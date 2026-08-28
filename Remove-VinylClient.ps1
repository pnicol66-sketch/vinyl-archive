# Offboard a private client in one command (PowerShell 5.1, no dependencies).
#
# The reverse of New-VinylClient.ps1: a total takedown of one client's private
# site. Purges their R2 bucket prefix, deletes their Cloudflare Access app,
# Worker route and DNS record, and removes their entry from tenants.json /
# build.config.json. Nothing of theirs was ever in the public repo, so this
# leaves no trace. See CLIENT-ONBOARDING.md section D.
#
#   .\Remove-VinylClient.ps1 -Slug smith            # prompts once, then deletes
#   .\Remove-VinylClient.ps1 -Slug smith -WhatIf    # show what would be deleted
#   .\Remove-VinylClient.ps1 -Slug smith -Force     # no prompt (scripted)
#
# DESTRUCTIVE and IRREVERSIBLE (real deletion from a private bucket). Idempotent:
# anything already gone is reported and skipped. Refuses to touch 'owner'.
# Needs the same Cloudflare token as New-VinylClient (CF_API_TOKEN or a gitignored
# cf-api.local.json).

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-z0-9-]+$')]
  [string]$Slug,

  # Skip the confirmation prompt (for scripted teardowns).
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------- constants ----------
$AccountId    = '0c94e84d9739eea5ffda13ecc647393e'
$ZoneName     = 'vinylcurator.net'
$ClientBucket = 'vinyl-client'
$Site         = Split-Path -Parent $MyInvocation.MyCommand.Path
$Fqdn         = "$Slug.$ZoneName"

if ($Slug -eq 'owner') { throw "Refusing to offboard 'owner' - that is the public site, not a client." }

# ---------- helpers ----------
function ReadJson([string]$path) { return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
function WriteUtf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false))) }
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

# ---------- Cloudflare client (never logs the token) ----------
$script:Token   = $env:CF_API_TOKEN
if (-not $script:Token) {
  $tf = Join-Path $Site 'cf-api.local.json'
  if (Test-Path $tf) { try { $script:Token = (ReadJson $tf).token } catch { } }
}
$script:HaveTok = [bool]$script:Token
function Invoke-CF {
  param([string]$Method, [string]$Path)
  if (-not $script:HaveTok) { throw "No Cloudflare token loaded - cannot call the API." }
  $uri = 'https://api.cloudflare.com/client/v4' + $Path
  $headers = @{ Authorization = "Bearer $script:Token" }
  try { $resp = Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' }
  catch {
    $detail = ''
    try { $detail = $_.ErrorDetails.Message } catch { }
    if (-not $detail) { $detail = $_.Exception.Message }
    throw ("Cloudflare $Method $Path failed: " + $detail)
  }
  if ($resp -and ($resp.PSObject.Properties.Name -contains 'success') -and (-not $resp.success)) {
    throw ("Cloudflare $Method $Path returned errors: " + ($resp.errors | ConvertTo-Json -Compress))
  }
  return $resp.result
}
function Find-Rclone {
  $r = (Get-Command rclone -ErrorAction SilentlyContinue).Source
  if (-not $r) {
    $r = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
      Select-Object -First 1).FullName
  }
  return $r
}

# Remove one tenant object from tenants.json text, preserving the rest of the
# file's formatting (line-based; the file keeps 4-space object indentation and
# the slug on its own line). Returns $null if the slug isn't present.
function Remove-TenantBlock([string]$raw, [string]$slug) {
  $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
  $lines = $raw -split "`r?`n"
  $slugRe = '^\s{6}"slug":\s*"' + [regex]::Escape($slug) + '"\s*,?\s*$'
  $si = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $slugRe) { $si = $i; break } }
  if ($si -lt 0) { return $null }
  # expand to the enclosing object: up to a lone '    {', down to '    }' / '    },'
  $start = $si; while ($start -ge 0 -and $lines[$start] -notmatch '^\s{4}\{\s*$') { $start-- }
  $end = $si;   while ($end -lt $lines.Count -and $lines[$end] -notmatch '^\s{4}\},?\s*$') { $end++ }
  if ($start -lt 0 -or $end -ge $lines.Count) { return $null }
  $removedWasLast = ($lines[$end] -notmatch ',\s*$')   # its close brace had no trailing comma
  $keep = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -lt $start -or $i -gt $end) { $keep.Add($lines[$i]) } }
  if ($removedWasLast) {
    # the object before it is now last: strip its trailing comma ('    },' -> '    }')
    for ($i = $keep.Count - 1; $i -ge 0; $i--) {
      if ($keep[$i] -match '^\s{4}\},\s*$') { $keep[$i] = ($keep[$i] -replace ',\s*$', ''); break }
      elseif ($keep[$i] -match '^\s{4}\}\s*$') { break }
    }
  }
  return ($keep -join $nl)
}

# =====================================================================
Say ""
Say ("=== Offboard '$Slug'  (https://$Fqdn) ===") 'Cyan'

