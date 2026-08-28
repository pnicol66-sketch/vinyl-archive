# Spec — automate private-client onboarding (`New-VinylClient`)

Status: **SCOPED, not yet built.** Pick this up in a fresh branch/thread.
Written 2026-08-27. Owner: Paul (pnicol66@gmail.com).

This document is self-contained. A fresh thread should be able to implement the
whole thing from this file + the two references below, without the conversation
that produced it.

**References to read first**
- `CLIENT-ONBOARDING.md` (same folder) — the current **manual** 8-step runbook this automates.
- Memory `vinyl-r2-hosting-infra.md` — the whole hosting product (R2 + Worker + Access + build.ps1).
- `build.ps1` (same folder) — the build/publish engine; already does the build+sync half.

---

## 1. Goal

Collapse the fiddly, error-prone half of onboarding a private client into one command:

```powershell
.\New-VinylClient.ps1 -Slug smith -Email jane@gmail.com -Name "The Smith Collection"
```

…that performs onboarding steps **3, 5, 6, 7, 4** (register tenant → DNS → Worker
route → Access app+policy+Google-only → build+push) off a single Cloudflare API
token, **idempotently**, and prints the handover URL.

Plus a companion verifier:

```powershell
.\Test-VinylClient.ps1 -Slug smith
```

…that proves the wiring end-to-end (DNS resolves → route exists → Access app +
policy present → bucket has files) and prints a green checklist.

### Why this is the right slice
Steps 5–7 are Cloudflare-dashboard clicks and are **exactly** the ones that failed
during the manual `smith` setup (Access app silently didn't save; the separate
Login-methods tab; wrong-page navigation). They are 100% API-scriptable, and a
script never forgets to click Save or leave "Accept all" on. Highest reliability +
time win, and self-contained.

---

## 2. What automates vs. what stays manual

| Onboarding step (from CLIENT-ONBOARDING.md) | In this tool? | Notes |
|---|---|---|
| 1. Client shares Drive folder | ❌ client action | out of scope |
| 1. Add Drive-desktop **shortcut** under `G:\My Drive\Vinyl Curator Clients\<slug>\` | ❌ manual GUI (~30s) | Drive-for-desktop doesn't mount "Shared with me" without it |
| 1. Register `photoRoots` in `build.config.json` | ✅ | script writes the tenant block by convention path |
| 2. Import albums + AI research + export `collection-<slug>.json` | ❌ human-in-the-loop | the quality core; must stay manual |
| 3. Register tenant in `tenants.json` | ✅ | script appends the JSON object |
| 4. `build.ps1 -Tenant <slug> -Push` | ✅ | script shells out to existing build |
| 5. DNS AAAA record | ✅ Cloudflare API | |
| 6. Worker route | ✅ Cloudflare API | |
| 7. Access app + policy + Google-only login | ✅ Cloudflare API | Google-only set **at creation** — no separate tab |
| 8. Handover email | ⚠️ Phase 3 | draft via Gmail MCP; sending stays a human click |

**Precondition the tool must check, not do:** `collection-<slug>.json` must already
exist in `G:\My Drive\Vinyl Curator Website\` (step 2 done by hand). Fail fast with a
clear message if missing.

---

## 3. The Cloudflare API calls (the meat)

Base: `https://api.cloudflare.com/client/v4`
Auth header: `Authorization: Bearer <CF_API_TOKEN>` (see §5 for the token).

