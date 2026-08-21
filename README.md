# vinylcurator.net — archive site

The public, static archive site for a documented vinyl collection. Generated —
do not hand-edit `index.html`, `albums/`, `sitemap.xml`, or `collection.json`;
edit `templates/` + `assets/` and rebuild.

## How it works

1. In the Vinyl Project sheet, tick the `Website` column on the albums to
   publish, then run **Owner: export website data...** — this writes a
   whitelisted `collection.json` (no prices, ever) to
   `G:\My Drive\Vinyl Curator Website\`.
2. Build:

   ```
   powershell -ExecutionPolicy Bypass -File build.ps1
   ```

   Reads the export + the album photo folders on the Drive mount, resizes
   photos to web size (1600px + 480px thumbs; re-encoding strips EXIF/GPS),
   and renders the site. Incremental — only changed photos are reconverted
   (`-Force` rebuilds everything).
3. Preview: `powershell -ExecutionPolicy Bypass -File serve.ps1` →
   http://localhost:8322/
4. Publish: `build.ps1 -Push` (commit + push; GitHub Pages redeploys).

The build refuses to run if any price-like key or `$` amount appears anywhere
in the data — album pages double as eBay/Discogs link targets and must stay
price-free.

## Layout

```
/                      landing page (generated from templates/landing.html)
/albums/               Personal Archive index (Collection tab): cards + filter
/available/            Available from Archive (For Sale tab) + Discogs links
/sold/                 Sold from Archive (Sold tab); no links, no prices
/albums/<slug>/        one album page; photos in img/ (web) + img/t/ (thumbs)
/assets/               shared CSS + JS (lightbox, filter)
/collection.json       public copy of the whitelisted export
templates/  build.ps1  serve.ps1        the generator
```

Slug rule (must match `websiteSlug_` in the sheet script): Drive folder name,
lowercased, every run of non-alphanumerics becomes `-`, trimmed.

## When an album's photos don't load

The build looks for each album's photo folder (by its Drive folder name) under
the photo roots configured at the top of `build.ps1`. If a build warning says a
folder wasn't found, point to it in `build.config.json` (local only, not
committed):

```json
{
  "photoRoots": ["G:\\My Drive\\Some Other Import Folder"],
  "folderOverrides": {
    "artist-name-album-title": "G:\\My Drive\\Wherever\\Artist_Album"
  }
}
```

`folderOverrides` wins for that one album (key = the album's slug);
`photoRoots` adds extra folders to search for every album.

