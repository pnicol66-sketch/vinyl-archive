# Vinyl Curator archive site builder (PowerShell 5.1, no dependencies).
#
# Reads the sheet's whitelisted export (collection.json on the Drive mount)
# plus the album photo folders, resizes photos to web size (which also strips
# EXIF/GPS - required), and renders the static site into this repo.
#
#   .\build.ps1           build only (eyeball locally via serve.ps1)
#   .\build.ps1 -Push     build, then git add/commit/push (publishes)
#   .\build.ps1 -Force    ignore the per-album manifests AND the source folder
#                         scan cache: re-scan every folder, rebuild every photo
#
# PRICE GUARD: the export already whitelists fields, but this script refuses
# to build if any price-like key or any $-amount appears anywhere in the
# data - album pages double as marketplace link targets and must stay
# price-free.

param([switch]$Push, [switch]$Force, [switch]$AllowEmpty, [string]$Tenant = 'owner', [switch]$All)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$Elapsed = [Diagnostics.Stopwatch]::StartNew()

# ---------- config ----------
# The Website export folder on the Drive mount. Each tenant's data file lives
# here (owner: collection.json; a client: collection-<slug>.json); the specific
# file is chosen from the tenant registry below. $DataFile is set there.
$WebsiteDataDir = 'G:\My Drive\Vinyl Curator Website'
$PhotoRoots = @('G:\My Drive\Vinyl Curator', 'G:\My Drive\Vinyl Curator Dev')
$WebEdge    = 1600   # max long edge, web size
$ThumbEdge  = 480    # max long edge, thumbnails
$JpegQ      = 82
$ShotNums   = @('01','03','05','06','08','10','12','14','16','18','20','22','23','24','25')
# Gallery order (mirrors websiteImageUrls_ in the sheet script): covers,
# then each side's label followed by its vinyl surface shot (22-25),
# matrix close-ups last.
$ShotOrder  = @('01','03','05','06','22','08','23','10','24','12','25','14','16','18','20')

# Corner ownership watermark, on both the web-size images and the thumbs.
# Sized to stay inside eBay's attribution-watermark rule (<=5% of image
# area, <=50% opacity, corner placement). Discogs listing photo uploads
# must use the CLEAN full-res originals from Drive - Discogs allows no
# watermarks of any kind on item photos.
$Watermark  = 'vinylcurator.net'

# Sold records have their own index page (/sold/, 2026-08-21) - the archive
# keeps the documentation of records it no longer holds. Their matrix
# transcriptions are archive content and stay indexable by default; every
# record eventually sells, so noindexing them would progressively remove the
# archive from search. Flip to $true only if Sold pages should be hidden from
# crawlers - note that also drops them from /sold/, since the card dispatch
# treats a noindexed row as unlisted.
$NoindexSold = $false

# Contact address, split so the raw HTML never contains the assembled
# address (site.js joins the parts at load - keeps scrapers off it).
# contact@vinylcurator.net is a Porkbun forward to the owner's Gmail.
$MailUser   = 'contact'
$MailDomain = 'vinylcurator.net'

# Image host. Album photos are served from Cloudflare R2 at this origin, NOT
# from GitHub Pages: the generated HTML references absolute URLs here, and
# -Push syncs the photos up to the bucket instead of committing them (Pages
# cannot hold the collection at scale - see vinyl-site-multitenancy-design.md).
# The sheet export can override per-build via site.assetBaseUrl; this is the
# fallback for a build whose export predates that field.
$AssetBaseDefault = 'https://img.vinylcurator.net'
$R2Remote         = 'r2:vinyl-img/albums'
# Private client sites (Phase P) sync their whole tree to this bucket, keyed by
# the client's subdomain label. The rclone `r2` remote's token must have access
# to it (broaden the token to cover both buckets, or use an account-scoped one).
$ClientBucket     = 'vinyl-client'

$Site   = Split-Path -Parent $MyInvocation.MyCommand.Path
# $Albums (this tenant's album output dir) is set from the tenant registry below.

# Middle dot as a code point: PS 5.1 reads BOM-less .ps1 files as ANSI, so a
# literal multi-byte character here would mojibake into the output.
$mid = [string][char]0x00B7
# Em dash, same reason - used in the section-header ledes below.
$dash = [string][char]0x2014

