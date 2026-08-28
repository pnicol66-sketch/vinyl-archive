# Client handover email — template

Fill the three placeholders and send. `New-VinylClient.ps1` prints the handover
URL at the end of a run; this is the message that goes with it.

- `{NAME}` — the client's name (e.g. "Jane")
- `{URL}` — `https://<slug>.vinylcurator.net`
- `{EMAIL}` — the Google account they shared the Drive folder from

Sending stays a human click. To have Claude stage it as a **Gmail draft** (never
sent automatically), ask: "draft the handover email for `<slug>`" — it fills this
template and creates a draft in your Gmail for you to review and send.

---

**Subject:** Your private record archive is ready

Hi {NAME},

Your collection is now online as a private, login-gated archive:

  {URL}

To view it, click **Continue with Google** and sign in with **{EMAIL}** — the
same Google account you shared your photos from. Only that account can get in;
the site isn't listed anywhere and isn't searchable.

One thing you'll notice: Google's sign-in screen says "continue to
cloudflareaccess.com." That's expected — Cloudflare is the secure gateway that
guards your archive. Nothing to worry about.

Browse the covers, the pressing details, and the record surfaces at your
leisure. Any corrections or additions, just let me know.

Best,
Paul

---

## Notes
- The `{EMAIL}` must match the address allowed on the client's Cloudflare Access
  policy (that's what `New-VinylClient -Email` set). A different Google account
  will be refused at the gateway.
- If the client can't get in, run `.\Test-VinylClient.ps1 -Slug <slug> -Email <their-email>`
  to confirm a policy allows that exact address.
