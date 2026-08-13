# Vinyl Curator archive site builder (PowerShell 5.1, no dependencies).
#
# Reads the sheet's whitelisted export (collection.json on the Drive mount)
# plus the album photo folders, resizes photos to web size (which also strips
# EXIF/GPS - required), and renders the static site into this repo.
#
#   .\build.ps1           build only (eyeball locally via serve.ps1)
#   .\build.ps1 -Push     build, then git add/commit/push (publishes)
#   .\build.ps1 -Force    ignore per-album manifests, rebuild every photo
#
# PRICE GUARD: the export already whitelists fields, but this script refuses
# to build if any price-like key or any $-amount appears anywhere in the
# data - album pages double as marketplace link targets and must stay
# price-free.

param([switch]$Push, [switch]$Force)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# ---------- config ----------
$DataFile   = 'G:\My Drive\Vinyl Curator Website\collection.json'
$PhotoRoots = @('G:\My Drive\Vinyl Curator', 'G:\My Drive\Vinyl Curator Dev')
$WebEdge    = 1600   # max long edge, web size
$ThumbEdge  = 480    # max long edge, thumbnails
$JpegQ      = 82
$ShotNums   = @('01','03','05','06','08','10','12','14','16','18','20')

$Site   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Albums = Join-Path $Site 'albums'

# Middle dot as a code point: PS 5.1 reads BOM-less .ps1 files as ANSI, so a
# literal multi-byte character here would mojibake into the output.
$mid = [string][char]0x00B7

# ---------- helpers ----------
function HtmlEnc([string]$s) { return [System.Net.WebUtility]::HtmlEncode($s) }