# ---------- discover what exists (read-only) ----------
$ZoneId = $null; $app = $null; $route = $null; $dns = $null
if ($script:HaveTok) {
  $zones = @(Invoke-CF GET "/zones?name=$ZoneName")
  if ($zones.Count -gt 0) { $ZoneId = $zones[0].id }
  if ($ZoneId) {
    $app   = @(Invoke-CF GET "/accounts/$AccountId/access/apps")     | Where-Object { $_.domain -eq $Fqdn } | Select-Object -First 1
    $route = @(Invoke-CF GET "/zones/$ZoneId/workers/routes")        | Where-Object { $_.pattern -eq "$Fqdn/*" } | Select-Object -First 1
    $dns   = @(Invoke-CF GET "/zones/$ZoneId/dns_records?type=AAAA&name=$Fqdn") | Select-Object -First 1
  }
} else {
  Say "  WARN  no Cloudflare token - can only remove the local tenant entry + purge the bucket." 'Yellow'
}
$rclone = Find-Rclone
$bucketCount = $null
if ($rclone) {
  $files = & $rclone lsf "r2:$ClientBucket/$Slug/" 2>$null
  if ($LASTEXITCODE -eq 0) { $bucketCount = @($files).Count }
}
$TenantsFile = Join-Path $Site 'tenants.json'
$inTenants = $false
if (Test-Path $TenantsFile) { $inTenants = [bool](@((ReadJson $TenantsFile).tenants) | Where-Object { $_.slug -eq $Slug }) }

# ---------- summary ----------
Say ""
Say "Will delete:" 'Yellow'
Say ("  bucket    r2:$ClientBucket/$Slug/   " + $(if ($null -eq $bucketCount) { '(rclone unavailable - will attempt purge)' } elseif ($bucketCount -eq 0) { '(empty / already gone)' } else { "($bucketCount top-level entries)" }))
Say ("  Access    " + $(if ($app) { "app " + $app.id } else { '(none)' }))
Say ("  route     " + $(if ($route) { $route.id } else { '(none)' }))
Say ("  DNS       " + $(if ($dns) { $dns.id } else { '(none)' }))
Say ("  tenant    " + $(if ($inTenants) { "tenants.json entry '$Slug' (+ build.config.json photoRoots)" } else { '(not in tenants.json)' }))

if ($WhatIfPreference) { Say ""; Say "(-WhatIf: nothing deleted.)" 'Yellow'; return }

if (-not $Force) {
  if (-not $PSCmdlet.ShouldProcess($Fqdn, "PERMANENTLY DELETE bucket + Access app + route + DNS + tenant entry")) {
    Say "Aborted - nothing deleted." 'Yellow'; return
  }
}

# =====================================================================
# Delete, most-destructive data first, then wiring, then local files
# =====================================================================
Say ""
# --- bucket ---
if ($rclone) {
  & $rclone purge "r2:$ClientBucket/$Slug/" 2>$null
  if ($LASTEXITCODE -eq 0) { Say "OK  purged r2:$ClientBucket/$Slug/" 'Green' }
  else { Say "..  bucket purge returned non-zero (may have been empty already)" 'DarkGray' }
} else { Say "SKIP  rclone not found - purge r2:$ClientBucket/$Slug/ by hand" 'Yellow' }

# --- Access app (deletes its inline policy with it) ---
if ($app) { Invoke-CF DELETE "/accounts/$AccountId/access/apps/$($app.id)" | Out-Null; Say "OK  deleted Access app $($app.id)" 'Green' }
elseif ($script:HaveTok) { Say "SKIP  no Access app" 'DarkGray' }

# --- Worker route ---
if ($route) { Invoke-CF DELETE "/zones/$ZoneId/workers/routes/$($route.id)" | Out-Null; Say "OK  deleted route $($route.id)" 'Green' }
elseif ($script:HaveTok) { Say "SKIP  no route" 'DarkGray' }

# --- DNS ---
if ($dns) { Invoke-CF DELETE "/zones/$ZoneId/dns_records/$($dns.id)" | Out-Null; Say "OK  deleted DNS $($dns.id)" 'Green' }
elseif ($script:HaveTok) { Say "SKIP  no DNS record" 'DarkGray' }

# --- tenants.json ---
if ($inTenants) {
  $raw = [IO.File]::ReadAllText($TenantsFile, [Text.Encoding]::UTF8)
  $new = Remove-TenantBlock $raw $Slug
  if ($null -eq $new) { Say "WARN  could not locate the '$Slug' block in tenants.json - remove it by hand" 'Yellow' }
  else {
    $check = $new | ConvertFrom-Json   # fail loudly rather than write invalid JSON
    if (@($check.tenants | Where-Object { $_.slug -eq $Slug })) { throw "tenants.json removal left '$Slug' behind - aborting write." }
    WriteUtf8 $TenantsFile $new
    Say "OK  removed '$Slug' from tenants.json" 'Green'
  }
} else { Say "SKIP  not in tenants.json" 'DarkGray' }

# --- build.config.json photoRoots (gitignored) ---
$ConfigFile = Join-Path $Site 'build.config.json'
if (Test-Path $ConfigFile) {
  $cfg = ReadJson $ConfigFile
  if (($cfg.PSObject.Properties.Name -contains 'tenants') -and ($cfg.tenants.PSObject.Properties.Name -contains $Slug)) {
    $cfg.tenants.PSObject.Properties.Remove($Slug)
    WriteUtf8 $ConfigFile ($cfg | ConvertTo-Json -Depth 10)
    Say "OK  removed '$Slug' from build.config.json" 'Green'
  } else { Say "SKIP  no build.config.json photoRoots for '$Slug'" 'DarkGray' }
}

Say ""
Say "Offboarded '$Slug' - total takedown complete." 'Green'
Say "Manual leftovers to tidy if you want: the collection-$Slug.json export and the" 'DarkGray'
Say "Drive shortcut under 'Vinyl Curator Clients\$Slug' are yours to keep or delete." 'DarkGray'
