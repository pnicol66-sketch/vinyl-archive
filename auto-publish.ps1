# Auto-publish watcher for vinylcurator.net (run by the "Vinyl Archive
# Auto-Publish" scheduled task every 5 minutes).
#
# Reads the export's "generated" stamp; when it differs from the last
# published stamp, runs build.ps1 -Push. A failing export is retried on the
# next two ticks, then held until a NEW export appears (see autopublish.log
# in this folder). Delete .autopublish-state.json to force a republish.

$Site = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataFile = 'G:\My Drive\Vinyl Curator Website\collection.json'
$StateFile = Join-Path $Site '.autopublish-state.json'
$LogFile = Join-Path $Site 'autopublish.log'

function Log([string]$msg) {
  Add-Content -Path $LogFile -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg)
}

# Silently skip when Drive is not mounted or the file is mid-sync.
try {
  if (-not (Test-Path $DataFile)) { exit 0 }
  $json = [IO.File]::ReadAllText($DataFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $gen = [string]$json.generated
  if ($gen -eq '') { exit 0 }
} catch { exit 0 }

$state = @{ published = ''; attempted = ''; attempts = 0 }
if (Test-Path $StateFile) {
  try {
    $s = Get-Content -Raw $StateFile | ConvertFrom-Json
    $state.published = [string]$s.published
    $state.attempted = [string]$s.attempted
    $state.attempts = [int]$s.attempts
  } catch {}
}
if ($gen -eq $state.published) { exit 0 }
if ($gen -eq $state.attempted -and $state.attempts -ge 3) { exit 0 }

Log "new export detected (generated $gen) - building"
try { git -C $Site pull --rebase --autostash | Out-Null } catch {}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Site 'build.ps1') -Push *>&1 |
  Out-String -Stream | Out-File -FilePath $LogFile -Append -Encoding utf8
if ($LASTEXITCODE -eq 0) {
  $state.published = $gen; $state.attempted = ''; $state.attempts = 0
  Log "published $gen"
} else {
  $state.attempted = $gen; $state.attempts = $state.attempts + 1
  Log ("BUILD/PUSH FAILED (attempt " + $state.attempts + " of 3) - see output above")
  if ($state.attempts -ge 3) { Log "holding until a new export appears" }
}
@{ published = $state.published; attempted = $state.attempted; attempts = $state.attempts } |
  ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8

# Cap the log.
try {
  $lines = @(Get-Content $LogFile)
  if ($lines.Count -gt 800) { $lines[-500..-1] | Set-Content $LogFile -Encoding UTF8 }
} catch {}
