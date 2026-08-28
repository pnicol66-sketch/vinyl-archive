# Onboard a private client in one command (PowerShell 5.1, no dependencies).
#
# Collapses the fiddly half of CLIENT-ONBOARDING.md (steps 3,5,6,7,4) into a
# single idempotent command driven off one Cloudflare API token:
#   3. register the tenant in tenants.json (+ photoRoots in build.config.json)
#   5. DNS AAAA record            (Cloudflare API)
#   6. Worker route               (Cloudflare API)
#   7. Access app + policy + Google-only login   (Cloudflare API)
#   4. build + push to the private R2 bucket      (shells to build.ps1)
# then verifies the wiring and prints the handover URL.
#
#   .\New-VinylClient.ps1 -Slug smith -Email jane@gmail.com -Name "The Smith Collection"
#   .\New-VinylClient.ps1 -Slug zztest -Email me@gmail.com -Name "Test" -WhatIf
#
# Stays MANUAL (this tool does not do them): the client's Drive share, the
# Drive-for-desktop shortcut, and album import/AI-research/export. The tool
# checks that the export (collection-<slug>.json) already exists and fails fast
# if not. See NEW-CLIENT-AUTOMATION-SPEC.md for the full design.
#
# TOKEN: a Cloudflare API token scoped DNS:Edit + Workers Routes:Edit +
# Access Apps and Policies:Edit + Access IdP:Read (zone vinylcurator.net /
# account). Supply it via the CF_API_TOKEN env var, or a gitignored
# cf-api.local.json next to this script: { "token": "..." }. Never committed.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-z0-9-]+$')]
  [string]$Slug,

  [Parameter(Mandatory = $true)]
  [string]$Email,

  [Parameter(Mandatory = $true)]
  [string]$Name,

  # Override the convention photo root (G:\My Drive\Vinyl Curator Clients\<slug>).
  [string]$PhotoRoot,

  # Do the file edits + Cloudflare wiring but skip the build+push (step 4).
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

# ---------- constants (reference values, CLIENT-ONBOARDING.md section E) ----------
$AccountId       = '0c94e84d9739eea5ffda13ecc647393e'
$ZoneName        = 'vinylcurator.net'
$WorkerScript    = 'vinyl-client-sites'
$ClientBucket    = 'vinyl-client'
$WebsiteDataDir  = 'G:\My Drive\Vinyl Curator Website'
$PhotoConvention = 'G:\My Drive\Vinyl Curator Clients\' + $Slug
$Site            = Split-Path -Parent $MyInvocation.MyCommand.Path
$Fqdn            = "$Slug.$ZoneName"

# ---------- small helpers ----------
function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Step([string]$msg) { Write-Host "" ; Write-Host ("=== " + $msg + " ===") -ForegroundColor Cyan }
function ReadJson([string]$path) {
  return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}
