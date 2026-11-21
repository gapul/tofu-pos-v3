// Capability URL: the page lives under /<secret>/ (only its SHA-256 is stored, as LINK_TOKEN_SHA256).
// The APK embeds the shop's sync token, so nothing is served without the secret path.
async function sha256(text) {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, "0")).join("");
}
const notFound = () => new Response("Not found", { status: 404, headers: { "Cache-Control": "no-store", "X-Robots-Tag": "noindex" } });
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const m = /^\/([A-Za-z0-9_-]{20,})(\/.*)?$/.exec(url.pathname);
    if (!m || !env.LINK_TOKEN_SHA256 || await sha256(m[1]) !== env.LINK_TOKEN_SHA256) return notFound();
    // Relative links on the page need the trailing slash.
    if (!m[2]) return Response.redirect(url.origin + url.pathname + "/", 302);
    const inner = new URL(m[2] === "/" ? "/index.html" : m[2], url.origin);
    const response = await env.ASSETS.fetch(new Request(inner, request));
    const headers = new Headers(response.headers);
    headers.set("Cache-Control", "no-store");
    headers.set("X-Robots-Tag", "noindex");
    headers.set("Referrer-Policy", "no-referrer");
    if (inner.pathname.endsWith(".apk")) {
      headers.set("Content-Type", "application/vnd.android.package-archive");
      headers.set("Content-Disposition", 'attachment; filename="TOS.apk"');
    }
    return new Response(response.body, { status: response.status, headers });
  }
};
