# Onboarding a private client — checklist

How to stand up a login-gated private archive for one client at
`https://<slug>.vinylcurator.net`. `<slug>` is a short lowercase label (the
subdomain and the bucket key prefix), e.g. `smith`.

Proven end-to-end 2026-08-27; `smith` is the live reference built this way.
Steps 3-7 are now automated by `New-VinylClient.ps1` (2026-08-28); the manual
dashboard version is kept in Appendix F.

---

## A. One-time infrastructure — already in place (reference only)

- Private R2 bucket **`vinyl-client`** (Public Access **disabled**).
- Worker **`vinyl-client-sites`** — binding `CLIENT_BUCKET` → `vinyl-client`;
  serves `<slug>.vinylcurator.net/<path>` from bucket key `<slug>/<path>`, fails
  closed without a Cloudflare Access identity.
- Cloudflare **Zero Trust** team `vinylcurator` (login domain
  `vinylcurator.cloudflareaccess.com`), with **Google** as an identity provider.
- rclone remote **`r2`** — its token is scoped to **all buckets** (so it can
  write `vinyl-client`).

You only touch Section A again if any of it breaks. Everything below is per client.

---

## B. Onboard a client — per-client checklist

**One command does steps 3-7.** After two manual prep steps (photos + collection
data), run `New-VinylClient.ps1`: it registers the tenant, wires Cloudflare,
builds, pushes and verifies — idempotently. The dashboard steps it replaces are
preserved in **Appendix F** as a fallback.

**One-time prerequisite — Cloudflare API token.** Put a scoped token in a
gitignored `cf-api.local.json` next to the scripts: `{ "token": "<token>" }`
(or set `$env:CF_API_TOKEN`). Scope it:
- Zone · **DNS: Edit** · **Workers Routes: Edit** (zone `vinylcurator.net`)
- Account · **Access: Apps and Policies: Edit** · **Access: Identity Providers: Read**

