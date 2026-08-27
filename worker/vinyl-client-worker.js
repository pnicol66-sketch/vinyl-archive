// Vinyl Curator - private client site Worker.
//
// Serves each client's archive from ONE private R2 bucket, keyed by the client
// subdomain label:  https://<slug>.vinylcurator.net/<path>  ->  R2 object
// "<slug>/<path>" (a trailing "/" or an extensionless path resolves to
// ".../index.html"). Nothing here is public: the bucket is private and the
// hostname is gated by Cloudflare Access (a per-client email allow-list) in
// front of this Worker, so only an authenticated, authorised client's request
// ever reaches the code below.
//
// Binding (wrangler.toml): CLIENT_BUCKET -> the private R2 bucket (e.g. vinyl-client).
//
// Security model: Access protects the hostname at Cloudflare's edge, so every
// request that arrives here has already passed the login + policy check and
// carries an Access identity. We fail CLOSED if that identity is absent - a
// request with no Access header means the gate is misconfigured or bypassed,
// and we must never serve private pages in that case. (Hardening TODO: verify
// the Cf-Access-Jwt-Assertion signature against the team's JWKS for
// defence-in-depth; presence-plus-edge-enforcement is the first cut.)

const TYPES = {
  html: 'text/html; charset=utf-8', css: 'text/css; charset=utf-8',
  js: 'text/javascript; charset=utf-8', json: 'application/json',
  svg: 'image/svg+xml', jpg: 'image/jpeg', jpeg: 'image/jpeg',
  png: 'image/png', webp: 'image/webp', gif: 'image/gif',
  ico: 'image/x-icon', xml: 'application/xml',
  txt: 'text/plain; charset=utf-8', woff2: 'font/woff2', woff: 'font/woff'
};

function contentType(key) {
  const ext = key.slice(key.lastIndexOf('.') + 1).toLowerCase();
  return TYPES[ext] || 'application/octet-stream';
}

export default {
  async fetch(request, env) {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }

    // Fail closed unless Cloudflare Access has authenticated the request.
    const hasIdentity = request.headers.get('Cf-Access-Jwt-Assertion') ||
      request.headers.get('Cf-Access-Authenticated-User-Email');
    if (!hasIdentity) {
      return new Response('Forbidden - this site is served only through Cloudflare Access.', { status: 403 });
    }

    const url = new URL(request.url);
    const label = url.hostname.split('.')[0];          // <slug>
    if (!label || label === 'www' || label === 'img') {
      return new Response('Not found', { status: 404 });
    }

    // Resolve the request path to an object key, defaulting directories to
    // index.html. Reject any '..' before it can escape the client's prefix.
    let path = decodeURIComponent(url.pathname);
    if (path.includes('..')) return new Response('Bad request', { status: 400 });
    if (path.endsWith('/')) path += 'index.html';
    else if (!path.slice(path.lastIndexOf('/') + 1).includes('.')) path += '/index.html';
    const key = label + path;                          // e.g. smith/albums/x/index.html

    const obj = await env.CLIENT_BUCKET.get(key);
    if (!obj || !obj.body) {
      return new Response('Not found', { status: 404, headers: { 'Content-Type': 'text/plain' } });
    }

    const headers = new Headers();
    obj.writeHttpMetadata(headers);                    // etag, etc.
    headers.set('Content-Type', contentType(key));     // our map wins over stored metadata
    headers.set('Cache-Control', 'private, max-age=300');
    headers.set('X-Robots-Tag', 'noindex');            // private: never index, even if leaked
    return new Response(request.method === 'HEAD' ? null : obj.body, { headers });
  }
};
