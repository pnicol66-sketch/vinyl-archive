# Onboarding a private client — checklist

How to stand up a login-gated private archive for one client at
`https://<slug>.vinylcurator.net`. `<slug>` is a short lowercase label (the
subdomain and the bucket key prefix), e.g. `smith`.

Proven end-to-end 2026-08-27; `smith` is the live reference built this way.

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

### 1. Get the client's photos
- [ ] Client shares their photo Drive folder with the owner's Google account.
- [ ] Add a **shortcut** to it under `G:\My Drive\Vinyl Curator Clients\<slug>\`
      (Drive for desktop doesn't mount "Shared with me" — the shortcut is what
      makes it visible to the build).
- [ ] Register that folder as this client's **own** photo root in
      **`build.config.json`** so the build searches ONLY it for this client (never
      the owner's or another client's folders — this prevents a shared album
      folder-name pulling the wrong copy):
```json
{
  "photoRoots": [],
  "folderOverrides": {},
  "tenants": {
    "<slug>": { "photoRoots": ["G:\\My Drive\\Vinyl Curator Clients\\<slug>"] }
  }
}
```
      (Per-album `folderOverrides` can also be set inside the tenant block if a
      folder name doesn't match.)

### 2. Build the client's collection data (sheet)
- [ ] In a **client copy of the Vinyl Project sheet** (kept under the owner's
      account, never shared with the client), import the client's albums and run
      the research pipeline — the same way you build your own collection.
- [ ] Set the sheet's **collection ID** to `<slug>`
      (`Website > Set collection ID…`).
- [ ] Export the site data (`Website > Publish Vinyl Site…` / export) → produces
      **`collection-<slug>.json`** in `G:\My Drive\Vinyl Curator Website\`.

### 3. Register the tenant
- [ ] Add an entry to **`tenants.json`**:
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

### 4. Build + publish to the private bucket
- [ ] Run:
```
.\build.ps1 -Tenant <slug> -Push
```
This builds a self-contained tree (relative URLs, assets bundled) into a
gitignored staging dir and `rclone sync`s it to `r2:vinyl-client/<slug>/`.
Nothing enters the public repo.

### 5. DNS (Cloudflare → vinylcurator.net → DNS → Records → Add record)
- [ ] Type **AAAA**, Name **`<slug>`**, IPv6 **`100::`**, Proxy **Proxied**
      (orange), TTL Auto.

### 6. Worker route (Workers & Pages → `vinyl-client-sites` → Domains → Routes)
- [ ] Add route **`<slug>.vinylcurator.net/*`**, zone `vinylcurator.net`.

### 7. Cloudflare Access app (Zero Trust → Access controls → Applications)
- [ ] **Create new application → Self-hosted.**
- [ ] Public hostname: subdomain **`<slug>`**, domain `vinylcurator.net`, path blank.
- [ ] Add a policy: **Allow → Emails → the client's Gmail**
      (the one they shared the Drive folder from).
- [ ] **Save application** — confirm it appears in the Applications list.
- [ ] Open the app → **Login methods** → turn OFF "Accept all", select **Google**,
      turn ON "Apply instant authentication" → Save.

### 8. Hand it over
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

## Notes / known gaps
- **`-All` does not publish private tenants** — its loop syncs only the owner
  site + git. Publish each private client individually with `-Tenant <slug> -Push`.
- **Login domain wording**: Google's sign-in shows "continue to
  cloudflareaccess.com" (Google shows the registrable domain; a custom Access
  domain to change it needs a paid plan). Reassure in the invite; it's standard.
