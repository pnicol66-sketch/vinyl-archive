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

# The lines of a build's output that say why it failed, else its last lines.
function Get-FailureSummary($lines) {
  $all = @($lines | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_ -ne '' })
  $keep = @($all | Where-Object {
      $_ -match '^(PROSE|ERROR|FAIL)|FullyQualifiedErrorId|failed|refused|rejected|fatal:'
    } | Select-Object -Unique -First 25)
  if ($keep.Count -eq 0) { $keep = @($all | Select-Object -Last 15) }
  ($keep | ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + '...' } else { $_ } }) -join "`r`n"
}
