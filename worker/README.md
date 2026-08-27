# Private client sites (Phase P)

Login-gated per-client archives at `https://<client>.clients.vinylcurator.net`.
Each client's static site lives in ONE private R2 bucket under a key prefix (the
subdomain label); a Cloudflare Worker streams it, and **Cloudflare Access** gates
the hostname (per-client email allow-list) in front of the Worker.

```
<client>.clients.vinylcurator.net/<path>
   -> Cloudflare Access   (Google / email OTP login; per-client email policy)
   -> vinyl-client-worker.js   (fails closed with no Access identity)
   -> private R2 bucket "vinyl-client", key "<client>/<path>"
```

Nothing here is public: the bucket has no public domain, and the Worker refuses
any request that did not come through Access. The owner's public site
(`vinylcurator.net`, `www`, `img`) is untouched - it is not under `.clients`.

## One-time setup

1. **Private bucket** - R2 > Create bucket > `vinyl-client`. Do **not** add a
   public custom domain to it.
2. **Worker** - create a Worker named `vinyl-client-sites`; paste
   `vinyl-client-worker.js` (or `npx wrangler deploy`). Bind R2 bucket
   `vinyl-client` as **`CLIENT_BUCKET`**. Add the route
   `*.clients.vinylcurator.net/*`.
3. **DNS** - add a **proxied** record for `*.clients` (e.g. AAAA `100::`, orange
   cloud) so the wildcard hostname resolves and hits the Worker route.
4. **Access** - Zero Trust > Access > Applications > Add a **self-hosted**
   application for `*.clients.vinylcurator.net` (or one app per client hostname).
   Identity: Google and/or one-time email PIN. Default policy: **deny** (so a
   hostname with no matching client policy is closed).

## Onboard a client

1. Build the client's self-contained site (see build.ps1 private mode, P4) and
   `rclone sync` it to `r2:vinyl-client/<slug>/`.
2. Add a Cloudflare Access **policy** allowing that client's email(s), scoped to
   `<slug>.clients.vinylcurator.net`.
3. Send the client their URL. First visit -> Access login -> their archive.

## Offboard a client (takedown)

1. Delete the client's bucket prefix: `rclone purge r2:vinyl-client/<slug>`.
2. Remove their Access policy.

The pages and images are gone completely (private bucket, real deletion) and
nothing of theirs was ever in the public repo - so takedown is total, with no
git-history residue to disclose.

## Hardening TODO

The Worker fails closed on a missing Access identity and relies on Access
enforcing the hostname at the edge. For defence-in-depth, verify the
`Cf-Access-Jwt-Assertion` signature against the team JWKS
(`https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`) inside the Worker.
