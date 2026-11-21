// Every request needs HTTP Basic auth (any user name, the shared passphrase). The APK embeds the
// shop's sync token, so nothing here is served without it.
async function sha256(text) {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, "0")).join("");
}
export default {
  async fetch(request, env) {
    const header = request.headers.get("Authorization") ?? "";
    let ok = false;
    if (header.startsWith("Basic ") && env.PASSWORD_SHA256) {
      try { const pass = atob(header.slice(6)).split(":").slice(1).join(":"); ok = await sha256(pass) === env.PASSWORD_SHA256; } catch {}
    }
    if (!ok) return new Response("合言葉が必要です", { status: 401, headers: { "WWW-Authenticate": 'Basic realm="TOS", charset="UTF-8"', "Cache-Control": "no-store" } });
    const response = await env.ASSETS.fetch(request);
    const headers = new Headers(response.headers);
    headers.set("Cache-Control", "no-store");
    headers.set("X-Robots-Tag", "noindex");
    if (new URL(request.url).pathname.endsWith(".apk")) headers.set("Content-Type", "application/vnd.android.package-archive");
    return new Response(response.body, { status: response.status, headers });
  }
};