function WriteUtf8([string]$path, [string]$text) {
  [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function JsonStr([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('\', '\\').Replace('"', '\"')
}

# ---------- Cloudflare client (never logs the token) ----------
$script:Token   = $null
$script:HaveTok = $false
function Invoke-CF {
  param([string]$Method, [string]$Path, $Body)
  if (-not $script:HaveTok) { throw "No Cloudflare token loaded - cannot call the API." }
  $uri = 'https://api.cloudflare.com/client/v4' + $Path
  $headers = @{ Authorization = "Bearer $script:Token" }
  $req = @{ Method = $Method; Uri = $uri; Headers = $headers; ContentType = 'application/json' }
  if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 10) }
  try {
    $resp = Invoke-RestMethod @req
  } catch {
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

# =====================================================================
# 0. Validate + preconditions (fail fast, before touching anything)
# =====================================================================
Step "Onboarding '$Slug'  ->  https://$Fqdn"

if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
  throw "Email '$Email' does not look like a valid address."
}

$DataFile = Join-Path $WebsiteDataDir ("collection-$Slug.json")
if (-not (Test-Path $DataFile)) {
  throw ("Precondition failed: '$DataFile' does not exist.`n" +
    "  Do the manual steps first: share + shortcut the client's Drive folder,`n" +
    "  import/research their albums in the client sheet copy, set collection ID`n" +
    "  '$Slug', and export the site data. Then re-run this command.")
}
Say "OK  collection-$Slug.json present." 'Green'

# ---------- load the Cloudflare token ----------
$script:Token = $env:CF_API_TOKEN
if (-not $script:Token) {
  $tf = Join-Path $Site 'cf-api.local.json'
  if (Test-Path $tf) {
    try { $script:Token = (ReadJson $tf).token } catch { }
  }
}
if ($script:Token) {
  $script:HaveTok = $true
} elseif ($WhatIfPreference) {
  Say "WARN  no Cloudflare token (CF_API_TOKEN or cf-api.local.json). -WhatIf will" 'Yellow'
  Say "      show planned actions only and skip the live existence checks." 'Yellow'
} else {
  throw ("No Cloudflare token found. Set `$env:CF_API_TOKEN or create a gitignored`n" +
    "  cf-api.local.json next to this script: { ""token"": ""<token>"" }`n" +
    "  Scopes: DNS:Edit, Workers Routes:Edit, Access Apps and Policies:Edit, Access IdP:Read.")
}

# ---------- discover runtime IDs (read-only; safe under -WhatIf) ----------
$ZoneId = $null; $GoogleIdp = $null
if ($script:HaveTok) {
  Say "Discovering zone + Google IdP ids ..." 'DarkGray'
  $zones = Invoke-CF GET ("/zones?name=$ZoneName")
  if (-not $zones -or $zones.Count -eq 0) { throw "Zone '$ZoneName' not found on this token." }
  $ZoneId = $zones[0].id
  $idps = Invoke-CF GET ("/accounts/$AccountId/access/identity_providers")
  $g = @($idps | Where-Object { $_.type -eq 'google' }) | Select-Object -First 1
  if (-not $g) { throw "No Google identity provider found in Access - configure it first." }
  $GoogleIdp = $g.id
  Say ("OK  zone " + $ZoneId + " ; Google IdP " + $GoogleIdp) 'Green'
}

# =====================================================================
# 1. Local file edits first (cheap, local, resumable)
# =====================================================================
Step "Register tenant + photo root (local files)"

# --- 1a. tenants.json (committed; edited surgically to keep its formatting) ---
$TenantsFile = Join-Path $Site 'tenants.json'
$reg = ReadJson $TenantsFile
$existingTenant = @($reg.tenants) | Where-Object { $_.slug -eq $Slug } | Select-Object -First 1
if ($existingTenant) {
  Say "SKIP  tenant '$Slug' already in tenants.json (no duplicate)." 'DarkGray'
} else {
  $block =
    "    {`n" +
    "      ""slug"": ""$(JsonStr $Slug)"",`n" +
    "      ""name"": ""$(JsonStr $Name)"",`n" +
    "      ""private"": true,`n" +
    "      ""dataFile"": ""collection-$(JsonStr $Slug).json"",`n" +
    "      ""watermark"": ""vinylcurator.net"",`n" +
    "      ""indexes"": [ { ""path"": ""albums"", ""title"": ""$(JsonStr $Name)"" } ],`n" +
    "      ""listed"": false,`n" +
    "      ""indexed"": false,`n" +
    "      ""status"": ""active""`n" +
    "    }"
  if ($PSCmdlet.ShouldProcess($TenantsFile, "append tenant '$Slug'")) {
    $raw = [IO.File]::ReadAllText($TenantsFile, [Text.Encoding]::UTF8)
    # Turn the tenants-array closer  ...}\n  ]\n}  into  ...},\n<block>\n  ]\n}
    $new = [regex]::Replace($raw, ",?\r?\n  \]\r?\n\}\s*$",
      ("," + "`n" + $block + "`n  ]`n}`n"))
    if ($new -eq $raw) {
      throw ("Could not locate the tenants array closer in tenants.json - add this block by hand:`n" + $block)
    }
    WriteUtf8 $TenantsFile $new
    Say "OK  appended tenant '$Slug' to tenants.json." 'Green'
  }
}

# --- 1b. build.config.json (gitignored, machine-local; reserialize is fine) ---
$ConfigFile = Join-Path $Site 'build.config.json'
$photoRoots = if ($PhotoRoot) { @($PhotoRoot) } else { @($PhotoConvention) }
if (Test-Path $ConfigFile) { $cfg = ReadJson $ConfigFile }
else { $cfg = [pscustomobject]@{ photoRoots = @(); folderOverrides = [pscustomobject]@{} } }
if (-not ($cfg.PSObject.Properties.Name -contains 'tenants')) {
  $cfg | Add-Member -NotePropertyName tenants -NotePropertyValue ([pscustomobject]@{})
}
if ($cfg.tenants.PSObject.Properties.Name -contains $Slug) {
  # preserve any existing sub-keys (e.g. folderOverrides); set only photoRoots
  $tblk = $cfg.tenants.$Slug
  if ($tblk.PSObject.Properties.Name -contains 'photoRoots') { $tblk.photoRoots = $photoRoots }
  else { $tblk | Add-Member -NotePropertyName photoRoots -NotePropertyValue $photoRoots }
} else {
  $cfg.tenants | Add-Member -NotePropertyName $Slug -NotePropertyValue ([pscustomobject]@{ photoRoots = $photoRoots })
}
if ($PSCmdlet.ShouldProcess($ConfigFile, "set tenants.$Slug.photoRoots = $($photoRoots -join '; ')")) {
  WriteUtf8 $ConfigFile ($cfg | ConvertTo-Json -Depth 10)
  Say ("OK  photoRoots for '$Slug' -> " + ($photoRoots -join '; ')) 'Green'
}

# =====================================================================
# 2. Cloudflare wiring: DNS -> route -> app -> policy (all idempotent)
# =====================================================================

# --- 2a. DNS AAAA (step 5) ---
Step "DNS AAAA  $Fqdn -> 100:: (proxied)"
if ($script:HaveTok) {
  $rec = @(Invoke-CF GET ("/zones/$ZoneId/dns_records?type=AAAA&name=$Fqdn"))
  if ($rec.Count -gt 0) {
    Say "SKIP  AAAA record already exists ($($rec[0].id))." 'DarkGray'
  } elseif ($PSCmdlet.ShouldProcess($Fqdn, "create AAAA record -> 100:: (proxied)")) {
    $body = @{ type = 'AAAA'; name = $Slug; content = '100::'; proxied = $true; ttl = 1 }
    $r = Invoke-CF POST ("/zones/$ZoneId/dns_records") $body
    Say ("OK  created AAAA record " + $r.id) 'Green'
  }
} else { Say "WHATIF  would create AAAA $Fqdn -> 100:: (proxied)" 'Yellow' }

# --- 2b. Worker route (step 6) ---
Step "Worker route  $Fqdn/* -> $WorkerScript"
if ($script:HaveTok) {
  $routes = @(Invoke-CF GET ("/zones/$ZoneId/workers/routes"))
  $match = @($routes | Where-Object { $_.pattern -eq "$Fqdn/*" }) | Select-Object -First 1
  if ($match) {
    Say "SKIP  route already exists ($($match.id))." 'DarkGray'
  } elseif ($PSCmdlet.ShouldProcess("$Fqdn/*", "create Worker route -> $WorkerScript")) {
    $body = @{ pattern = "$Fqdn/*"; script = $WorkerScript }
    $r = Invoke-CF POST ("/zones/$ZoneId/workers/routes") $body
    Say ("OK  created route " + $r.id) 'Green'
  }
} else { Say "WHATIF  would create route $Fqdn/* -> $WorkerScript" 'Yellow' }

# --- 2c. Access app (step 7): Google-only login set at creation ---
Step "Access application (Google-only) for $Fqdn"
$AppId = $null
if ($script:HaveTok) {
  $apps = @(Invoke-CF GET ("/accounts/$AccountId/access/apps"))
  $app = @($apps | Where-Object { $_.domain -eq $Fqdn }) | Select-Object -First 1
  if ($app) {
    $AppId = $app.id
    Say "SKIP  Access app already exists ($AppId)." 'DarkGray'
  } elseif ($PSCmdlet.ShouldProcess($Fqdn, "create self-hosted Access app (Google-only)")) {
    $body = @{
      name                      = $Name
      domain                    = $Fqdn
      type                      = 'self_hosted'
      session_duration          = '24h'
      allowed_idps              = @($GoogleIdp)
      auto_redirect_to_identity = $true      # == "instant auth", skips the chooser
      app_launcher_visible      = $false
    }
    $r = Invoke-CF POST ("/accounts/$AccountId/access/apps") $body
    $AppId = $r.id
    Say ("OK  created Access app " + $AppId) 'Green'
  }
} else { Say "WHATIF  would create self-hosted Access app for $Fqdn (Google-only)" 'Yellow' }

# --- 2d. Access policy (step 7): allow the client's email ---
Step "Access policy  allow $Email"
if ($script:HaveTok -and $AppId) {
  $pols = @(Invoke-CF GET ("/accounts/$AccountId/access/apps/$AppId/policies"))
  $has = $false
  foreach ($p in $pols) {
    foreach ($inc in @($p.include)) {
      if ($inc.email -and ($inc.email.email -eq $Email)) { $has = $true }
    }
  }
  if ($has) {
    Say "SKIP  a policy already allows $Email." 'DarkGray'
  } elseif ($PSCmdlet.ShouldProcess($Fqdn, "add allow policy for $Email")) {
    $body = @{ name = "$Slug allow"; decision = 'allow'
      include = @(@{ email = @{ email = $Email } }) }
    try {
      # Inline app policy (older shape).
      $r = Invoke-CF POST ("/accounts/$AccountId/access/apps/$AppId/policies") $body
      Say ("OK  created inline policy " + $r.id) 'Green'
    } catch {
      # Reusable account-level policy (newer shape): create, then attach to the app.
      Say "  inline policy endpoint rejected it; using reusable account policy ..." 'DarkGray'
      $r = Invoke-CF POST ("/accounts/$AccountId/access/policies") $body
      $pid = $r.id
      Invoke-CF PUT ("/accounts/$AccountId/access/apps/$AppId") @{ policies = @($pid) } | Out-Null
      Say ("OK  created reusable policy " + $pid + " and attached it") 'Green'
    }
  }
} elseif (-not $script:HaveTok) {
  Say "WHATIF  would add an allow policy for $Email" 'Yellow'
} else {
  Say "SKIP  no app id (created under -WhatIf); policy step deferred." 'DarkGray'
}

# =====================================================================
# 3. Build + publish to the private bucket (step 4)
# =====================================================================
Step "Build + push  build.ps1 -Tenant $Slug -Push"
if ($SkipBuild) {
  Say "SKIP  -SkipBuild given." 'DarkGray'
} elseif ($PSCmdlet.ShouldProcess("$Slug", "build.ps1 -Tenant $Slug -Push")) {
  $buildPs1 = Join-Path $Site 'build.ps1'
  & powershell -NoProfile -ExecutionPolicy Bypass -File $buildPs1 -Tenant $Slug -Push
  if ($LASTEXITCODE -ne 0) { throw "build.ps1 failed (exit $LASTEXITCODE) - fix, then re-run this command (idempotent)." }
  Say "OK  built and pushed to r2:$ClientBucket/$Slug/." 'Green'
} else {
  Say "WHATIF  would run build.ps1 -Tenant $Slug -Push" 'Yellow'
}

# =====================================================================
# 4. Verify the wiring (end-of-run checklist)
# =====================================================================
if ((-not $WhatIfPreference) -and $script:HaveTok) {
  Step "Verify"
  $ok = $true
  # DNS
  $rec = @(Invoke-CF GET ("/zones/$ZoneId/dns_records?type=AAAA&name=$Fqdn"))
  if ($rec.Count -gt 0) { Say "  [OK] DNS AAAA present" 'Green' } else { Say "  [--] DNS AAAA MISSING" 'Red'; $ok = $false }
  # Route
  $routes = @(Invoke-CF GET ("/zones/$ZoneId/workers/routes"))
  if (@($routes | Where-Object { $_.pattern -eq "$Fqdn/*" }).Count -gt 0) { Say "  [OK] Worker route present" 'Green' } else { Say "  [--] Worker route MISSING" 'Red'; $ok = $false }
  # App + policy
  $apps = @(Invoke-CF GET ("/accounts/$AccountId/access/apps"))
  $app = @($apps | Where-Object { $_.domain -eq $Fqdn }) | Select-Object -First 1
  if ($app) {
    Say "  [OK] Access app present" 'Green'
    $pols = @(Invoke-CF GET ("/accounts/$AccountId/access/apps/$($app.id)/policies"))
    $allow = $false
    foreach ($p in $pols) { foreach ($inc in @($p.include)) { if ($inc.email -and $inc.email.email -eq $Email) { $allow = $true } } }
    if ($allow) { Say "  [OK] policy allows $Email" 'Green' } else { Say "  [--] no policy for $Email" 'Red'; $ok = $false }
  } else { Say "  [--] Access app MISSING" 'Red'; $ok = $false }
  # Bucket
  $rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
  if (-not $rclone) {
    $rclone = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
  }
  if ($rclone -and -not $SkipBuild) {
    $files = & $rclone lsf "r2:$ClientBucket/$Slug/" 2>$null
    if ($LASTEXITCODE -eq 0 -and $files) { Say "  [OK] bucket has files ($(@($files).Count) entries)" 'Green' } else { Say "  [--] bucket empty / not reachable" 'Red'; $ok = $false }
  } else { Say "  [..] bucket check skipped (no rclone / -SkipBuild)" 'DarkGray' }
  # Live fail-closed check
  $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
  if ($curl) {
    $head = & $curl -sI "https://$Fqdn/" 2>$null | Out-String
    if ($head -match '30[12]' -and $head -match 'cloudflareaccess\.com') { Say "  [OK] live: 302 -> cloudflareaccess.com (fails closed)" 'Green' }
    else { Say "  [..] live check inconclusive (may need a minute for DNS/route to propagate)" 'DarkGray' }
  }
  Write-Host ""
  if ($ok) { Say "ALL GREEN - wiring is in place." 'Green' } else { Say "Some checks are RED - re-run this command (idempotent) after fixing." 'Yellow' }
}

# =====================================================================
# 5. Handover + manual reminders
# =====================================================================
Step "Done"
Say "Handover URL:  https://$Fqdn" 'Cyan'
Say ""
Say "Still to do by hand (out of scope for this tool):" 'Yellow'
Say "  - Confirm the client shared their photo Drive folder with you." 'Yellow'
Say "  - Confirm a Drive-for-desktop SHORTCUT exists under:" 'Yellow'
Say "      $PhotoConvention" 'Yellow'
Say "  - Send the client the handover URL; they Continue with Google ($Email)." 'Yellow'
if ($WhatIfPreference) { Say ""; Say "(-WhatIf: nothing above was changed.)" 'Yellow' }
