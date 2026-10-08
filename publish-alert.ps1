# Email alert for a failed site publish. Dot-sourced by auto-publish.ps1 and
# setup-publish-alert.ps1.
#
# The sender, the recipient and the Gmail APP PASSWORD live in
# publish-alert.local.xml beside this file. It is gitignored and written by
# setup-publish-alert.ps1 with Export-Clixml, so the password is encrypted with
# Windows DPAPI: only this Windows user on this machine can read it (the
# publish task runs as that user). Nothing personal is in this public repo.

$AlertFile = Join-Path $PSScriptRoot 'publish-alert.local.xml'

# Returns '' when the email was sent, otherwise why it was not.
function Send-PublishAlert([string]$Subject, [string]$Body) {
  if (-not (Test-Path $AlertFile)) { return 'not set up - run setup-publish-alert.ps1' }
  try {
    $cfg = Import-Clixml $AlertFile
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $mail = @{
      SmtpServer    = 'smtp.gmail.com'
      Port          = 587
      UseSsl        = $true
      Credential    = $cfg.Credential
      From          = $cfg.From
      To            = $cfg.To
      Subject       = $Subject
      Body          = $Body
      Encoding      = [Text.Encoding]::UTF8
      WarningAction = 'SilentlyContinue'
      ErrorAction   = 'Stop'
    }
    Send-MailMessage @mail
    return ''
  } catch {
    return $_.Exception.Message
  }
}

# The sheet's own link (optional, saved by setup-publish-alert.ps1), else ''.
function Get-AlertSheetUrl {
  try { if (Test-Path $AlertFile) { return [string](Import-Clixml $AlertFile).SheetUrl } } catch {}
  return ''
}

# The sheet column behind each exported field (the export's own key names).
$ProseColumns = @{
  artist = 'Artist'; title = 'Title'; year = 'Year'; labelName = 'Label Name'
  labelNumber = 'Label Number'; monoStereo = 'Mono/Stereo'; countryOfOrigin = 'Country Of Origin'
  format = 'Format'; genre = 'Genre'; speed = 'Speed'; producer = 'Producer'; composer = 'Composer'
  conductor = 'Conductor'; performerOrchestra = 'Performer/Orchestra'; musicians = 'Musicians'
  coverGrade = 'Cover Grade'; vinylGrade = 'Vinyl Grade'; albumStory = 'Album Story'
  lpNotes = 'LP Notes'; labelNotes = 'Label Notes'; fidelity = 'Fidelity'
  generalNotes = 'General Notes'; variantChronology = 'Label Variant Hierarchy'
}

function Get-ProseColumn([string]$path) {
  if ($path -match '^sides\[(\d)\]') { return 'Side ' + ([int]$Matches[1] + 1) }
  if ($path -match '^matrix\.([a-d])') { return 'the side ' + $Matches[1].ToUpper() + ' runout (matrix) cell' }
  $k = ($path -split '[.\[]')[0]
  if ($ProseColumns.ContainsKey($k)) { return $ProseColumns[$k] }
  return $path
}

# What the flagged words are doing wrong, in plain terms.
function Get-ProseHint([string]$text) {
  $h = @()
  if ($text -match '(?i)photo|picture|image') { $h += 'it mentions the photographs - say what the label or cover shows, not that a photo shows it' }
  if ($text -match '(?i)\btyped\b|transcri') { $h += 'it refers to the typed runout - describe the runout itself ("the runout reads ...")' }
  if ($text -match '(?i)collector|\byou\b|\byour\b') { $h += 'it speaks to the collector - write it as a plain fact about the record' }
  if ($text -match '(?i)\b(check|checked|confirm|confirmed|unconfirmed|verif\w*|flag\w*|recheck\w*)\b') { $h += 'it describes the checking - keep the fact, drop how it was checked' }
  if ($text -match '(?i)\b(likely|probably|possibly|documented|catalogued as)\b|\bper [A-Z]') { $h += 'it hedges or cites - state the value plainly, or leave the clause out' }
  if ($text -match '(?i)https?:|www\.|\.(com|net|org)\b') { $h += 'it carries a web address - remove it' }
  if ($h.Count -eq 0) { $h += 'it says where a fact came from or how it was checked - keep the fact, drop the source or the checking' }
  $h
}