All reference IDs live in §7. Implementer: fetch zone ID and Google IdP ID at
runtime (don't hard-code) — helpers below.

### 3.0 Discover IDs (run once per invocation, cache in-process)
```
GET /zones?name=vinylcurator.net
  -> result[0].id = ZONE_ID

GET /accounts/{ACCOUNT_ID}/access/identity_providers
  -> the entry with type == "google" -> .id = GOOGLE_IDP_ID
```

### 3.1 DNS record (step 5) — idempotent
```
GET  /zones/{ZONE_ID}/dns_records?type=AAAA&name=<slug>.vinylcurator.net
  -> if exists, skip (or PATCH to correct); else:
POST /zones/{ZONE_ID}/dns_records
  { "type":"AAAA", "name":"<slug>", "content":"100::", "proxied":true, "ttl":1 }
```

### 3.2 Worker route (step 6) — idempotent
```
GET  /zones/{ZONE_ID}/workers/routes
  -> if any pattern == "<slug>.vinylcurator.net/*", skip; else:
POST /zones/{ZONE_ID}/workers/routes
  { "pattern":"<slug>.vinylcurator.net/*", "script":"vinyl-client-sites" }
```

### 3.3 Access application (step 7) — idempotent
```
GET  /accounts/{ACCOUNT_ID}/access/apps
  -> if any .domain == "<slug>.vinylcurator.net", reuse its id; else:
POST /accounts/{ACCOUNT_ID}/access/apps
  {
    "name": "<Name>",
    "domain": "<slug>.vinylcurator.net",
    "type": "self_hosted",
    "session_duration": "24h",
    "allowed_idps": ["<GOOGLE_IDP_ID>"],
    "auto_redirect_to_identity": true,     // == "instant auth", Google-only
    "app_launcher_visible": false
  }
  -> result.id = APP_ID (a.k.a. aud/uid)
```
> `allowed_idps` + `auto_redirect_to_identity` together ARE the "turn off Accept
> all, select Google, apply instant authentication" manual step — done at creation.

### 3.4 Access policy (step 7) — allow the client's email
⚠️ **Verify the current API shape first** — Cloudflare has been migrating from
inline app policies to *reusable account-level* policies. Try inline; if the
endpoint 404s/deprecates, use the reusable form.

Inline (older, may still work):
```
POST /accounts/{ACCOUNT_ID}/access/apps/{APP_ID}/policies
  { "name":"<slug> allow", "decision":"allow",
    "include":[ { "email": { "email":"<client_email>" } } ] }
```
Reusable (newer):
```
POST /accounts/{ACCOUNT_ID}/access/policies
  { "name":"<slug> allow", "decision":"allow",
    "include":[ { "email": { "email":"<client_email>" } } ] }
  -> POLICY_ID
then PUT the app (3.3) with "policies":["<POLICY_ID>"] in the body.
```

### 3.5 Offboard (natural companion — `Remove-VinylClient`, Phase 3)
Section D of the onboarding doc is equally API-scriptable:
```
rclone purge r2:vinyl-client/<slug>
DELETE /accounts/{ACCOUNT_ID}/access/apps/{APP_ID}
DELETE /zones/{ZONE_ID}/workers/routes/{ROUTE_ID}
DELETE /zones/{ZONE_ID}/dns_records/{RECORD_ID}
+ remove the tenants.json entry
```

---

## 4. Local file edits the tool makes

- **`tenants.json`** — append (idempotent: replace if slug present):
  ```json
  { "slug":"<slug>", "name":"<Name>", "private":true,
    "dataFile":"collection-<slug>.json", "watermark":"vinylcurator.net",
    "indexes":[ { "path":"albums", "title":"<Name>" } ],
    "listed":false, "indexed":false, "status":"active" }
  ```
- **`build.config.json`** (gitignored, machine-local) — set the tenant photoRoots by
  convention, unless `-PhotoRoot` overrides:
  ```json
  "tenants": { "<slug>": { "photoRoots": ["G:\\My Drive\\Vinyl Curator Clients\\<slug>"] } }
  ```
  Preserve existing `photoRoots`/`folderOverrides`/other tenants — merge, don't clobber.

Then shell out: `powershell -File .\build.ps1 -Tenant <slug> -Push`.

---

## 5. Secrets / config handling

- One **Cloudflare API token**, scoped minimally:
  - **Zone → DNS → Edit** (zone: vinylcurator.net)
  - **Zone → Workers Routes → Edit** (zone: vinylcurator.net)
  - **Account → Access: Apps and Policies → Edit**
  - **Account → Access: Organizations, Identity Providers, and Groups → Read** (to read the Google IdP id)
- Store it **out of the repo**. Options (pick during impl):
  - a new gitignored file `cf-api.local.json` next to build.ps1, **or**
  - a `_secrets` block in `build.config.json` (already gitignored) — simplest.
  - Confirm `build.config.json` is in `.gitignore` before writing a token into it.
- Never echo the token; never let it reach git. `Test-VinylClient` and dry-run must
  work read-only.

---

## 6. Requirements / behaviours

- **Idempotent**: re-running for an existing slug detects each resource and skips or
  updates — never duplicates a DNS record, route, app, or tenant entry. Safe to re-run
  after a partial failure.
- **Dry-run**: `-WhatIf` prints every action (API call + file edit) without doing them.
- **Fail fast + clear**: check `collection-<slug>.json` exists before touching Cloudflare.
- **Ordered + resumable**: do file edits first (cheap, local), then DNS → route → app →
  policy → build+push. On failure, print exactly which step failed and how to resume.
- **No secret leakage** in logs/output.
- **Verify at the end**: after publish, call the same checks as `Test-VinylClient` and
  print the green checklist (or what's red).
- **Param validation**: `-Slug` = `^[a-z0-9-]+$`; `-Email` a plausible address; `-Name`
  free text; optional `-PhotoRoot`.

### `Test-VinylClient -Slug <slug>` checks
1. DNS: `<slug>.vinylcurator.net` resolves / AAAA record present (API or `Resolve-DnsName`).
2. Route: a Worker route matches `<slug>.vinylcurator.net/*`.
3. Access: an app exists for that domain **with a policy** and Google-only login.
4. Bucket: `rclone lsf r2:vinyl-client/<slug>/` returns files (index.html at least).
5. Live: `curl -sI https://<slug>.vinylcurator.net/` → 302 to
   `vinylcurator.cloudflareaccess.com` (fails-closed = correct).

---

## 7. Reference values (from CLIENT-ONBOARDING.md §E)

| Thing | Value |
|---|---|
| Cloudflare account ID | `0c94e84d9739eea5ffda13ecc647393e` |
| Zone | `vinylcurator.net` (fetch ZONE_ID at runtime) |
| Private bucket | `vinyl-client` |
| Worker script name | `vinyl-client-sites` (binding `CLIENT_BUCKET`) |
| Access team / login domain | `vinylcurator.cloudflareaccess.com` |
| Access → Google redirect URI | `https://vinylcurator.cloudflareaccess.com/cdn-cgi/access/callback` |
| Google IdP | fetch GOOGLE_IDP_ID at runtime (type == "google") |
| DNS per client | `<slug>` AAAA `100::` **Proxied** |
| Bucket key layout | `<slug>/albums/…`, `<slug>/assets/…`, `<slug>/index.html` |
| rclone remote | `r2` (token scoped to all buckets, can write vinyl-client) |
| Collection data dir | `G:\My Drive\Vinyl Curator Website\collection-<slug>.json` |
| Client photo root (convention) | `G:\My Drive\Vinyl Curator Clients\<slug>` |

---

## 8. Build plan (phased)

**Phase 1 — core `New-VinylClient.ps1`** (the win)
- Token config + ID discovery helpers (§3.0, §5).
- Steps 3+5+6+7+4, idempotent, with `-WhatIf`.
- End-of-run verification block.
- Test against a **throwaway slug** (e.g. `zztest`), then **offboard it** (§3.5 by
  hand or the Phase-3 script) to leave no trace. Do NOT test against `smith` (live).

**Phase 2 — `Test-VinylClient.ps1`**
- The 5 checks in §6. Read-only. Also usable standalone to audit `smith`.

**Phase 3 — nice-to-haves**
- `Remove-VinylClient.ps1` (§3.5) — one-command offboarding.
- Handover email **draft** via Gmail MCP (`create_draft`); sending stays manual.
- Optional interactive prompt mode if params omitted.

**Out of scope (leave manual):** the Drive share, the Drive-desktop shortcut, and
album research/export. Note them in the tool's final "now do by hand" reminder.

---

## 9. Testing checklist (Phase 1 acceptance)

- [ ] `-WhatIf` on a new slug prints all 5 actions, changes nothing (git + Cloudflare unchanged).
- [ ] Real run on throwaway slug creates DNS + route + app + policy + tenant + publishes.
- [ ] `curl -sI https://<slug>.vinylcurator.net/` → 302 to cloudflareaccess.com (fails closed).
- [ ] Re-run same slug = all "already exists, skipped" (idempotent), no duplicates.
- [ ] Owner build still byte-identical afterwards (`git status` shows only intended files).
- [ ] Throwaway slug fully offboarded (bucket purged, app/route/DNS/tenant removed).
- [ ] Update `CLIENT-ONBOARDING.md`: replace manual steps 3–7 with "run `New-VinylClient`".

---

## 10. Open questions to settle when building

1. Inline vs. reusable Access policy (§3.4) — confirm which the API accepts today.
2. Token storage location — `cf-api.local.json` vs. `_secrets` in `build.config.json` (confirm gitignore).
3. Should `New-VinylClient` also *offer* to draft the handover email, or keep Phase 3 separate?
4. Wildcard vs. per-app — we deliberately use per-client Access apps (email policies differ). Keep per-app.