function Write-Utf8([string]$path, [string]$text) {
  [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Slugify([string]$s) {
  $t = $s.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $t = $t.Trim('-')
  if ($t -eq '') { $t = 'x' }
  return $t
}

# Resize + re-encode (drops EXIF incl. GPS). Honors the EXIF orientation tag
# before it is lost so rotated phone shots come out upright.
function Resize-Jpeg([string]$src, [string]$dst, [int]$maxEdge, [int]$quality) {
  $img = [System.Drawing.Image]::FromFile($src)
  try {
    if ($img.PropertyIdList -contains 274) {
      $o = ($img.GetPropertyItem(274)).Value[0]
      if ($o -eq 3) { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
      elseif ($o -eq 6) { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
      elseif ($o -eq 8) { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
    }
    $scale = [Math]::Min(1.0, $maxEdge / [double][Math]::Max($img.Width, $img.Height))
    $nw = [int][Math]::Max(1, [Math]::Round($img.Width * $scale))
    $nh = [int][Math]::Max(1, [Math]::Round($img.Height * $scale))
    $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img, 0, 0, $nw, $nh)
    $g.Dispose()
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
      Where-Object { $_.MimeType -eq 'image/jpeg' }
    $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
      [System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
    $bmp.Save($dst, $codec, $ep)
    $bmp.Dispose()
  } finally { $img.Dispose() }
}

function Section([string]$id, [string]$title, [string]$bodyHtml) {
  if ($bodyHtml -eq '') { return '' }
  return "  <section class=""$id"">`n    <h2>$title</h2>`n$bodyHtml`n  </section>`n"
}

function Prose([string]$text) {
  if ($text.Trim() -eq '') { return '' }
  return '    <div class="prose">' + (HtmlEnc $text.Trim()) + '</div>'
}

# ---------- load + guard ----------
if (-not (Test-Path $DataFile)) { throw "Data file not found: $DataFile (run the sheet's Website export first)" }
$json = [IO.File]::ReadAllText($DataFile, [Text.Encoding]::UTF8) | ConvertFrom-Json

$priceRx = [regex]'\$\s?\d'
$keyRx = [regex]'(?i)price|estimate|delta|supplement|valuation'
$violations = New-Object System.Collections.Generic.List[string]
function Test-Node($node, [string]$path) {
  if ($null -eq $node) { return }
  if ($node -is [string]) {
    if ($priceRx.IsMatch($node)) { $violations.Add("$path contains a `$ amount") }
    return
  }
  if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
    $i = 0
    foreach ($item in $node) { Test-Node $item "$path[$i]"; $i++ }
    return
  }
  if ($node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $node.PSObject.Properties) {
      if ($keyRx.IsMatch($p.Name)) { $violations.Add("$path.$($p.Name) is a price-like key") }
      Test-Node $p.Value "$path.$($p.Name)"
    }
  }
}
$ai = 0
foreach ($a in $json.albums) { Test-Node $a "albums[$ai]"; $ai++ }
if ($violations.Count -gt 0) {
  $violations | ForEach-Object { Write-Host "GUARD: $_" -ForegroundColor Red }
  throw 'Price guard failed - fix the export (or the sheet cells) and re-export. Nothing was built.'
}

$generated = [datetime]::Parse($json.generated, $null,
  [System.Globalization.DateTimeStyles]::RoundtripKind)
if (((Get-Date).ToUniversalTime() - $generated.ToUniversalTime()).TotalDays -gt 7) {
  Write-Host "WARNING: collection.json is over 7 days old ($($json.generated)) - re-export from the sheet?" -ForegroundColor Yellow
}
$genDate = $generated.ToString('yyyy-MM-dd')
$year = (Get-Date).Year
$base = $json.site.baseUrl.TrimEnd('/')

# ---------- templates ----------
$tplAlbum = [IO.File]::ReadAllText((Join-Path $Site 'templates\album.html'), [Text.Encoding]::UTF8)
$tplIndex = [IO.File]::ReadAllText((Join-Path $Site 'templates\archive-index.html'), [Text.Encoding]::UTF8)
$tplLanding = [IO.File]::ReadAllText((Join-Path $Site 'templates\landing.html'), [Text.Encoding]::UTF8)

if (-not (Test-Path $Albums)) { New-Item -ItemType Directory $Albums | Out-Null }

$built = 0; $photosDone = 0; $photosSkipped = 0
$warnings = New-Object System.Collections.Generic.List[string]
$cards = New-Object System.Text.StringBuilder
$slugSet = @{}

foreach ($album in $json.albums) {
  $slug = $album.slug
  $slugSet[$slug] = $true
  $dir = Join-Path $Albums $slug
  $imgDir = Join-Path $dir 'img'
  $thumbDir = Join-Path $imgDir 't'
  foreach ($d in @($dir, $imgDir, $thumbDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null }
  }

  # ----- photos -----
  $srcFolder = $null
  foreach ($root in $PhotoRoots) {
    $candidate = Join-Path $root $album.folderName
    if (Test-Path $candidate) { $srcFolder = $candidate; break }
  }
  $shots = @()
  if ($null -eq $srcFolder) {
    $warnings.Add("$($album.artist) - $($album.title): photo folder '$($album.folderName)' not found under any photo root")
  } else {
    $files = Get-ChildItem $srcFolder -File | Where-Object {
      $_.Extension -match '(?i)^\.(jpe?g|png)$' -and $_.Name -match ' - (\d\d) (.+)\.[^.]+$'
    } | ForEach-Object {
      $m = [regex]::Match($_.Name, ' - (\d\d) (.+)\.[^.]+$')
      [pscustomobject]@{ File = $_; Num = $m.Groups[1].Value; Shot = $m.Groups[2].Value }
    } | Where-Object { $ShotNums -contains $_.Num } |
      Sort-Object @{ e = { $_.Num } }, @{ e = { $_.Shot } }

    # incremental manifest: "name|length|mtimeticks" per source file
    $maniFile = Join-Path $imgDir 'manifest.json'
    $old = @{}
    if ((Test-Path $maniFile) -and -not $Force) {
      (ConvertFrom-Json ([IO.File]::ReadAllText($maniFile))) | ForEach-Object { $old[$_] = $true }
    }
    $newMani = @()
    $wanted = @{}
    foreach ($s in $files) {
      $outName = $s.Num + '-' + (Slugify $s.Shot) + '.jpg'
      $key = $s.File.Name + '|' + $s.File.Length + '|' + $s.File.LastWriteTimeUtc.Ticks
      $newMani += $key
      $wanted[$outName] = $true
      $web = Join-Path $imgDir $outName
      $thumb = Join-Path $thumbDir $outName
      if ($old.ContainsKey($key) -and (Test-Path $web) -and (Test-Path $thumb)) {
        $photosSkipped++
      } else {
        Resize-Jpeg $s.File.FullName $web $WebEdge $JpegQ
        Resize-Jpeg $s.File.FullName $thumb $ThumbEdge $JpegQ
        $photosDone++
      }
      $shots += [pscustomobject]@{ Name = $outName; Shot = $s.Shot }
    }
    # prune outputs whose source is gone
    Get-ChildItem $imgDir -File -Filter '*.jpg' | Where-Object { -not $wanted.ContainsKey($_.Name) } |
      ForEach-Object { Remove-Item $_.FullName -Force }
    Get-ChildItem $thumbDir -File -Filter '*.jpg' | Where-Object { -not $wanted.ContainsKey($_.Name) } |
      ForEach-Object { Remove-Item $_.FullName -Force }
    Write-Utf8 $maniFile (ConvertTo-Json $newMani -Compress)
  }

  # ----- page fragments -----
  $enc = @{}
  foreach ($p in 'artist','title','year','labelName','labelNumber','monoStereo','countryOfOrigin',
                 'format','genre','speed','coverGrade','vinylGrade') {
    $v = [string]$album.$p
    $enc[$p] = HtmlEnc $v.Trim()
  }

  $subParts = @()
  if ($enc.year) { $subParts += $enc.year }
  $lab = ($enc.labelName + ' ' + $enc.labelNumber).Trim()
  if ($lab) { $subParts += $lab }
  if ($enc.monoStereo) { $subParts += $enc.monoStereo }
  if ($enc.countryOfOrigin) { $subParts += $enc.countryOfOrigin }
  $fsParts = @()
  if ($enc.format) { $fsParts += $enc.format }
  if ($enc.speed) { $fsParts += $enc.speed }
  if ($fsParts.Count -gt 0) { $subParts += ($fsParts -join " $mid ") }
  $subtitle = $subParts -join " &nbsp;$mid&nbsp; "

  $gallery = ''
  if ($shots.Count -gt 0) {
    $hero = $shots[0]
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('  <section class="gallery">')
    [void]$sb.AppendLine('    <figure class="hero-shot"><img src="img/' + $hero.Name +
      '" alt="' + (HtmlEnc ($album.artist + ' - ' + $album.title + ': ' + $hero.Shot)) + '"></figure>')
    if ($shots.Count -gt 1) {
      [void]$sb.AppendLine('    <div class="strip">')
      foreach ($s in ($shots | Select-Object -Skip 1)) {
        [void]$sb.AppendLine('      <img src="img/t/' + $s.Name + '" data-full="img/' + $s.Name +
          '" alt="' + (HtmlEnc $s.Shot) + '" loading="lazy">')
      }
      [void]$sb.AppendLine('    </div>')
    }
    [void]$sb.AppendLine('  </section>')
    $gallery = $sb.ToString()
  }

  $rows = New-Object System.Text.StringBuilder
  $detailDefs = @(
    @('Label', $enc.labelName), @('Catalogue number', $enc.labelNumber),
    @('Year', $enc.year), @('Mono / Stereo', $enc.monoStereo),
    @('Country', $enc.countryOfOrigin), @('Format', $enc.format),
    @('Speed', $enc.speed), @('Genre', $enc.genre),
    @('Producer', (HtmlEnc ([string]$album.producer).Trim())),
    @('Composer', (HtmlEnc ([string]$album.composer).Trim())),
    @('Conductor', (HtmlEnc ([string]$album.conductor).Trim())),
    @('Performer / Orchestra', (HtmlEnc ([string]$album.performerOrchestra).Trim())),
    @('Musicians', (HtmlEnc ([string]$album.musicians).Trim()))
  )
  foreach ($d in $detailDefs) {
    if ($d[1] -ne '') {
      [void]$rows.AppendLine('      <tr><th>' + $d[0] + '</th><td>' + $d[1] + '</td></tr>')
    }
  }
  $details = Section 'details' 'Pressing details' ('    <table><tbody>' + "`n" +
    $rows.ToString() + '    </tbody></table>')

  $mx = New-Object System.Text.StringBuilder
  foreach ($side in 'a','b','c','d') {
    $v = ([string]$album.matrix.$side).Trim()
    if ($v -ne '') { [void]$mx.AppendLine('Side ' + $side.ToUpper() + ':  ' + $v) }
  }
  $matrix = ''
  if ($mx.Length -gt 0) {
    $matrix = Section 'matrix' 'Matrix / Runout' ('    <pre>' + (HtmlEnc $mx.ToString().TrimEnd()) + '</pre>')
  }

  $sections = ''
  $sections += Section 'story' 'The Album' (Prose ([string]$album.albumStory))
  $sections += Section 'pressing' 'This Pressing' (Prose ([string]$album.lpNotes))
  $sections += Section 'label' 'The Label' (Prose ([string]$album.labelNotes))
  $sections += Section 'fidelity' 'Fidelity' (Prose ([string]$album.fidelity))
  $sections += Section 'notes' 'Notes' (Prose ([string]$album.generalNotes))

  $tl = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt 4; $i++) {
    $v = ([string]$album.sides[$i]).Trim()
    if ($v -ne '') {
      [void]$tl.AppendLine('      <div class="side"><h3>Side ' + ($i + 1) + '</h3><pre>' +
        (HtmlEnc $v) + '</pre></div>')
    }
  }
  $tracklist = ''
  if ($tl.Length -gt 0) {
    $tracklist = Section 'tracklist-wrap' 'Tracklist' ('    <div class="tracklist">' + "`n" +
      $tl.ToString() + '    </div>')
  }

  $chronology = ''
  $chron = [string]$album.variantChronology
  if ($null -ne $album.variantChronology -and $chron.Trim() -ne '') {
    $chronology = Section 'chronology' 'Variant chronology' ('    <pre>' +
      (HtmlEnc $chron.Trim()) + '</pre>')
  }

  $cond = New-Object System.Text.StringBuilder
  if ($enc.coverGrade) { [void]$cond.AppendLine('      <dt>Cover</dt><dd>' + $enc.coverGrade + '</dd>') }
  if ($enc.vinylGrade) { [void]$cond.AppendLine('      <dt>Vinyl</dt><dd>' + $enc.vinylGrade + '</dd>') }
  $condition = ''
  if ($cond.Length -gt 0) {
    $condition = Section 'condition' 'Condition' ('    <dl>' + "`n" + $cond.ToString() + '    </dl>')
  }

  $descSrc = ([string]$album.lpNotes).Trim()
  if ($descSrc -eq '') { $descSrc = ([string]$album.albumStory).Trim() }
  $descSrc = $descSrc -replace '\s+', ' '
  if ($descSrc.Length -gt 155) { $descSrc = $descSrc.Substring(0, 152).TrimEnd() + '...' }

  $page = $tplAlbum.Replace('{{ARTIST}}', $enc.artist).Replace('{{TITLE}}', $enc.title)
  $page = $page.Replace('{{SUBTITLE}}', $subtitle)
  $page = $page.Replace('{{META_DESC}}', (HtmlEnc $descSrc))
  $page = $page.Replace('{{CANONICAL}}', "$base/albums/$slug/")
  $page = $page.Replace('{{GALLERY}}', $gallery).Replace('{{DETAILS}}', $details)
  $page = $page.Replace('{{MATRIX}}', $matrix).Replace('{{SECTIONS}}', $sections)
  $page = $page.Replace('{{TRACKLIST}}', $tracklist).Replace('{{CHRONOLOGY}}', $chronology)
  $page = $page.Replace('{{CONDITION}}', $condition)
  $page = $page.Replace('{{GENERATED}}', $genDate).Replace('{{YEAR}}', "$year")
  $page = $page.Replace('{{ROOT}}', '../../')
  Write-Utf8 (Join-Path $dir 'index.html') $page
  $built++

  # ----- index card -----
  $coverThumb = ''
  $firstCover = $shots | Where-Object { $_.Name -like '01-*' } | Select-Object -First 1
  if ($firstCover) { $coverThumb = "$slug/img/t/$($firstCover.Name)" }
  $search = (($album.artist + ' ' + $album.title + ' ' + $album.labelName + ' ' +
    $album.labelNumber + ' ' + $album.year).ToLowerInvariant() -replace '\s+', ' ').Trim()
  $coverHtml = '<div class="cover"></div>'
  if ($coverThumb -ne '') {
    $coverHtml = '<div class="cover"><img src="' + $coverThumb + '" alt="" loading="lazy"></div>'
  }
  [void]$cards.AppendLine('    <a class="card" href="' + $slug + '/" data-search="' +
    (HtmlEnc $search) + '">' + $coverHtml + '<div class="meta"><p class="a">' + $enc.artist +
    '</p><p class="t">' + $enc.title + '</p><p class="y">' +
    (($enc.year, $enc.labelName | Where-Object { $_ -ne '' }) -join " $mid ") +
    '</p></div></a>')
}

# ---------- index, landing, sitemap, data copy ----------
$countLabel = "$built records"
if ($built -eq 1) { $countLabel = '1 record' }
$idx = $tplIndex.Replace('{{CARDS}}', $cards.ToString()).Replace('{{COUNTLABEL}}', $countLabel)
$idx = $idx.Replace('{{CANONICAL}}', "$base/albums/").Replace('{{ROOT}}', '../')
$idx = $idx.Replace('{{GENERATED}}', $genDate).Replace('{{YEAR}}', "$year")
Write-Utf8 (Join-Path $Albums 'index.html') $idx

$land = $tplLanding.Replace('{{COUNTLABEL}}', $countLabel).Replace('{{CANONICAL}}', "$base/")
$land = $land.Replace('{{GENERATED}}', $genDate).Replace('{{YEAR}}', "$year")
Write-Utf8 (Join-Path $Site 'index.html') $land

$sm = New-Object System.Text.StringBuilder
[void]$sm.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sm.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
foreach ($u in (@("$base/", "$base/albums/") + ($json.albums | ForEach-Object { "$base/albums/$($_.slug)/" }))) {
  [void]$sm.AppendLine("  <url><loc>$u</loc><lastmod>$genDate</lastmod></url>")
}
[void]$sm.AppendLine('</urlset>')
Write-Utf8 (Join-Path $Site 'sitemap.xml') $sm.ToString()

Copy-Item $DataFile (Join-Path $Site 'collection.json') -Force

# ---------- prune removed albums ----------
Get-ChildItem $Albums -Directory | Where-Object { -not $slugSet.ContainsKey($_.Name) } |
  ForEach-Object {
    $hold = Join-Path $Site ('_removed\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (-not (Test-Path $hold)) { New-Item -ItemType Directory $hold -Force | Out-Null }
    Move-Item $_.FullName (Join-Path $hold $_.Name)
    $warnings.Add("Removed album staged in _removed\: $($_.Name) (no longer in the export)")
  }

# ---------- report ----------
Write-Host ''
Write-Host "Built $built album page(s); photos: $photosDone converted, $photosSkipped unchanged." -ForegroundColor Green
foreach ($w in $warnings) { Write-Host "WARNING: $w" -ForegroundColor Yellow }
Write-Host "Preview locally: powershell -ExecutionPolicy Bypass -File serve.ps1  ->  http://localhost:8322/"

if ($Push) {
  Push-Location $Site
  try {
    git add -A
    git commit -m "publish $genDate ($built albums)"
    git push
  } finally { Pop-Location }
}
