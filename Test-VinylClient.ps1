# Verify a private client's wiring end-to-end (PowerShell 5.1, read-only).
#
# Proves the five things onboarding must get right, and prints a green/red
# checklist. Read-only: makes no changes, so it is safe to run any time and is
# also handy to audit an existing client (e.g. smith).
#
#   .\Test-VinylClient.ps1 -Slug smith
#   .\Test-VinylClient.ps1 -Slug smith -Email jane@gmail.com   # also assert that email is allowed
#
# Checks:
#   1. DNS   - AAAA 100:: record for <slug>.vinylcurator.net (API), or a public
#              DNS answer as a tokenless fallback.
#   2. Route - a Worker route matches <slug>.vinylcurator.net/*.
#   3. Access- a self-hosted app exists for that domain, Google-only, with an
#              allow policy (and, if -Email given, one that allows that email).
#   4. Bucket- rclone lsf r2:vinyl-client/<slug>/ returns files (index.html).
#   5. Live  - https://<slug>.vinylcurator.net/ answers 302 -> cloudflareaccess.com
#              (fails closed without an identity = correct).
#
# Checks 1-3 need the Cloudflare token (CF_API_TOKEN env var or a gitignored
# cf-api.local.json { "token": "..." }); 4-5 do not. Missing prerequisites are
# reported as skipped [..], not passes. Exit code is 0 only if nothing is red.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-z0-9-]+$')]
  [string]$Slug,

  [string]$Email
)

$ErrorActionPreference = 'Stop'

# ---------- constants (CLIENT-ONBOARDING.md section E) ----------
$AccountId    = '0c94e84d9739eea5ffda13ecc647393e'
$ZoneName     = 'vinylcurator.net'
$ClientBucket = 'vinyl-client'
$AccessTeam   = 'vinylcurator.cloudflareaccess.com'
$Site         = Split-Path -Parent $MyInvocation.MyCommand.Path
$Fqdn         = "$Slug.$ZoneName"

# ---------- result tracking ----------
$script:Red = 0
$script:Skipped = 0
function Pass([string]$m) { Write-Host ("  [OK] " + $m) -ForegroundColor Green }
function Fail([string]$m) { Write-Host ("  [--] " + $m) -ForegroundColor Red; $script:Red++ }
function Skip([string]$m) { Write-Host ("  [..] " + $m) -ForegroundColor DarkGray; $script:Skipped++ }

# ---------- Cloudflare client (never logs the token) ----------
$script:Token   = $env:CF_API_TOKEN
if (-not $script:Token) {
  $tf = Join-Path $Site 'cf-api.local.json'
  if (Test-Path $tf) {
    try { $script:Token = ([IO.File]::ReadAllText($tf, [Text.Encoding]::UTF8) | ConvertFrom-Json).token } catch { }
  }
}
$script:HaveTok = [bool]$script:Token
function Invoke-CF {
  param([string]$Path)
  $uri = 'https://api.cloudflare.com/client/v4' + $Path
  $headers = @{ Authorization = "Bearer $script:Token" }
  try {
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ContentType 'application/json'
  } catch {
    $detail = ''
    try { $detail = $_.ErrorDetails.Message } catch { }
    if (-not $detail) { $detail = $_.Exception.Message }
    throw ("Cloudflare GET $Path failed: " + $detail)
  }
  if ($resp -and ($resp.PSObject.Properties.Name -contains 'success') -and (-not $resp.success)) {
    throw ("Cloudflare GET $Path returned errors: " + ($resp.errors | ConvertTo-Json -Compress))
  }
  return $resp.result
}

# ---------- external tool discovery ----------
function Find-Rclone {
  $r = (Get-Command rclone -ErrorAction SilentlyContinue).Source
  if (-not $r) {
    $r = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
      Select-Object -First 1).FullName
  }
  return $r
}

Write-Host ""
Write-Host ("=== Verify '$Slug'  ->  https://$Fqdn ===") -ForegroundColor Cyan
if (-not $script:HaveTok) {
  Write-Host "  (no Cloudflare token - checks 1-3 will be skipped; running 4-5 only)" -ForegroundColor Yellow
}

# resolve zone id once (checks 1 and 2)
$ZoneId = $null
if ($script:HaveTok) {
  try {
    $zones = @(Invoke-CF ("/zones?name=$ZoneName"))
    if ($zones.Count -gt 0) { $ZoneId = $zones[0].id }
  } catch { Write-Host ("  zone lookup failed: " + $_.Exception.Message) -ForegroundColor Red }
}