# One entry per field the site build refused (its "PROSE: slug.field: ...text..."
# lines), with the album, tab, column, the flagged words and what to change.
# '' when the build failed for another reason.
function Get-ProseGuidance($lines, $albums) {
  $hits = @($lines | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_ -match '^PROSE: ' } | Select-Object -Unique)
  $out = @(); $n = 0
  foreach ($hl in $hits) {
    if ($hl -notmatch '^PROSE: ([^.\s]+)\.(\S+): \.\.\.(.*)\.\.\.$') { continue }
    $slug = $Matches[1]; $path = $Matches[2]; $ex = $Matches[3].Trim()
    $a = @($albums | Where-Object { [string]$_.slug -eq $slug }) | Select-Object -First 1
    $n++
    if ($a) {
      $name = "$($a.artist) - $($a.title)"
      $where = "tab: $($a.tab)"
      if ($a.folderName) { $where += ", folder: $($a.folderName)" }
    } else { $name = $slug; $where = 'not found in the export' }
    $out += "$n. $name   ($where)"
    $out += "   Column:   " + (Get-ProseColumn $path)
    $out += "   Flagged:  `"...$ex...`""
    foreach ($h in (Get-ProseHint $ex)) { $out += "   Fix:      $h" }
    $out += ''
  }
  $out -join "`r`n"
}

# The email for an export the watcher is holding: @{ Subject; Body }.
function New-HoldAlert([string]$gen, [string]$published, [string]$failure, [string]$guide, [string]$sheetUrl, [string]$logFile) {
  $nl = "`r`n"
  $live = if ($published) { $published } else { '(unknown)' }
  $open = if ($sheetUrl) { "Open the sheet: $sheetUrl" } else { 'Open the production sheet.' }
  $b = @('The vinylcurator.net publish FAILED 3 times on the same export and is holding.', '',
    "Export:        $gen", "Live site is:  the export of $live", '')
  if ($guide) {
    $count = @([regex]::Matches($guide, '(?m)^\d+\. ')).Count
    $subject = "vinylcurator.net publish FAILED - $count field(s) to fix"
    $b += 'WHAT TO FIX', 'The site build refuses text that names where a fact came from, mentions the photographs or',
      'the checking, or speaks to the collector. Each field below says what the record IS once fixed;',
      'keep every fact, change only the flagged words.', '', $guide.TrimEnd(), '',
      'HOW TO FIX', "1. $open",
      '2. Menu Vinyl Curator > Check catalogue prose (read only). Tick the album(s) above and click the',
      '   button that rewrites the ticked rows. Or edit the column named above by hand.',
      '3. Menu Website > Publish Vinyl Site... - a new export clears the hold, and the site is live',
      '   about 3-4 minutes later. If anything is still refused, another email like this names it.'
  } else {
    $subject = "vinylcurator.net publish FAILED (export $gen)"
    $b += 'HOW TO FIX', "1. $open",
      '2. Read what the build said below. If it names something in the sheet, fix it there.',
      '   If it is a network or GitHub error, it usually clears by itself - just publish again.',
      '3. Menu Website > Publish Vinyl Site... again.',
      '   A new export clears the hold.'
  }
  $reason = if ($failure) { $failure } else { '(not captured - see the log)' }
  $b += '', 'What the build said:', $reason, '', "Full log: $logFile on $env:COMPUTERNAME"
  @{ Subject = $subject; Body = ($b -join $nl) }
}

# The lines of a build's output that say why it failed, else its last lines.
function Get-FailureSummary($lines) {
  $all = @($lines | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_ -ne '' })
  $keep = @($all | Where-Object {
      $_ -match '^(PROSE|ERROR|FAIL)|FullyQualifiedErrorId|failed|refused|rejected|fatal:'
    } | Select-Object -Unique -First 25)
  if ($keep.Count -eq 0) { $keep = @($all | Select-Object -Last 15) }
  ($keep | ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + '...' } else { $_ } }) -join "`r`n"
}
