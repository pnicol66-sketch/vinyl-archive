# One-time setup for the publish-failure email. Run it yourself, in a console:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup-publish-alert.ps1
#
# Needs a Gmail APP PASSWORD (Google Account > Security > 2-Step Verification >
# App passwords), never the account's own password. Saves
# publish-alert.local.xml (gitignored, DPAPI-encrypted to this Windows user)
# and sends a test email. Re-run it to change the address or the password.

. (Join-Path $PSScriptRoot 'publish-alert.ps1')

$from = (Read-Host 'Gmail address that SENDS the alert').Trim()
if ($from -eq '') { Write-Host 'No address - nothing saved.'; Read-Host 'Press Enter to close' | Out-Null; exit 1 }
$to = (Read-Host "Send alerts TO (press Enter for $from)").Trim()
if ($to -eq '') { $to = $from }

$cred = Get-Credential -UserName $from -Message 'Paste the 16-letter Gmail APP PASSWORD as the password'
if (-not $cred) { Write-Host 'Cancelled - nothing saved.'; Read-Host 'Press Enter to close' | Out-Null; exit 1 }

@{ From = $from; To = $to; Credential = $cred } | Export-Clixml -Path $AlertFile

$why = Send-PublishAlert 'vinylcurator.net publish alert - test' (
  "This is a test from setup-publish-alert.ps1 on $env:COMPUTERNAME.`r`n`r`n" +
  "If a queued site publish fails, an email like this names the export and what the build said.")
if ($why -eq '') {
  Write-Host "Saved. Test email sent to $to - check the inbox (and Spam)."
} else {
  Write-Host "Saved, but the test email FAILED: $why"
  Write-Host 'Check the app password (no spaces needed) and run this again.'
}
Read-Host 'Press Enter to close' | Out-Null