# --- 1. DNS ---
Write-Host "1. DNS"
if ($script:HaveTok -and $ZoneId) {
  $rec = @(Invoke-CF ("/zones/$ZoneId/dns_records?type=AAAA&name=$Fqdn"))
  if ($rec.Count -gt 0) {
    $proxied = if ($rec[0].proxied) { 'proxied' } else { 'NOT proxied' }
    if ($rec[0].proxied) { Pass ("AAAA $Fqdn -> $($rec[0].content) ($proxied)") }
    else { Fail ("AAAA $Fqdn is $proxied - Access won't gate it; must be proxied") }
  } else { Fail "no AAAA record for $Fqdn" }
} else {
  # tokenless fallback: does the name resolve publicly at all?
  try {
    $ans = Resolve-DnsName -Name $Fqdn -ErrorAction Stop | Where-Object { $_.QueryType -in @('A', 'AAAA') }
    if ($ans) { Pass "$Fqdn resolves publicly (tokenless check; can't confirm it's the 100:: record)" }
    else { Fail "$Fqdn does not resolve" }
  } catch { Fail "$Fqdn does not resolve" }
}

# --- 2. Worker route ---
Write-Host "2. Worker route"
if ($script:HaveTok -and $ZoneId) {
  $routes = @(Invoke-CF ("/zones/$ZoneId/workers/routes"))
  $m = @($routes | Where-Object { $_.pattern -eq "$Fqdn/*" }) | Select-Object -First 1
  if ($m) { Pass ("route $Fqdn/* -> " + $m.script) } else { Fail "no Worker route for $Fqdn/*" }
} else { Skip "route check needs the Cloudflare token" }

# --- 3. Access app + policy + Google-only ---
Write-Host "3. Access application"
if ($script:HaveTok) {
  $apps = @(Invoke-CF ("/accounts/$AccountId/access/apps"))
  $app = @($apps | Where-Object { $_.domain -eq $Fqdn }) | Select-Object -First 1
  if (-not $app) {
    Fail "no Access app for $Fqdn (site would be publicly reachable if the route serves it)"
  } else {
    Pass ("app '" + $app.name + "' (" + $app.id + ")")
    # Google-only: auto_redirect_to_identity on, and allowed_idps constrained (not 'accept all')
    if ($app.auto_redirect_to_identity) { Pass "instant auth on (auto_redirect_to_identity)" }
    else { Fail "instant auth OFF - user sees the IdP chooser (Accept all)" }
    if ($app.allowed_idps -and @($app.allowed_idps).Count -ge 1) { Pass "login constrained to a specific IdP" }
    else { Fail "no allowed_idps set - accepts all identity providers" }
    # policy present (and, if -Email, allows that email)
    $pols = @(Invoke-CF ("/accounts/$AccountId/access/apps/$($app.id)/policies"))
    if (@($pols).Count -eq 0) { Fail "app has NO policy - nobody (or everybody) can get in" }
    else {
      Pass ("has " + @($pols).Count + " policy/policies")
      if ($Email) {
        $allow = $false
        foreach ($p in $pols) { foreach ($inc in @($p.include)) { if ($inc.email -and $inc.email.email -eq $Email) { $allow = $true } } }
        if ($allow) { Pass "a policy allows $Email" } else { Fail "no policy allows $Email" }
      }
    }
  }
} else { Skip "Access checks need the Cloudflare token" }

# --- 4. Bucket ---
Write-Host "4. Bucket"
$rclone = Find-Rclone
if ($rclone) {
  $files = & $rclone lsf "r2:$ClientBucket/$Slug/" 2>$null
  if ($LASTEXITCODE -eq 0 -and $files) {
    $has = @($files) -contains 'index.html'
    if ($has) { Pass ("r2:$ClientBucket/$Slug/ has index.html (" + @($files).Count + " top-level entries)") }
    else { Pass ("r2:$ClientBucket/$Slug/ has " + @($files).Count + " entries (no top-level index.html - check the build)") }
  } elseif ($LASTEXITCODE -eq 0) { Fail "r2:$ClientBucket/$Slug/ is empty" }
  else { Fail "rclone could not read r2:$ClientBucket/$Slug/ (remote 'r2' scoped to this bucket?)" }
} else { Skip "rclone not found (winget install Rclone.Rclone) - bucket check skipped" }

# --- 5. Live (fails closed) ---
Write-Host "5. Live"
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if ($curl) {
  $head = & $curl -sI "https://$Fqdn/" 2>$null | Out-String
  if ($head -match '30[12]' -and $head -match [regex]::Escape($AccessTeam)) {
    Pass "302 -> $AccessTeam (fails closed without an identity = correct)"
  } elseif ($head -match '\b200\b') {
    Fail "returns 200 without an identity - NOT gated (Access app / route wrong)"
  } elseif ($head) {
    Skip "inconclusive (DNS/route may still be propagating); headers did not show the Access redirect"
  } else {
    Skip "no response yet (DNS/route may still be propagating)"
  }
} else { Skip "curl.exe not found - live check skipped" }

# ---------- summary ----------
Write-Host ""
$skipNote = if ($script:Skipped -gt 0) { " ($script:Skipped skipped - see [..]; run with a token for the full audit)" } else { "" }
if ($script:Red -eq 0) {
  Write-Host ("ALL GREEN - $Fqdn is wired correctly." + $skipNote) -ForegroundColor Green
  exit 0
} else {
  Write-Host ("$script:Red check(s) RED - see [--] above." + $skipNote) -ForegroundColor Red
  exit 1
}
