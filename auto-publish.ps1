# Publish vinylcurator.net from the latest sheet export.
#
# RUNS AUTOMATICALLY. Scheduled task "Vinyl Site Publish Queue" fires every
# 2 minutes (PT2M) via publish-launcher.vbs, which wscript runs windowless -
# that launcher is what replaced the bare powershell.exe task whose console
# flash the user found noisy. The task is not retired; only the flash is.
# The "Publish Vinyl Site" desktop shortcut runs this with -Manual for an
# immediate, visible run.
#
# It logs ONLY when it publishes or fails, so silence in autopublish.log
# means "nothing to do", never "not running". To check it is alive, ask the
# task: Get-ScheduledTaskInfo -TaskName 'Vinyl Site Publish Queue' reports
# LastRunTime and LastTaskResult (0 = fine). Reading the log inside the
# 2-minute window and concluding the watcher is dead is a mistake already
# made once, at the cost of a redundant manual build.
#
# Reads the export's "generated" stamp; when it differs from the last
# published stamp, runs build.ps1 -Push. -Manual shows progress in the
# console, always attempts (ignores the automatic 3-strike hold), and
# waits for a key so the result can be read. Log: autopublish.log here.
# Delete .autopublish-state.json to force a republish.

param([switch]$Manual)

$Site = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataFile = 'G:\My Drive\Vinyl Curator Website\collection.json'
$RequestFile = 'G:\My Drive\Vinyl Curator Website\publish-request.json'
$StateFile = Join-Path $Site '.autopublish-state.json'
$LogFile = Join-Path $Site 'autopublish.log'

function Log([string]$msg) {
  Add-Content -Path $LogFile -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg)
  if ($Manual) { Write-Host $msg }
}
function Finish([int]$code) {
  if ($Manual) { Read-Host 'Press Enter to close' | Out-Null }
  exit $code
}

# Skip when Drive is not mounted or the file is mid-sync.
try {
  if (-not (Test-Path $DataFile)) {
    if ($Manual) { Write-Host "Export file not found: $DataFile (is Google Drive running?)" }
    Finish 0
  }
  $json = [IO.File]::ReadAllText($DataFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $gen = [string]$json.generated
  if ($gen -eq '') { Finish 0 }
} catch {
  if ($Manual) { Write-Host 'Could not read the export (mid-sync?) - try again in a minute.' }
  Finish 0
}

$state = @{ published = ''; attempted = ''; attempts = 0 }
if (Test-Path $StateFile) {
  try {
    $s = Get-Content -Raw $StateFile | ConvertFrom-Json
    $state.published = [string]$s.published
    $state.attempted = [string]$s.attempted
    $state.attempts = [int]$s.attempts
  } catch {}
}
# Scheduled (windowless) mode acts ONLY on a publish request queued by the
# sheet's "Website > Publish Vinyl Site..." item; the desktop shortcut
# (-Manual) publishes the latest export regardless.
if (-not $Manual) {
  try {
    if (-not (Test-Path $RequestFile)) { exit 0 }
    $req = Get-Content -Raw $RequestFile | ConvertFrom-Json
    $reqGen = [string]$req.generated
  } catch { exit 0 }
  if ($reqGen -eq '' -or $reqGen -eq $state.published) { exit 0 }
  if ($reqGen -ne $gen) { exit 0 }   # export file still syncing - next tick
}

if ($gen -eq $state.published) {
  if ($Manual) { Write-Host "Site is already up to date with the latest export ($gen)." }
  Finish 0
}
if (-not $Manual -and $gen -eq $state.attempted -and $state.attempts -ge 3) { exit 0 }

Log "new export detected (generated $gen) - building"
try { git -C $Site pull --rebase --autostash | Out-Null } catch {}
if ($Manual) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Site 'build.ps1') -Push *>&1 |
    Tee-Object -Variable buildOut | Out-Host
  $buildOut | Out-String -Stream | Out-File -FilePath $LogFile -Append -Encoding utf8
} else {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Site 'build.ps1') -Push *>&1 |
    Out-String -Stream | Out-File -FilePath $LogFile -Append -Encoding utf8
}
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

Finish 0