### 1. Get the client's photos  (manual)
- [ ] Client shares their photo Drive folder with the owner's Google account.
- [ ] Add a **shortcut** to it under `G:\My Drive\Vinyl Curator Clients\<slug>\`
      (Drive for desktop doesn't mount "Shared with me" — the shortcut is what
      makes it visible to the build). New-VinylClient registers this path as the
      client's photo root automatically; pass `-PhotoRoot <path>` only to override.

### 2. Build the client's collection data (sheet)  (manual, human-in-the-loop)
- [ ] In a **client copy of the Vinyl Project sheet** (kept under the owner's
      account, never shared with the client), import the client's albums and run
      the research pipeline — the same way you build your own collection.
- [ ] Set the sheet's **collection ID** to `<slug>`
      (`Website > Set collection ID…`).
- [ ] Export the site data (`Website > Publish Vinyl Site…` / export) → produces
      **`collection-<slug>.json`** in `G:\My Drive\Vinyl Curator Website\`.
      (New-VinylClient fails fast if this file is missing.)

### 3. Run the onboarding command  (automated)
```
.\New-VinylClient.ps1 -Slug <slug> -Email <client-gmail> -Name "The <Client> Collection"
```
Idempotently and in order, this:
- registers the tenant in **`tenants.json`** and the photoRoots in
  **`build.config.json`**;
- creates the **DNS** AAAA (`<slug>` → `100::`, proxied), the **Worker route**
  (`<slug>.vinylcurator.net/*` → `vinyl-client-sites`), and the **Access app**
  (self-hosted, **Google-only login set at creation**) with an **allow policy**
  for the client's email;
- runs **`build.ps1 -Tenant <slug> -Push`** (builds a self-contained tree and
  `rclone sync`s it to `r2:vinyl-client/<slug>/`; nothing enters the public repo);
- prints a green/red **verify** checklist and the handover URL.

Flags: **`-WhatIf`** = dry run (prints every action, changes nothing);
**`-SkipBuild`** = wire Cloudflare without publishing. Re-running is safe —
each resource is detected and skipped, never duplicated.

### 4. Verify (optional — step 3 already runs this)
```
.\Test-VinylClient.ps1 -Slug <slug> -Email <client-gmail>
```
Read-only; re-checks DNS, Worker route, Access app + policy + Google-only, the
R2 bucket (has `index.html`), and the live **302 → cloudflareaccess.com**
(fails closed). Also handy any time to audit an existing client (e.g. `smith`).

### 5. Hand it over
- [ ] Send the client `https://<slug>.vinylcurator.net`.
- [ ] They click **Continue with Google** (their existing account) → their archive.
- [ ] Optional in the welcome note: "sign in with the Google account you shared
      the folder from, via our secure Cloudflare gateway."

---

## C. Update a client (their collection changed)
- [ ] Re-run the sheet export for `<slug>` → `collection-<slug>.json`.
- [ ] `.\build.ps1 -Tenant <slug> -Push` (re-syncs; incremental).
No Cloudflare changes needed.

---

## D. Offboard a client (takedown)
- [ ] Purge their bucket prefix: `rclone purge r2:vinyl-client/<slug>`.
- [ ] Delete their **Access application** (Applications → `<slug>` → Delete).
- [ ] Delete their **Worker route** (`<slug>.vinylcurator.net/*`).
- [ ] Delete their **DNS record** (`<slug>` AAAA).
- [ ] Remove their entry from `tenants.json`.
Their pages + photos are gone completely (private bucket, real deletion) and
nothing of theirs was ever in the public repo — a total takedown.
(A `Remove-VinylClient.ps1` to do all of this off the same token is planned —
Phase 3 of the automation.)

---

## E. Reference values
| Thing | Value |
|---|---|
| Private bucket | `vinyl-client` |
| Worker | `vinyl-client-sites` (binding `CLIENT_BUCKET`) |
| Access team / login domain | `vinylcurator.cloudflareaccess.com` |
| Access → Google redirect URI | `https://vinylcurator.cloudflareaccess.com/cdn-cgi/access/callback` |
| Cloudflare account ID | `0c94e84d9739eea5ffda13ecc647393e` |
| DNS per client | `<slug>` AAAA `100::` **Proxied** |
| Bucket key layout | `<slug>/albums/…`, `<slug>/assets/…`, `<slug>/index.html` |

## Notes
- **`build.ps1 -All -Push`** republishes the owner site AND every private client
  in one command (each private tenant syncs itself to its bucket; the owner gets
  the image-sync + git push). Use it to push a site-wide change to everyone; use
  `-Tenant <slug> -Push` to publish just one client.
- **Login domain wording**: Google's sign-in shows "continue to
  cloudflareaccess.com" (Google shows the registrable domain; a custom Access
  domain to change it needs a paid plan). Reassure in the invite; it's standard.

---

## F. Appendix — manual equivalent (what New-VinylClient automates)

Do these by hand only if the tool is unavailable. This is the original steps
3-7, in dashboard form. (Verified against the live API 2026-08-28: the Access
policy is created **inline** on the app; Google-only is `allowed_idps` +
`auto_redirect_to_identity` set at creation.)

### F.3 Register the tenant
Add an entry to **`tenants.json`**:
```json
{
  "slug": "<slug>",
  "name": "The <Client> Collection",
  "private": true,
  "dataFile": "collection-<slug>.json",
  "watermark": "vinylcurator.net",
  "indexes": [ { "path": "albums", "title": "The <Client> Collection" } ],
  "listed": false,
  "indexed": false,
  "status": "active"
}
```
And register the photo root in **`build.config.json`** so the build searches
ONLY this client's folder (never the owner's or another client's — a shared
album folder-name could otherwise pull the wrong copy):
```json
{
  "photoRoots": [],
  "folderOverrides": {},
  "tenants": {
    "<slug>": { "photoRoots": ["G:\\My Drive\\Vinyl Curator Clients\\<slug>"] }
  }
}
```

### F.4 Build + publish to the private bucket
```
.\build.ps1 -Tenant <slug> -Push
```

### F.5 DNS (Cloudflare → vinylcurator.net → DNS → Records → Add record)
Type **AAAA**, Name **`<slug>`**, IPv6 **`100::`**, Proxy **Proxied** (orange),
TTL Auto.

### F.6 Worker route (Workers & Pages → `vinyl-client-sites` → Domains → Routes)
Add route **`<slug>.vinylcurator.net/*`**, zone `vinylcurator.net`.

### F.7 Cloudflare Access app (Zero Trust → Access controls → Applications)
- **Create new application → Self-hosted.**
- Public hostname: subdomain **`<slug>`**, domain `vinylcurator.net`, path blank.
- Add a policy: **Allow → Emails → the client's Gmail** (the one they shared the
  Drive folder from).
- **Save application** — confirm it appears in the Applications list.
- Open the app → **Login methods** → turn OFF "Accept all", select **Google**,
  turn ON "Apply instant authentication" → Save.