# Optional local config (gitignored - holds machine paths): extra photo roots
# and per-album folder overrides for albums whose photos don't resolve:
#   { "photoRoots": ["D:\\More Albums"],
#     "folderOverrides": { "<album slug>": "C:\\full\\path\\to\\album folder" } }
$ConfigFile = Join-Path $Site 'build.config.json'
$FolderOverrides = @{}
if (Test-Path $ConfigFile) {
  $cfg = [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
  if ($cfg.photoRoots) { $PhotoRoots = @($PhotoRoots) + @($cfg.photoRoots) }
  if ($cfg.folderOverrides) {
    foreach ($p in $cfg.folderOverrides.PSObject.Properties) {
      $FolderOverrides[$p.Name] = [string]$p.Value
    }
  }
}

# ---------- tenant registry ----------
# Each collection published to this site is a tenant: its own URL prefix, data
# file, asset base and watermark (tenants.json, committed). The owner is tenant
# zero with an EMPTY prefix, so every path and URL below is exactly what it was.
# This step scopes the data file, the album output dir, the asset base, the
# watermark and the prune to the chosen tenant; the per-tenant nav / {{ROOT}}
# depth and the multi-tenant build loop are later Phase B steps (B3, B5).
if ([string]::IsNullOrWhiteSpace($Tenant)) { $Tenant = 'owner' }
$TenantsFile = Join-Path $Site 'tenants.json'

# -All: build every active tenant, each in its own process. A per-tenant build
# is self-contained (it writes only its own prefix + its own sitemap
# contribution), so looping child processes is simpler and safer than threading
# one pass through N tenants. -All -Push publishes ONCE after all builds; full
# multi-tenant publishing (per-tenant R2 buckets etc.) is B7 - for now this
# syncs the owner's public image tree and does a single git push.
if ($All) {
  if (-not (Test-Path $TenantsFile)) { throw 'tenants.json not found - cannot -All.' }
  $regAll = [IO.File]::ReadAllText($TenantsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $activeTenants = @($regAll.tenants | Where-Object {
    [string]$_.status -ne 'suspended' -and [string]$_.status -ne 'removed' })
  if ($activeTenants.Count -eq 0) { throw 'No active tenants in tenants.json.' }
  foreach ($t in $activeTenants) {
    Write-Host ("=== Building tenant: " + $t.slug + " ===") -ForegroundColor Cyan
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Tenant', [string]$t.slug)
    if ($Force)      { $argv += '-Force' }
    if ($AllowEmpty) { $argv += '-AllowEmpty' }
    & powershell @argv
    if ($LASTEXITCODE -ne 0) { throw ("Tenant build failed: " + $t.slug + " (exit $LASTEXITCODE)") }
  }
  if ($Push) {
    $rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
    if (-not $rclone) {
      $rclone = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1).FullName
    }
    if (-not $rclone) { throw 'rclone not found - install it (winget install Rclone.Rclone).' }
    Write-Host "Syncing owner photos to $R2Remote ..." -ForegroundColor DarkGray
    & $rclone sync (Join-Path $Site 'albums') $R2Remote --include '**/*.jpg' --s3-no-check-bucket --transfers 16 --checkers 16 --stats-one-line
    if ($LASTEXITCODE -ne 0) { throw "rclone sync to R2 failed (exit $LASTEXITCODE) - not committing." }
    Push-Location $Site
    try {
      git add -A
      git commit -m ("publish " + (Get-Date -Format 'yyyy-MM-dd') + " (all tenants)")
      git push
    } finally { Pop-Location }
  }
  return
}

$ownerDefault = [pscustomobject]@{ slug = 'owner'; urlPrefix = ''
  dataFile = 'collection.json'; assetBase = $AssetBaseDefault; watermark = 'vinylcurator.net' }
$tenantCfg = $ownerDefault
if (Test-Path $TenantsFile) {
  $reg = [IO.File]::ReadAllText($TenantsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $tenantCfg = @($reg.tenants) | Where-Object { $_.slug -eq $Tenant } | Select-Object -First 1
  if (-not $tenantCfg) {
    throw ("Unknown tenant '$Tenant' - not in tenants.json (have: " +
      ((@($reg.tenants).slug) -join ', ') + ').')
  }
}
# A PRIVATE tenant (a login-gated client site, Phase P) is served from its own
# subdomain root, with relative image/asset URLs, and is built into a gitignored
# per-client STAGING tree that never enters the public repo - then synced to the
# private R2 bucket. Owner and public tenants build into the site repo itself.
$private = ($tenantCfg.private -eq $true)
$urlPrefix = if ($private) { '' } else { [string]$tenantCfg.urlPrefix }
$DataFile  = Join-Path $WebsiteDataDir ([string]$tenantCfg.dataFile)
if ($private) {
  $OutRoot = Join-Path $env:LOCALAPPDATA ('vinyl-private\' + [string]$tenantCfg.slug)
  if (-not (Test-Path $OutRoot)) { New-Item -ItemType Directory $OutRoot -Force | Out-Null }
} else {
  $OutRoot = $Site
}
# This tenant's three section output dirs, under its prefix, within the output
# root. Owner (empty prefix, OutRoot = the repo) keeps /albums, /available,
# /sold at the site root exactly as before.
if ($urlPrefix -ne '') {
  $pfx = $urlPrefix -replace '/', '\'
  $Albums       = Join-Path $OutRoot ($pfx + '\albums')
  $AvailableDir = Join-Path $OutRoot ($pfx + '\available')
  $SoldDir      = Join-Path $OutRoot ($pfx + '\sold')
} else {
  $Albums       = Join-Path $OutRoot 'albums'
  $AvailableDir = Join-Path $OutRoot 'available'
  $SoldDir      = Join-Path $OutRoot 'sold'
}
# Watermark comes from the tenant ('' = clean images, the white-label option).
if ($null -ne $tenantCfg.watermark) { $Watermark = [string]$tenantCfg.watermark }

# Per-tenant photo roots. A client's albums live in the client's OWN folder, so a
# client build must search only that folder - never the owner's or another
# client's - or a shared album folder-name could pull the wrong copy. When
# build.config.json defines "tenants": { "<slug>": { "photoRoots": [...] } } for
# this (non-owner) tenant, REPLACE the global roots with the client's; likewise
# folderOverrides. The owner always uses the global roots (unchanged).
if ($tenantCfg.slug -ne 'owner' -and $cfg -and $cfg.tenants) {
  $tcfg = $cfg.tenants.PSObject.Properties[[string]$tenantCfg.slug]
  if ($tcfg) {
    $tcfg = $tcfg.Value
    if ($tcfg.photoRoots) { $PhotoRoots = @($tcfg.photoRoots) }
    if ($tcfg.folderOverrides) {
      $FolderOverrides = @{}
      foreach ($o in $tcfg.folderOverrides.PSObject.Properties) { $FolderOverrides[$o.Name] = [string]$o.Value }
    }
  }
}

# Depth of this tenant's pages below the site root, for the '../' asset/nav
# prefixes ({{ROOT}}). Owner (empty prefix): an album page sits at
# albums/<slug>/ (2 deep) and an index/about at <section>/ (1 deep), so these
# come out '../../' and '../' - exactly as the hardcoded values they replace. A
# client at collections/<slug>/ is two segments deeper.
$prefixDepth = @($urlPrefix -split '/' | Where-Object { $_ -ne '' }).Count
$RootAlbum = '../' * ($prefixDepth + 2)   # album page + withdrawn tombstone
$RootIndex = '../' * ($prefixDepth + 1)   # section index + about

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
# before it is lost so rotated phone shots come out upright. A non-empty $wm
# draws the corner watermark (text height ~3% of the long edge, white at
# ~45% opacity over a faint shadow so it reads on light and dark shots).
#
# A scriptblock rather than a function because it also runs inside worker
# runspaces (Invoke-ResizeBatch below), and a runspace inherits nothing from
# this one - no functions, no variables, no loaded assemblies. Everything it
# needs is a parameter or loaded here. Keep it self-contained.
# One job is one SOURCE photo and produces both of its outputs: the source is
# read off the Drive mount once and JPEG-decoded once, then scaled twice. That
# halves both the reads and the decodes against a job-per-output split.
$ResizeScript = {
  param($jobs, [int]$webEdge, [int]$thumbEdge, [int]$quality, [string]$wm)
  $ErrorActionPreference = 'Stop'
  Add-Type -AssemblyName System.Drawing
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq 'image/jpeg' }
  $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
    [System.Drawing.Imaging.Encoder]::Quality, [long]$quality)

  # Scale an already-decoded, already-oriented image to $maxEdge and write it
  # out as JPEG. A non-empty $mark draws the corner watermark.
  function Save-Scaled($img, [string]$dst, [int]$maxEdge, [string]$mark, $codec, $ep) {
    $scale = [Math]::Min(1.0, $maxEdge / [double][Math]::Max($img.Width, $img.Height))
    $nw = [int][Math]::Max(1, [Math]::Round($img.Width * $scale))
    $nh = [int][Math]::Max(1, [Math]::Round($img.Height * $scale))
    $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img, 0, 0, $nw, $nh)
    if ($mark -ne '') {
      $fs = [Math]::Max(13, [int][Math]::Round([Math]::Max($nw, $nh) * 0.030))
      $font = New-Object System.Drawing.Font('Segoe UI', $fs,
        [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
      $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
      $sz = $g.MeasureString($mark, $font)
      $pad = [Math]::Round($fs * 0.8)
      $x = [float]($nw - $sz.Width - $pad)
      $y = [float]($nh - $sz.Height - $pad)
      $off = [Math]::Max(1, [int][Math]::Round($fs / 14))
      $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 0, 0, 0))
      $ink = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(115, 255, 255, 255))
      $g.DrawString($mark, $font, $shadow, ($x + $off), ($y + $off))
      $g.DrawString($mark, $font, $ink, $x, $y)
      $font.Dispose(); $shadow.Dispose(); $ink.Dispose()
    }
    $g.Dispose()
    $outStream = New-Object IO.MemoryStream
    $bmp.Save($outStream, $codec, $ep)
    [IO.File]::WriteAllBytes('\\?\' + $dst, $outStream.ToArray())
    $outStream.Dispose()
    $bmp.Dispose()
  }

  foreach ($j in $jobs) {
    # Byte-stream IO with \\?\ paths: long classical titles push source paths
    # past the 260-char Windows limit, which plain GDI+ file calls refuse.
    $srcStream = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes('\\?\' + $j.Src))
    $img = [System.Drawing.Image]::FromStream($srcStream)
    try {
      # Honor the EXIF orientation tag before re-encoding drops it, so rotated
      # phone shots come out upright. Applied once, to the shared decode.
      if ($img.PropertyIdList -contains 274) {
        $o = ($img.GetPropertyItem(274)).Value[0]
        if ($o -eq 3) { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
        elseif ($o -eq 6) { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
        elseif ($o -eq 8) { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
      }
      Save-Scaled $img $j.Web $webEdge $wm $codec $ep
      Save-Scaled $img $j.Thumb $thumbEdge $wm $codec $ep
    } finally { $img.Dispose(); $srcStream.Dispose() }
  }
}
$ResizeScriptText = $ResizeScript.ToString()

# What a worker process runs. Single-quoted here-string: every $ below belongs
# to the worker, not to this script. Kept ASCII-only and written out with a BOM
# so PS 5.1 cannot mis-read it as ANSI.
$WorkerScript = @'
param([string]$lib, [string]$cfgFile, [string]$listFile, [string]$progressFile, [string]$errFile)
$ErrorActionPreference = 'Stop'
try {
  . $lib
  $cfg = Get-Content -Raw $cfgFile | ConvertFrom-Json
  $done = 0
  foreach ($line in [IO.File]::ReadAllLines($listFile)) {
    if ($line -eq '') { continue }
    # '|' is illegal in Windows paths, so it is a safe field separator here.
    $p = $line.Split([char]124)
    & $ResizeScript @([pscustomobject]@{ Src = $p[0]; Web = $p[1]; Thumb = $p[2] }) `
      ([int]$cfg.webEdge) ([int]$cfg.thumbEdge) ([int]$cfg.quality) ([string]$cfg.watermark)
    $done++
    [IO.File]::WriteAllText($progressFile, "$done")
  }
} catch {
  [IO.File]::WriteAllText($errFile, $_.Exception.Message)
  exit 1
}
'@

# Run every pending photo across the worker pool and wait for all of them.
# The wait is the point: the caller writes the manifests immediately after, and
# a manifest is the record that says "these outputs are current". A failure has
# to throw BEFORE that write, exactly as the old sequential path did, so the
# next build retries the work instead of skipping it.
function Invoke-ResizeBatch($jobs) {
  $all = @($jobs)
  if ($all.Count -eq 0) { return }

  # Small batches - the normal incremental publish, a handful of new shots -
  # run right here: starting workers costs more than the work does.
  if ($MaxWorkers -le 1 -or $all.Count -le 8) {
    & $ResizeScript $all $WebEdge $ThumbEdge $JpegQ $Watermark
    return
  }

  # Bigger batches go to child PROCESSES, not threads. GDI+ serializes on a
  # process-wide lock, so a runspace pool measured only 1.26x on 7 threads for
  # exactly this work; separate processes measured 2.7x over the same 40
  # photos and pull further ahead as the batch grows, which is the case
  # -Force exists for. Output is byte-identical either way - verified by
  # rebuilding all 224 photos and diffing against the committed tree.
  $work = Join-Path $env:TEMP ('vinyl-build-' + $PID)
  if (Test-Path $work) { [IO.Directory]::Delete((Convert-Path $work), $true) }
  New-Item -ItemType Directory $work -Force | Out-Null
  $utf8bom = New-Object System.Text.UTF8Encoding($true)
  $lib = Join-Path $work 'resize-lib.ps1'
  [IO.File]::WriteAllText($lib, ('$ResizeScript = {' + $ResizeScriptText + '}'), $utf8bom)
  $cfgFile = Join-Path $work 'config.json'
  [IO.File]::WriteAllText($cfgFile, (ConvertTo-Json @{ webEdge = $WebEdge; thumbEdge = $ThumbEdge
    quality = $JpegQ; watermark = $Watermark } -Compress), $utf8bom)
  $workerPs = Join-Path $work 'worker.ps1'
  [IO.File]::WriteAllText($workerPs, $WorkerScript, $utf8bom)

  # Round-robin: consecutive photos are usually the same album shot on the
  # same day at the same size, so dealing them out keeps the workers even.
  $slices = [Math]::Min($all.Count, $MaxWorkers)
  $lists = @()
  for ($i = 0; $i -lt $slices; $i++) { $lists += , (New-Object System.Collections.ArrayList) }
  for ($i = 0; $i -lt $all.Count; $i++) {
    [void]$lists[$i % $slices].Add($all[$i].Src + '|' + $all[$i].Web + '|' + $all[$i].Thumb)
  }

  $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $procs = @()
  for ($i = 0; $i -lt $slices; $i++) {
    $listFile = Join-Path $work "list$i.txt"
    [IO.File]::WriteAllLines($listFile, [string[]]$lists[$i].ToArray())
    $prog = Join-Path $work "prog$i.txt"
    $errFile = Join-Path $work "err$i.txt"
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.UseShellExecute = $false
    # Publishing runs from a deliberately windowless launcher - a worker must
    # never flash a console window.
    $psi.CreateNoWindow = $true
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}" "{2}" "{3}" "{4}" "{5}"' -f
      $workerPs, $lib, $cfgFile, $listFile, $prog, $errFile)
    $procs += [pscustomobject]@{ P = [Diagnostics.Process]::Start($psi); Prog = $prog; Err = $errFile }
  }

  # Progress is read from the workers' own counters, so a worker that dies
  # part way through reports what it actually finished, not what it was given.
  function Get-BatchProgress($ps) {
    $n = 0
    foreach ($p in $ps) {
      # The worker rewrites this file as it goes, so a read can collide with a
      # write. Progress is cosmetic - never fail the build over it.
      try { if (Test-Path $p.Prog) { $n += [int](Get-Content -Raw $p.Prog) } } catch { }
    }
    return $n
  }
  while (@($procs | Where-Object { -not $_.P.HasExited }).Count -gt 0) {
    Start-Sleep -Milliseconds 500
    Write-Host ("`r  photos: " + (Get-BatchProgress $procs) + '/' + $all.Count + '  ') -NoNewline
  }
  foreach ($p in $procs) { $p.P.WaitForExit() }
  Write-Host ("`r  photos: " + (Get-BatchProgress $procs) + '/' + $all.Count + '  ')

  $failures = New-Object System.Collections.Generic.List[string]
  foreach ($p in $procs) {
    if ($p.P.ExitCode -ne 0) {
      $msg = "a photo worker exited with code $($p.P.ExitCode)"
      if (Test-Path $p.Err) { $msg = (Get-Content -Raw $p.Err).Trim() }
      $failures.Add($msg)
    }
    $p.P.Dispose()
  }
  [IO.Directory]::Delete((Convert-Path $work), $true)
  if ($failures.Count -gt 0) {
    throw ("Photo processing failed:`n  " + ($failures -join "`n  "))
  }
}

function Section([string]$id, [string]$title, [string]$bodyHtml) {
  if ($bodyHtml -eq '') { return '' }
  return "  <section class=""$id"">`n    <h2>$title</h2>`n$bodyHtml`n  </section>`n"
}

function Prose([string]$text) {
  if ($text.Trim() -eq '') { return '' }
  return '    <div class="prose">' + (HtmlEnc $text.Trim()) + '</div>'
}

# The site nav, built per tenant (the {{NAV}} token in album.html /
# archive-index.html). LF-joined to match those (LF) templates exactly.
#   $current : 'album' | 'archive' | 'available' | 'sold'
#   $root    : the page's '../' prefix to the site root
#   $albumTab: the album's tab, only read when $current is 'album'
# The OWNER nav is reproduced byte-for-byte from the old template markup: album
# pages carry no aria-current, the Sold sublink shows on a Sold album page and
# inside Available/Sold on the indexes. A CLIENT tenant shows ONLY its own
# collection(s) from its `indexes` - never the owner's sections or About.
function Build-Nav([string]$current, [string]$root, [string]$albumTab) {
  $nl = "`n"
  if ($tenantCfg.slug -eq 'owner') {
    $curA = ''; $curV = ''; $curS = ''
    if ($current -eq 'archive')   { $curA = ' aria-current="page"' }
    if ($current -eq 'available') { $curV = ' aria-current="page"' }
    if ($current -eq 'sold')      { $curS = ' aria-current="page"' }
    $sold = ''
    if ($current -eq 'album') {
      if ($albumTab -eq 'Sold') { $sold = '<a class="sub" href="' + $root + 'sold/">Sold</a>' }
    } elseif ($current -eq 'available' -or $current -eq 'sold') {
      $sold = '<a class="sub" href="' + $root + 'sold/"' + $curS + '>Sold</a>'
    }
    return '  <nav>' + $nl +
      '    <a class="brand" href="' + $root + '">Vinyl Curator</a>' + $nl +
      '    <a href="' + $root + 'albums/"' + $curA + '>Personal Archive</a>' + $nl +
      '    <span class="nav-sec"><a href="' + $root + 'available/"' + $curV + '>Available</a>' + $sold + '</span>' + $nl +
      '    <a href="' + $root + 'about/">About</a>' + $nl +
      '  </nav>'
  }
  # Client tenant: brand + only its own indexes.
  $nav = '  <nav>' + $nl +
    '    <a class="brand" href="' + $root + '">' + (HtmlEnc ([string]$tenantCfg.name)) + '</a>' + $nl
  foreach ($ix in @($tenantCfg.indexes)) {
    $ipath = ([string]$ix.path).Trim('/')
    $cur = ''
    if ($current -eq $ipath -or ($current -eq 'archive' -and $ipath -eq 'albums')) { $cur = ' aria-current="page"' }
    $nav += '    <a href="' + $root + $ipath + '/"' + $cur + '>' + (HtmlEnc ([string]$ix.title)) + '</a>' + $nl
  }
  return $nav + '  </nav>'
}

# ---------- load + guard ----------
if (-not (Test-Path $DataFile)) { throw "Data file not found: $DataFile (run the sheet's Website export first)" }
$json = [IO.File]::ReadAllText($DataFile, [Text.Encoding]::UTF8) | ConvertFrom-Json

$priceRx = [regex]'\$\s?\d'
# Historical narrative amounts ("a $26 million flop") are not listing/value
# data - strip them before the test. Everything else $-shaped stays fatal.
$narrativeRx = [regex]'(?i)\$\s?\d+(\.\d+)?\s*(million|billion)\b'
$keyRx = [regex]'(?i)price|estimate|delta|supplement|valuation'
$violations = New-Object System.Collections.Generic.List[string]
function Test-Node($node, [string]$path) {
  if ($null -eq $node) { return }
  if ($node -is [string]) {
    if ($priceRx.IsMatch($narrativeRx.Replace($node, ''))) {
      $violations.Add("$path contains a `$ amount")
    }
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

# EMPTY-EXPORT GUARD: an export carrying zero albums is almost always a failed
# or half-synced export, not a deliberate decision to unpublish everything.
# Building one would regenerate empty index pages AND stage every existing
# album directory into _removed\ - one bad export would take the whole site
# down in a single push. Refuse unless the caller says otherwise.
if (@($json.albums).Count -eq 0 -and -not $AllowEmpty) {
  throw ('The export contains 0 albums - refusing to build, because this ' +
    'would empty the site. Re-export from the sheet (Website > Publish Vinyl ' +
    'Site...). If you really do mean to publish an empty site, re-run with ' +
    '-AllowEmpty.')
}

# Per-album crawler policy. Absent "listed" (the current export shape) leaves
# a page indexable; the unpublish work adds "listed": false for unlisted rows.
function Test-Noindex($album) {
  if ([string]$album.status -eq 'withdrawn') { return $true }
  if ($NoindexSold -and $album.tab -eq 'Sold') { return $true }
  if ($album.listed -eq $false) { return $true }
  return $false
}

$generated = [datetime]::Parse($json.generated, $null,
  [System.Globalization.DateTimeStyles]::RoundtripKind)
if (((Get-Date).ToUniversalTime() - $generated.ToUniversalTime()).TotalDays -gt 7) {
  Write-Host "WARNING: collection.json is over 7 days old ($($json.generated)) - re-export from the sheet?" -ForegroundColor Yellow
}
$genDate = $generated.ToString('yyyy-MM-dd')
$year = (Get-Date).Year
$base = $json.site.baseUrl.TrimEnd('/')
# Canonical URL base for THIS tenant: the owner's is the site root; a client's
# is the site root plus its collection prefix. Used for canonical + sitemap URLs.
if ($private) { $tenantBase = ($base -replace '^https?://', ('https://' + [string]$tenantCfg.slug + '.')) }
elseif ($urlPrefix -ne '') { $tenantBase = "$base/$urlPrefix" }
else { $tenantBase = $base }
# Where photos are served from (R2). Prefer the export's own value so the sheet
# stays the single source of truth once it emits it; fall back otherwise.
$assetBase = [string]$json.site.assetBaseUrl
if ([string]::IsNullOrWhiteSpace($assetBase)) { $assetBase = [string]$tenantCfg.assetBase }
if ([string]::IsNullOrWhiteSpace($assetBase)) { $assetBase = $AssetBaseDefault }
$assetBase = $assetBase.TrimEnd('/')

# ---------- templates ----------
$tplAlbum = [IO.File]::ReadAllText((Join-Path $Site 'templates\album.html'), [Text.Encoding]::UTF8)
$tplIndex = [IO.File]::ReadAllText((Join-Path $Site 'templates\archive-index.html'), [Text.Encoding]::UTF8)
$tplLanding = [IO.File]::ReadAllText((Join-Path $Site 'templates\landing.html'), [Text.Encoding]::UTF8)
$tplAbout = [IO.File]::ReadAllText((Join-Path $Site 'templates\about.html'), [Text.Encoding]::UTF8)
$tplWithdrawn = [IO.File]::ReadAllText((Join-Path $Site 'templates\withdrawn.html'), [Text.Encoding]::UTF8)
$tplNotFound = [IO.File]::ReadAllText((Join-Path $Site 'templates\404.html'), [Text.Encoding]::UTF8)

# ---------- asset versions ----------
# The stylesheet and script are linked with a short content hash, so a changed
# asset is a NEW URL that no cache can answer from an old copy. GitHub Pages
# serves /assets/ with max-age=600 and there is no way to set headers on it,
# so without this a returning visitor spends up to ten minutes rendering new
# HTML against the previous stylesheet - which does not look like a stale
# cache, it looks like the layout is broken.
#
# Hashed per file, not one version for both: a CSS edit should not also make
# every visitor re-fetch the JS.
#
# The cost lands on the album pages, which are otherwise written to be
# byte-stable across publishes (see the note in album.html): a CSS edit now
# rewrites all of them, one fresh git blob each. That is per CSS CHANGE, not
# per publish - rare enough to be worth it, where a per-publish timestamp was
# not. The hash is of the content, so reverting a CSS edit restores the old
# URL rather than churning to a third value.
function AssetVer([string]$rel) {
  $p = Join-Path $Site $rel
  if (-not (Test-Path $p)) { return '0' }
  return (Get-FileHash $p -Algorithm MD5).Hash.Substring(0, 8).ToLowerInvariant()
}
$vCss = AssetVer 'assets\site.css'
$vJs  = AssetVer 'assets\site.js'

if (-not (Test-Path $Albums)) { New-Item -ItemType Directory $Albums | Out-Null }

# ---------- workers ----------
# Measured on this machine: ~190 ms of CPU per photo (decode + two scales) and
# ~11 ms to read it off the Drive mount, so a full rebuild is CPU-bound and
# scales with cores. Cores minus one leaves the machine usable - publishing
# runs on the owner's desktop while they are using it.
$MaxWorkers = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount - 1))

# ---------- source folder scan cache ----------
# Enumerating every album's source folder on the Drive stream mount costs
# minutes at collection scale, and between two builds almost nothing has
# changed. Cache each folder's parsed shot list against the folder's own
# LastWriteTimeUtc.
#
# CAVEAT, and the reason -Force bypasses it: a folder's mtime moves when a file
# is added, removed or renamed, but not necessarily when an existing file is
# overwritten in place. Re-importing a re-shot photo writes a new file, which
# does move it; a photo edited in place out of band would be missed. Run
# -Force after any such edit.
$ScanCacheFile = Join-Path $Site '.foldercache.json'
$ScanCache = @{}
if ((Test-Path $ScanCacheFile) -and -not $Force) {
  try {
    $rawCache = [IO.File]::ReadAllText($ScanCacheFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($p in $rawCache.PSObject.Properties) { $ScanCache[$p.Name] = $p.Value }
  } catch {
    # A corrupt or half-written cache is a re-scan, never a failed build.
    $ScanCache = @{}
  }
}
$ScanCacheNew = @{}
$scanHits = 0; $scanMisses = 0

# Parsed, filtered and ordered shot list for one album source folder. Shape is
# flat on purpose (no FileInfo) so it round-trips through the cache file.
function Get-SourceShots([string]$folder) {
  $stamp = [string](Get-Item -LiteralPath $folder).LastWriteTimeUtc.Ticks
  $hit = $ScanCache[$folder]
  if ($hit -and ([string]$hit.stamp) -eq $stamp) {
    $script:scanHits++
    $script:ScanCacheNew[$folder] = $hit
    return @($hit.files | ForEach-Object {
      [pscustomobject]@{ Path = [string]$_.Path; Name = [string]$_.Name
                         Length = [long]$_.Length; Ticks = [string]$_.Ticks
                         Num = [string]$_.Num; Shot = [string]$_.Shot }
    })
  }
  $script:scanMisses++
  $found = @(Get-ChildItem -LiteralPath $folder -File | Where-Object {
      $_.Extension -match '(?i)^\.(jpe?g|png)$' -and $_.Name -match ' - (\d\d) (.+)\.[^.]+$'
    } | ForEach-Object {
      $m = [regex]::Match($_.Name, ' - (\d\d) (.+)\.[^.]+$')
      [pscustomobject]@{ Path = $_.FullName; Name = $_.Name
                         Length = $_.Length; Ticks = [string]$_.LastWriteTimeUtc.Ticks
                         Num = $m.Groups[1].Value; Shot = $m.Groups[2].Value }
    } | Where-Object { $ShotNums -contains $_.Num } |
      Sort-Object @{ e = { $ShotOrder.IndexOf($_.Num) } }, @{ e = { $_.Shot } })
  $script:ScanCacheNew[$folder] = [pscustomobject]@{ stamp = $stamp; files = $found }
  return $found
}

# Photos are collected across the whole build and processed in one batch after
# the album loop (see below), not album by album: 25 albums of nine photos
# would otherwise mean 25 barriers, the pool draining at the tail of each.
$ResizeJobs = New-Object System.Collections.ArrayList
$PendingManifests = New-Object System.Collections.ArrayList

$built = 0; $photosDone = 0; $photosSkipped = 0
$warnings = New-Object System.Collections.Generic.List[string]
# Three index pages: Personal Archive (/albums/, Collection tab), Available
# from Archive (/available/, For Sale tab) and Sold (/sold/, Sold tab). The
# sold index carries no prices and no listing links - it is the record of what
# the archive has documented and passed on, not a storefront.
# Collection cards are held as rows, not appended HTML: the Personal Archive
# is ordered by genre then artist after the loop (see below).
$collectionRows = New-Object System.Collections.ArrayList
$cardsAvailable = New-Object System.Text.StringBuilder
# Sold cards are held as rows, not appended HTML: they are ordered by the
# sheet's Date Sold column after the loop, newest sale first.
$soldRows = New-Object System.Collections.ArrayList
$collectionCount = 0; $availableCount = 0; $soldCount = 0; $unlistedCount = 0
$withdrawnCount = 0; $photosPurged = 0
$slugSet = @{}

foreach ($album in $json.albums) {
  $slug = $album.slug
  $slugSet[$slug] = $true
  $dir = Join-Path $Albums $slug

  # ----- withdrawn: tombstone, photos deleted, URL preserved -----
  # The slug stays in $slugSet so the prune leaves the directory alone: the
  # address must keep resolving, because it may sit in a Discogs listing
  # comment. The export carries only artist/title/slug for these rows, so
  # there is nothing here to render but the notice.
  if ([string]$album.status -eq 'withdrawn') {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
    $wImg = Join-Path $dir 'img'
    if (Test-Path $wImg) {
      [IO.Directory]::Delete((Convert-Path $wImg), $true)
      $photosPurged++
    }
    $t = $tplWithdrawn.Replace('{{ROOT}}', $RootAlbum)
    $t = $t.Replace('{{YEAR}}', "$year")
    $t = $t.Replace('{{MAIL_U}}', $MailUser).Replace('{{MAIL_D}}', $MailDomain)
    $t = $t.Replace('{{VCSS}}', $vCss).Replace('{{VJS}}', $vJs)
    Write-Utf8 (Join-Path $dir 'index.html') $t
    $withdrawnCount++
    $built++
    continue
  }

  $imgDir = Join-Path $dir 'img'
  $thumbDir = Join-Path $imgDir 't'
  # Absolute R2 base for this album's photos - the page HTML points here, not
  # at its own img/ directory (which is no longer published to Pages).
  # Public/owner: absolute R2 URLs. Private client: relative (served from the
  # private bucket via the Worker, behind Access), so the tree is host-portable.
  $imgUrl = if ($private) { 'img' } else { "$assetBase/albums/$slug/img" }
  foreach ($d in @($dir, $imgDir, $thumbDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null }
  }

  # ----- photos -----
  $srcFolder = $null
  if ($FolderOverrides.ContainsKey($slug)) {
    if (Test-Path $FolderOverrides[$slug]) {
      $srcFolder = $FolderOverrides[$slug]
    } else {
      $warnings.Add("$($album.artist) - $($album.title): folderOverrides path does not exist: $($FolderOverrides[$slug])")
    }
  }
  if ($null -eq $srcFolder) {
    foreach ($root in $PhotoRoots) {
      $candidate = Join-Path $root $album.folderName
      if (Test-Path $candidate) { $srcFolder = $candidate; break }
    }
  }
  $shots = @()
  if ($null -eq $srcFolder) {
    $warnings.Add("$($album.artist) - $($album.title): photo folder '$($album.folderName)' not found under any photo root - point to it in build.config.json: ""folderOverrides"": { ""$slug"": ""<full path>"" } (or add its parent folder to ""photoRoots"")")
  } else {
    $files = Get-SourceShots $srcFolder

    # incremental manifest: "name|length|mtimeticks" per source file, plus a
    # cfg entry - changing sizes/quality/watermark rebuilds every photo.
    $cfgKey = "cfg|$WebEdge|$ThumbEdge|$JpegQ|$Watermark|wm2"
    $maniFile = Join-Path $imgDir 'manifest.json'
    $old = @{}
    if ((Test-Path $maniFile) -and -not $Force) {
      (ConvertFrom-Json ([IO.File]::ReadAllText($maniFile))) | ForEach-Object { $old[$_] = $true }
    }
    if (-not $old.ContainsKey($cfgKey)) { $old = @{} }
    $newMani = @($cfgKey)
    $wanted = @{}
    foreach ($s in $files) {
      $outName = $s.Num + '-' + (Slugify $s.Shot) + '.jpg'
      $key = $s.Name + '|' + $s.Length + '|' + $s.Ticks
      $newMani += $key
      $wanted[$outName] = $true
      $web = Join-Path $imgDir $outName
      $thumb = Join-Path $thumbDir $outName
      if ($old.ContainsKey($key) -and (Test-Path $web) -and (Test-Path $thumb)) {
        $photosSkipped++
      } else {
        [void]$ResizeJobs.Add([pscustomobject]@{ Src = $s.Path; Web = $web; Thumb = $thumb })
        $photosDone++
      }
      $shots += [pscustomobject]@{ Name = $outName; Shot = $s.Shot }
    }
    # prune outputs whose source is gone
    Get-ChildItem $imgDir -File -Filter '*.jpg' | Where-Object { -not $wanted.ContainsKey($_.Name) } |
      ForEach-Object { Remove-Item $_.FullName -Force }
    Get-ChildItem $thumbDir -File -Filter '*.jpg' | Where-Object { -not $wanted.ContainsKey($_.Name) } |
      ForEach-Object { Remove-Item $_.FullName -Force }
    # Deferred until the photos actually exist - see the batch after this loop.
    [void]$PendingManifests.Add([pscustomobject]@{
      Path = $maniFile; Json = (ConvertTo-Json $newMani -Compress) })
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
    [void]$sb.AppendLine('    <figure class="hero-shot"><img src="' + $imgUrl + '/' + $hero.Name +
      '" data-caption="' + (HtmlEnc $hero.Shot) + '" alt="' +
      (HtmlEnc ($album.artist + ' - ' + $album.title + ': ' + $hero.Shot)) + '"></figure>')
    if ($shots.Count -gt 1) {
      [void]$sb.AppendLine('    <div class="strip">')
      foreach ($s in ($shots | Select-Object -Skip 1)) {
        [void]$sb.AppendLine('      <img src="' + $imgUrl + '/t/' + $s.Name + '" data-full="' + $imgUrl + '/' + $s.Name +
          '" data-caption="' + (HtmlEnc $s.Shot) + '" alt="' + (HtmlEnc $s.Shot) +
          '" loading="lazy">')
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

  $secStory = Section 'story' 'The Album' (Prose ([string]$album.albumStory))
  $secPressing = Section 'pressing' 'This Pressing' (Prose ([string]$album.lpNotes))
  $secLabel = Section 'label' 'The Label' (Prose ([string]$album.labelNotes))
  $secFidelity = Section 'fidelity' 'Fidelity' (Prose ([string]$album.fidelity))
  $secNotes = Section 'notes' 'Notes' (Prose ([string]$album.generalNotes))

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

  # For Sale albums link out to their live Discogs listing right after the
  # details table (2026-08-14, owner request). Outbound INTO a marketplace -
  # no prices, no off-platform selling; vanishes when the record sells.
  #
  # A Sold row usually still carries the URL of the listing it sold from, so
  # the tab decides the wording, not the presence of the link: a sold record
  # says so plainly and links nowhere, or the page would send a reader to a
  # listing that no longer exists.
  $listingSec = ''
  $dgUrl = [string]$album.discogsListingUrl
  $ebUrl = [string]$album.ebayItemUrl
  if ($album.tab -eq 'Sold') {
    $listingSec = Section 'availability' 'Availability' ('    <p class="prose">This record ' +
      'has been sold. Its documentation stays here.</p>')
  } elseif ($dgUrl -ne '' -or $ebUrl -ne '') {
    # One "listed for sale" line, one anchor per marketplace it is on, joined
    # with "or". A record may be on Discogs, eBay, or both.
    $links = New-Object System.Collections.Generic.List[string]
    if ($dgUrl -ne '') {
      [void]$links.Add('<a href="' + (HtmlEnc $dgUrl) +
        '" target="_blank" rel="noopener">view the listing on Discogs</a>')
    }
    if ($ebUrl -ne '') {
      [void]$links.Add('<a href="' + (HtmlEnc $ebUrl) +
        '" target="_blank" rel="noopener">view the listing on eBay</a>')
    }
    $listingSec = Section 'availability' 'Availability' ('    <p class="prose">This record ' +
      'is currently listed for sale: ' + ($links -join ' or ') + '.</p>')
  }

  # Section order per the owner's spec (2026-08-13): [Availability,]
  # Matrix/Runout, Condition, Variant chronology, This Pressing, The Album,
  # Tracklist, The Label, Fidelity, Notes.
  $content = $listingSec + $matrix + $condition + $chronology + $secPressing + $secStory +
    $tracklist + $secLabel + $secFidelity + $secNotes

  $page = $tplAlbum.Replace('{{ARTIST}}', $enc.artist).Replace('{{TITLE}}', $enc.title)
  $page = $page.Replace('{{SUBTITLE}}', $subtitle)
  $page = $page.Replace('{{META_DESC}}', (HtmlEnc $descSrc))
  $page = $page.Replace('{{CANONICAL}}', "$base/albums/$slug/")
  $robots = ''
  if (Test-Noindex $album) { $robots = "`n<meta name=""robots"" content=""noindex"">" }
  $page = $page.Replace('{{ROBOTS}}', $robots)
  # The site nav (per tenant). On an album page nothing is aria-current; a Sold
  # album still gets the Sold sublink so a reader can step back up to /sold/
  # rather than Available, then Sold, then find the card again. Build-Nav does
  # all of this - Collection and For Sale album pages get the plain nav.
  $page = $page.Replace('{{NAV}}', (Build-Nav 'album' $RootAlbum ([string]$album.tab)))
  $page = $page.Replace('{{GALLERY}}', $gallery).Replace('{{DETAILS}}', $details)
  $page = $page.Replace('{{CONTENT}}', $content)
  # No {{GENERATED}} here - album.html deliberately carries no build date, so
  # a page's bytes change only when its content does (see the note in the
  # template). The index pages and the sitemap still carry the date.
  $page = $page.Replace('{{YEAR}}', "$year")
  $page = $page.Replace('{{ROOT}}', $RootAlbum)
  $page = $page.Replace('{{MAIL_U}}', $MailUser).Replace('{{MAIL_D}}', $MailDomain)
  $page = $page.Replace('{{VCSS}}', $vCss).Replace('{{VJS}}', $vJs)
  Write-Utf8 (Join-Path $dir 'index.html') $page
  $built++

  # ----- index card -----
  $coverThumb = ''
  $firstCover = $shots | Where-Object { $_.Name -like '01-*' } | Select-Object -First 1
  if ($firstCover) {
    $coverThumb = if ($private) { "$slug/img/t/$($firstCover.Name)" }
                  else { "$assetBase/albums/$slug/img/t/$($firstCover.Name)" }
  }
  $search = (($album.artist + ' ' + $album.title + ' ' + $album.labelName + ' ' +
    $album.labelNumber + ' ' + $album.year + ' ' + $album.genre).ToLowerInvariant() -replace '\s+', ' ').Trim()
  $coverHtml = '<div class="cover"></div>'
  if ($coverThumb -ne '') {
    $coverHtml = '<div class="cover"><img src="' + $coverThumb + '" alt="" loading="lazy"></div>'
  }
  # The card's LINK is relative to the index page rendering it: /albums/ links
  # its own children directly; /available/ and /sold/ reach across with
  # ../albums/. (The cover IMAGE is now an absolute R2 URL, so it needs no such
  # prefix - the same cover markup serves every index.)
  # Cross-tab card link prefix. Private clients have a single /albums/ index
  # (all their records), so cards always link to <slug>/ with no prefix.
  $p = ''
  if (-not $private -and $album.tab -ne 'Collection') { $p = '../albums/' }
  $coverHtmlP = $coverHtml
  # Date Sold, on Sold cards only. ISO in the sheet, spelled out here - and
  # day-first with the month named, so no reader has to guess whether 08-09
  # means August or September. Anything that is not a clean ISO date is
  # treated as absent: it also drops the card to the end of the ordering.
  $sd = ''
  $soldLine = ''
  if ($album.tab -eq 'Sold') {
    $sd = ([string]$album.soldDate).Trim()
    if ($sd -notmatch '^\d{4}-\d{2}-\d{2}$') {
      $sd = ''
    } else {
      $soldLine = '<p class="sold">Sold ' + ([datetime]::ParseExact($sd, 'yyyy-MM-dd', $null).
        ToString('d MMMM yyyy', [Globalization.CultureInfo]::InvariantCulture)) + '</p>'
    }
  }
  $cardHtml = '<a class="card" href="' + $p + $slug + '/" data-search="' +
    (HtmlEnc $search) + '">' + $coverHtmlP + '<div class="meta"><p class="a">' + $enc.artist +
    '</p><p class="t">' + $enc.title + '</p><p class="y">' +
    (($enc.year, $enc.labelName | Where-Object { $_ -ne '' }) -join " $mid ") +
    '</p>' + $soldLine + '</div></a>'
  # Unlisted albums keep their page and their URL but get no card on any
  # index, whichever tab they sit on. Their sitemap entry and noindex are
  # handled by Test-Noindex above.
  if ($private) {
    # Private client: every record goes into the one collection index,
    # regardless of tab (they are not selling here).
    $primaryGenre = (([string]$album.genre).Trim() -split ' - ', 2)[0].Trim().ToLowerInvariant()
    [void]$collectionRows.Add([pscustomobject]@{
      Genre  = $primaryGenre
      Artist = ((([string]$album.artist).Trim() -replace '^(?i)the\s+', '')).ToLowerInvariant()
      Seq    = $collectionRows.Count; Html = $cardHtml
    })
    $collectionCount++
  } elseif (Test-Noindex $album) {
    $unlistedCount++
  } elseif ($album.tab -eq 'Collection') {
    # Ordering waits until every row is in - see below. Sort keys are held
    # lower-cased, and a leading "The " is dropped from the artist key so
    # bands like "The Band" file under B, not T.
    # Group on the primary genre only (the part before " - "), so every "jazz -
    # <subgenre>" files together and the artist sort keeps one artist adjacent
    # within it, rather than the subgenre string splitting them apart.
    $primaryGenre = (([string]$album.genre).Trim() -split ' - ', 2)[0].Trim().ToLowerInvariant()
    [void]$collectionRows.Add([pscustomobject]@{
      Genre  = $primaryGenre
      Artist = ((([string]$album.artist).Trim() -replace '^(?i)the\s+', '')).ToLowerInvariant()
      Seq    = $collectionRows.Count; Html = $cardHtml
    })
    $collectionCount++
  } elseif ($album.tab -eq 'For Sale') {
    # One listing link per marketplace the record is on; each stacks as its own
    # centred line under the card.
    $listing = ''
    $dgUrl = [string]$album.discogsListingUrl
    $ebUrl = [string]$album.ebayItemUrl
    if ($dgUrl -ne '') {
      $listing += '<p class="listing-link"><a href="' + (HtmlEnc $dgUrl) +
        '" target="_blank" rel="noopener">View listing on Discogs</a></p>'
    }
    if ($ebUrl -ne '') {
      $listing += '<p class="listing-link"><a href="' + (HtmlEnc $ebUrl) +
        '" target="_blank" rel="noopener">View listing on eBay</a></p>'
    }
    [void]$cardsAvailable.AppendLine('    <div class="card-wrap">' + $cardHtml + $listing + '</div>')
    $availableCount++
  } elseif ($album.tab -eq 'Sold') {
    # No listing link: the record is gone, only its documentation is still
    # here. Ordering waits until every row is in - see below.
    [void]$soldRows.Add([pscustomobject]@{
      Date = $sd; Seq = $soldRows.Count; Html = $cardHtml
    })
    $soldCount++
  }
}

# ---------- photos ----------
# Everything the album loop decided needs re-encoding, in one pass. Manifests
# are written only once this returns: if it throws, every album's manifest is
# left as it was and the next build redoes exactly this work.
if ($ResizeJobs.Count -gt 0) {
  Write-Host "Processing $($ResizeJobs.Count) photo(s) on $MaxWorkers worker(s)..."
}
Invoke-ResizeBatch $ResizeJobs
foreach ($m in $PendingManifests) { Write-Utf8 $m.Path $m.Json }

# ---------- index pages, landing, sitemap, data copy ----------
function CountLabel([int]$n) {
  if ($n -eq 1) { return '1 record' }
  return "$n records"
}
function Render-Index([string]$title, [string]$lede, [string]$desc,
    [string]$canonical, [string]$current, [string]$cardsHtml, [string]$outDir) {
  # $current is 'archive', 'available' or 'sold' - the section this index is.
  # Build-Nav marks it aria-current and, inside Available/Sold, shows the Sold
  # sublink (a sub-item under Available, per .nav-sec). The nav is per-tenant.
  $h = $tplIndex.Replace('{{PAGE_TITLE}}', $title).Replace('{{LEDE}}', $lede)
  $h = $h.Replace('{{META_DESC}}', $desc).Replace('{{CANONICAL}}', $canonical)
  $h = $h.Replace('{{NAV}}', (Build-Nav $current $RootIndex ''))
  $h = $h.Replace('{{CARDS}}', $cardsHtml).Replace('{{ROOT}}', $RootIndex)
  $h = $h.Replace('{{GENERATED}}', $genDate).Replace('{{YEAR}}', "$year")
  $h = $h.Replace('{{MAIL_U}}', $MailUser).Replace('{{MAIL_D}}', $MailDomain)
  $h = $h.Replace('{{VCSS}}', $vCss).Replace('{{VJS}}', $vJs)
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
  Write-Utf8 (Join-Path $outDir 'index.html') $h
}

# Personal Archive is ordered by genre, then artist (a leading "The" is
# ignored for the artist sort). Ties fall back to export order. Records with
# no genre yet sort to the top as an empty key.
$cardsCollection = New-Object System.Text.StringBuilder
foreach ($r in ($collectionRows |
    Sort-Object @{ Expression = 'Genre' },
                @{ Expression = 'Artist' },
                @{ Expression = 'Seq' })) {
  [void]$cardsCollection.AppendLine('    ' + $r.Html)
}

if ($private) {
  # Private client: one index titled with their collection name; no
  # public/for-sale framing, no Available/Sold split.
  Render-Index ([string]$tenantCfg.name) `
    ('Your collection, fully documented ' + $dash + ' every pressing photographed, the ' +
      'matrix transcribed by hand, and the exact pressing identified.') `
    'A private, documented vinyl collection.' `
    "$tenantBase/albums/" 'archive' $cardsCollection.ToString() $Albums
} else {
  Render-Index 'Personal Archive' `
    ("Albums added constantly as I transition my collection into the Archive system. " +
      "It's public to demonstrate the detail that it delivers in a real live collection " +
      "minus the valuation research which remains private.") `
    'A documented personal vinyl collection: original pressings photographed, transcribed, and researched.' `
    "$tenantBase/albums/" 'archive' $cardsCollection.ToString() $Albums
}

if (-not $private) {
Render-Index 'Available from Archive' `
  ("These are some albums I'm clearing out from my collection. They are currently listed for sale, " +
    "each photographed against a full checklist $dash covers, labels, dead-wax close-ups $dash the " +
    "matrix / runout transcribed by hand and the exact pressing identified against label " +
    "discographies and variant records. " +
    "Each card opens the full documentation; the live listings are on Discogs and eBay.") `
  'Documented vinyl records currently listed for sale on Discogs and eBay, with full pressing documentation.' `
  "$tenantBase/available/" 'available' $cardsAvailable.ToString() $AvailableDir

# Newest sale first. Date Sold arrives as ISO text from the sheet, so sorting
# the string sorts the date; anything else was normalised to blank above and
# keeps export order at the end - records sold before the column existed have
# no date to sort on, and guessing one would be a lie in a documented archive.
$cardsSold = New-Object System.Text.StringBuilder
$soldUndated = 0
foreach ($r in ($soldRows |
    Sort-Object @{ Expression = 'Date'; Descending = $true },
                @{ Expression = 'Seq'; Descending = $false })) {
  if ($r.Date -eq '') { $soldUndated++ }
  [void]$cardsSold.AppendLine('    ' + $r.Html)
}

# Sold sits under Available in the nav: the same records, one step further on.
# No prices, no listing links, no sold dates - just the documentation of a
# record this archive researched and passed on.
Render-Index 'Sold from Archive' `
  ((CountLabel $soldCount) + " that have found new homes $mid the record has gone, its documentation stays here.") `
  'Vinyl records previously sold from the archive, with their full pressing documentation kept online.' `
  "$tenantBase/sold/" 'sold' $cardsSold.ToString() $SoldDir
}  # end: Available + Sold indexes (public/owner only)

# ---------- owner-only global pages ----------
# The landing, About, 404, the root sitemap and the root collection.json copy
# ARE the owner site at the domain root. A client tenant renders only its own
# album + section pages under its prefix and must never write these.
if ($tenantCfg.slug -eq 'owner') {
# The landing leads with the pitch and hands off to the story; the record
# counts live on the section pages the nav points to, not on buttons here.
$land = $tplLanding.Replace('{{CANONICAL}}', "$base/")
$land = $land.Replace('{{GENERATED}}', $genDate).Replace('{{YEAR}}', "$year")
$land = $land.Replace('{{MAIL_U}}', $MailUser).Replace('{{MAIL_D}}', $MailDomain)
$land = $land.Replace('{{IMG}}', $assetBase)
$land = $land.Replace('{{VCSS}}', $vCss).Replace('{{VJS}}', $vJs)
Write-Utf8 (Join-Path $Site 'index.html') $land

# About / the story behind the archive: a single static page at /about/,
# generated like everything else so its stylesheet hash stays in step. {{ROOT}}
# is ../ because it sits one level down, same as the album and section pages.
$about = $tplAbout.Replace('{{CANONICAL}}', "$base/about/")
$about = $about.Replace('{{GENERATED}}', $genDate).Replace('{{YEAR}}', "$year")
$about = $about.Replace('{{MAIL_U}}', $MailUser).Replace('{{MAIL_D}}', $MailDomain)
$about = $about.Replace('{{VCSS}}', $vCss).Replace('{{VJS}}', $vJs)
$about = $about.Replace('{{ROOT}}', $RootIndex)
$aboutDir = Join-Path $Site 'about'
if (-not (Test-Path $aboutDir)) { New-Item -ItemType Directory $aboutDir | Out-Null }
Write-Utf8 (Join-Path $aboutDir 'index.html') $about

# 404: generated like everything else, so its stylesheet carries the same
# content hash and a returning visitor cannot render it against a stale one.
# It was hand-maintained until then, which is why it was the last page still
# linking an unversioned asset.
#
# Its paths are ABSOLUTE, unlike every other template. GitHub Pages serves
# this one file for a missing URL at ANY depth - /nope and /albums/nope/ both
# get it - so there is no single {{ROOT}} that could be right for both.
$nf = $tplNotFound.Replace('{{VCSS}}', $vCss).Replace('{{VJS}}', $vJs)
$nf = $nf.Replace('{{YEAR}}', "$year")
Write-Utf8 (Join-Path $Site '404.html') $nf

Copy-Item $DataFile (Join-Path $Site 'collection.json') -Force
}

# ---------- private client: self-contained assets + root page ----------
# A private client site is served entirely from the private bucket via the
# Worker, so it must carry its OWN copy of /assets and a root page (public/owner
# tenants use the repo's committed /assets and root index.html). The stylesheet
# hash (VCSS/VJS) in the pages is computed from these same files, so the copy
# matches.
if ($private) {
  $assetsDst = Join-Path $OutRoot 'assets'
  if (Test-Path $assetsDst) { Remove-Item $assetsDst -Recurse -Force }
  Copy-Item (Join-Path $Site 'assets') $assetsDst -Recurse -Force
  Copy-Item (Join-Path $Site 'favicon.svg') (Join-Path $OutRoot 'favicon.svg') -Force
  # Root of the subdomain -> the collection index.
  Write-Utf8 (Join-Path $OutRoot 'index.html') (
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="robots" content="noindex">' +
    '<meta http-equiv="refresh" content="0; url=albums/">' +
    '<title>' + (HtmlEnc ([string]$tenantCfg.name)) + '</title></head>' +
    '<body><a href="albums/">Enter your collection</a></body></html>')
}

# ---------- sitemap: per-tenant .urls.txt, assembled globally (B4) ----------
# Each PUBLIC (indexed) tenant records its indexed page URLs, with lastmod, in
# its own .urls.txt under its prefix; the global sitemap.xml is then rebuilt
# from EVERY tenant's file, so building one tenant never drops another's
# entries. Private tenants (indexed:false) contribute nothing - clients are
# served behind auth (Phase P) and must never appear in a public sitemap.
# Noindexed albums are left out: a sitemap entry asks a crawler to index the
# very page whose meta tag tells it not to. .urls.txt is gitignored.
$tenantRoot = if ($urlPrefix -ne '') { Join-Path $OutRoot ($urlPrefix -replace '/', '\') } else { $OutRoot }
$urlsFile = Join-Path $tenantRoot '.urls.txt'
if ($tenantCfg.indexed -eq $false) {
  if (Test-Path $urlsFile) { Remove-Item $urlsFile -Force }
} else {
  $secUrls = @("$tenantBase/")
  if ($tenantCfg.slug -eq 'owner') {
    $secUrls += @("$tenantBase/about/", "$tenantBase/albums/", "$tenantBase/available/", "$tenantBase/sold/")
  } else {
    foreach ($ix in @($tenantCfg.indexes)) { $secUrls += "$tenantBase/$(([string]$ix.path).Trim('/'))/" }
  }
  $albUrls = @($json.albums | Where-Object { -not (Test-Noindex $_) } |
    ForEach-Object { "$tenantBase/albums/$($_.slug)/" })
  $lines = @($secUrls + $albUrls | ForEach-Object { "$_`t$genDate" })
  Write-Utf8 $urlsFile (($lines -join "`n") + "`n")

  # Rebuild the global sitemap from every tenant's .urls.txt (owner's sorts
  # first, so its URLs keep their historical order).
  $sm = New-Object System.Text.StringBuilder
  [void]$sm.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
  [void]$sm.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
  foreach ($f in (Get-ChildItem -Path $Site -Recurse -Filter '.urls.txt' -Force | Sort-Object FullName)) {
    foreach ($ln in [IO.File]::ReadAllLines($f.FullName)) {
      if ($ln.Trim() -eq '') { continue }
      $parts = $ln -split "`t", 2
      [void]$sm.AppendLine("  <url><loc>$($parts[0])</loc><lastmod>$($parts[1])</lastmod></url>")
    }
  }
  [void]$sm.AppendLine('</urlset>')
  Write-Utf8 (Join-Path $Site 'sitemap.xml') $sm.ToString()
}

# ---------- prune removed albums ----------
# Scoped to THIS tenant's album dir ($Albums is per-tenant now), so a client
# build can never stage the owner's albums into _removed\ - the landmine in
# vinyl-site-multitenancy-design.md sec 1 #3. The empty-export guard above is
# the other half: a failed/partial export never reaches this prune at all.
$stale = @(Get-ChildItem $Albums -Directory | Where-Object { -not $slugSet.ContainsKey($_.Name) })
# A handful of removals is routine; a large share of the archive disappearing
# in one build usually means the export was partial. Nothing is deleted (it is
# staged in _removed\), but say so loudly before the push.
if ($stale.Count -gt 3 -and $stale.Count -gt ($slugSet.Count / 4)) {
  Write-Host ("WARNING: this build removes $($stale.Count) album page(s) but keeps only " +
    "$($slugSet.Count) - is the export complete?") -ForegroundColor Red
  $stale | ForEach-Object { Write-Host "         $($_.Name)" -ForegroundColor Red }
}
$stale | ForEach-Object {
    $hold = Join-Path $OutRoot ('_removed\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (-not (Test-Path $hold)) { New-Item -ItemType Directory $hold -Force | Out-Null }
    Move-Item $_.FullName (Join-Path $hold $_.Name)
    $warnings.Add("Removed album staged in _removed\: $($_.Name) (no longer in the export)")
  }

# ---------- persist the folder scan cache, release the workers ----------
# Only folders visited by this build are carried forward, so albums that leave
# the export drop out of the cache on their own.
Write-Utf8 $ScanCacheFile (ConvertTo-Json $ScanCacheNew -Depth 6 -Compress)

# ---------- report ----------
Write-Host ''
Write-Host "Built $built album page(s); photos: $photosDone converted, $photosSkipped unchanged." -ForegroundColor Green
Write-Host ("Source folders: $scanHits from cache, $scanMisses scanned " +
  "$mid photo workers: $MaxWorkers $mid elapsed $([int]$Elapsed.Elapsed.TotalSeconds)s") -ForegroundColor DarkGray
Write-Host ("Indexes: $collectionCount in the collection $mid $availableCount available " +
  "$mid $soldCount sold") -ForegroundColor DarkGray
if ($soldUndated -gt 0) {
  Write-Host ("$soldUndated sold record(s) have no Date Sold and sit at the end of /sold/ " +
    "in export order. Type a yyyy-mm-dd date in the Sold tab's Date Sold column to place " +
    "them.") -ForegroundColor Cyan
}
if ($unlistedCount -gt 0) {
  Write-Host "$unlistedCount album page(s) are unlisted: reachable by URL, absent from every index, the sitemap and search." -ForegroundColor Cyan
}
if ($withdrawnCount -gt 0) {
  Write-Host "$withdrawnCount album page(s) WITHDRAWN: replaced by a notice, $photosPurged photo folder(s) deleted. The URL still resolves." -ForegroundColor Magenta
  Write-Host "  Note: deleting the photos here does not remove them from this repository's git history." -ForegroundColor DarkGray
}
foreach ($w in $warnings) { Write-Host "WARNING: $w" -ForegroundColor Yellow }
Write-Host "Preview locally: powershell -ExecutionPolicy Bypass -File serve.ps1  ->  http://localhost:8322/"

if ($Push) {
  # Photos live in R2, not the repo. Push the current image tree to the bucket
  # BEFORE the git commit, so the pages we publish never reference a photo that
  # is not yet in the bucket. Only *.jpg is synced (manifests stay local); sync
  # also deletes bucket photos whose source album is gone, mirroring a prune.
  $rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
  if (-not $rclone) {
    $rclone = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
      Select-Object -First 1).FullName
  }
  if (-not $rclone) {
    throw 'rclone not found - install it (winget install Rclone.Rclone) so photos can sync to R2 before publishing.'
  }

  if ($private) {
    # Private client: sync the whole self-contained tree (pages + images +
    # assets) to the private bucket under the client's prefix. NOTHING goes to
    # the public repo. Build metadata (manifests, caches) is excluded.
    $target = 'r2:' + $ClientBucket + '/' + [string]$tenantCfg.slug
    Write-Host "Syncing private client tree to $target ..." -ForegroundColor DarkGray
    & $rclone sync $OutRoot $target --exclude '.foldercache.json' --exclude '**/manifest.json' `
      --exclude '.urls.txt' --exclude '_removed/**' --s3-no-check-bucket --transfers 16 --checkers 16 --stats-one-line
    if ($LASTEXITCODE -ne 0) {
      throw ("rclone sync to $target failed (exit $LASTEXITCODE) - the r2 remote's token must have " +
        "access to the '$ClientBucket' bucket.")
    }
    Write-Host "Published private client '$($tenantCfg.slug)'. Ensure a Cloudflare Access policy allows their email on $($tenantCfg.slug).vinylcurator.net." -ForegroundColor Green
    return
  }

  # Owner / public tenant: photos to the public image bucket, then git.
  Write-Host "Syncing photos to $R2Remote ..." -ForegroundColor DarkGray
  & $rclone sync $Albums $R2Remote --include '**/*.jpg' --s3-no-check-bucket --transfers 16 --checkers 16 --stats-one-line
  if ($LASTEXITCODE -ne 0) {
    throw "rclone sync to R2 failed (exit $LASTEXITCODE) - NOT committing, so the published pages never point at photos missing from the bucket."
  }

  Push-Location $Site
  try {
    git add -A
    git commit -m "publish $genDate ($built albums)"
    git push
  } finally { Pop-Location }
}
