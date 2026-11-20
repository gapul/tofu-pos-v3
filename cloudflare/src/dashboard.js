// Static page only: it contains no data. The token stays in sessionStorage and is sent to /v1/dashboard.
export const DASHBOARD_HTML = `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>TOS ダッシュボード</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--muted:#667085;--line:#e3e6eb;--accent:#2f6fde;--warn:#c4320a;--warnbg:#fff1ec;--ok:#067647}
@media (prefers-color-scheme:dark){:root{--bg:#111418;--card:#1a1f26;--fg:#e8ebf0;--muted:#98a2b3;--line:#2c333d;--accent:#6f9cff;--warn:#ff8a65;--warnbg:#3a2018;--ok:#4cc38a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Hiragino Sans","Noto Sans JP",sans-serif}
header{position:sticky;top:0;background:var(--card);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;flex-wrap:wrap;gap:8px;align-items:center;z-index:1}
header h1{font-size:17px;margin:0 auto 0 0}main{max-width:1100px;margin:0 auto;padding:16px}
input,button{font:inherit;color:inherit;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:6px 10px}
button{cursor:pointer}button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.muted{color:var(--muted);font-size:13px}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:16px}
.card,section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.card b{display:block;font-size:22px;font-variant-numeric:tabular-nums}section{margin-bottom:16px;overflow-x:auto}
h2{font-size:15px;margin:0 0 8px}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{padding:6px 8px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}th:first-child,td:first-child{text-align:left;white-space:normal}
th{font-size:13px;color:var(--muted);font-weight:600}.warn{color:var(--warn);font-weight:700}tr.warn td{background:var(--warnbg)}
.thumb{width:32px;height:32px;border-radius:6px;object-fit:cover;vertical-align:middle;margin-right:8px;background:var(--line)}
.bar{height:8px;background:var(--accent);border-radius:4px;min-width:2px}svg text{fill:var(--muted);font-size:10px}svg rect{fill:var(--accent)}
#login{max-width:420px;margin:40px auto}#login input{width:100%;margin:8px 0}#error{color:var(--warn);margin:8px 0}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px}.grid2 section{margin-bottom:0}.grid2{margin-bottom:16px}
</style>
</head>
<body>
<header><h1>TOS ダッシュボード</h1>
<label class="muted"><input type="date" id="date"> </label>
<label class="muted"><input type="checkbox" id="all"> 全期間</label>
<button id="refresh">更新</button><button id="logout">ログアウト</button>
<span class="muted" id="updated"></span></header>
<main>
<div id="error" role="alert"></div>
<form id="login" class="card" hidden><h2>ダッシュボード用トークン</h2>
<p class="muted">レジ端末用とは別のトークンを入力してください。このタブを閉じると消えます。</p>
<input type="password" id="token" autocomplete="off" required><button class="primary" type="submit">表示</button></form>
<div id="view" hidden>
<div class="cards" id="cards"></div>
<section><h2>時間帯別売上（JST）</h2><div id="hours"></div></section>
<div class="grid2"><section><h2>商品別</h2><div id="products"></div></section>
<section><h2>客層（年代×性別・件数／売上）</h2><div id="segments"></div></section>
<section><h2>グループ別</h2><div id="groups"></div></section></div>
<div class="grid2"><section><h2>在庫（少ない順・マイナスは赤）</h2><div id="stock"></div></section>
<section><h2>端末別</h2><div id="devices"></div></section></div>
<section><h2>最近の会計</h2><div id="recent"></div></section>
<section><h2>レジ締め</h2><div id="sessions"></div></section>
</div>
</main>
<script>
"use strict";
const $ = id => document.getElementById(id), KEY = "tos-dashboard-token";
const yen = n => n == null ? "—" : "¥" + Number(n).toLocaleString("ja-JP"), num = n => n == null ? "—" : Number(n).toLocaleString("ja-JP");
const jst = s => s ? new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(s)) : "—";
const today = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Tokyo" }).format(new Date());
const AGE = { child: "子ども", student: "学生", adult: "大人", senior: "シニア" }, GENDER = { male: "男性", female: "女性", other: "その他" };
const GROUP = { solo: "一人", friends: "友人", family: "家族", couple: "カップル", group: "グループ" };
function store(action, value) { try { return action === "get" ? sessionStorage.getItem(KEY) : action === "set" ? sessionStorage.setItem(KEY, value) : sessionStorage.removeItem(KEY); } catch { return null; } }
let memoryToken = null, loading = false;
const token = () => store("get") || memoryToken;
function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) if (k === "class") node.className = v; else node.setAttribute(k, v);
  for (const c of children) node.append(c instanceof Node ? c : document.createTextNode(c == null ? "" : String(c)));
  return node;
}
function table(head, rows) {
  if (!rows.length) return el("p", { class: "muted" }, "データなし");
  return el("table", {}, el("thead", {}, el("tr", {}, ...head.map(h => el("th", {}, h)))),
    el("tbody", {}, ...rows.map(r => { const tr = el("tr", r.warn ? { class: "warn" } : {}, ...r.cells.map(c => el("td", {}, c))); return tr; })));
}
function hoursChart(hours) {
  const ns = "http://www.w3.org/2000/svg", max = Math.max(1, ...hours.map(h => h.sales)), w = 24 * 20, h = 140;
  const svg = document.createElementNS(ns, "svg"); svg.setAttribute("viewBox", "0 0 " + w + " " + (h + 18)); svg.setAttribute("width", "100%"); svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", "時間帯別売上");
  for (const x of hours) {
    const bh = Math.round(x.sales / max * h), r = document.createElementNS(ns, "rect");
    r.setAttribute("x", x.hour * 20 + 3); r.setAttribute("y", h - bh); r.setAttribute("width", 14); r.setAttribute("height", bh); r.setAttribute("rx", 2);
    const t = document.createElementNS(ns, "title"); t.textContent = x.hour + "時台 " + yen(x.sales) + "（" + x.orders + "件）"; r.append(t); svg.append(r);
    if (x.hour % 3 === 0) { const l = document.createElementNS(ns, "text"); l.setAttribute("x", x.hour * 20 + 10); l.setAttribute("y", h + 13); l.setAttribute("text-anchor", "middle"); l.textContent = x.hour; svg.append(l); }
  }
  return svg;
}
// Photos need the bearer token, so they are fetched once per hash and shown via blob URLs.
const images = new Map();
function thumb(hash) {
  const img = el("img", { class: "thumb", alt: "", loading: "lazy" });
  if (!images.has(hash)) images.set(hash, fetch("/v1/images/" + hash, { headers: { Authorization: "Bearer " + token() } })
    .then(r => r.ok ? r.blob() : Promise.reject(new Error("HTTP " + r.status))).then(b => URL.createObjectURL(b))
    .catch(e => { images.delete(hash); throw e; }));
  images.get(hash).then(url => { img.src = url; }, () => img.remove());
  return img;
}
const named = (hash, name) => hash ? el("span", {}, thumb(hash), name) : name;
function bar(value, max) { const d = el("div", { class: "bar" }); d.style.width = Math.max(2, Math.round(value / Math.max(1, max) * 100)) + "%"; return d; }
function render(d) {
  const t = d.totals;
  $("cards").replaceChildren(...[["純売上", yen(t.net_sales)], ["会計数", num(t.orders) + "件"], ["客単価", yen(t.average)],
    ["取消", num(t.cancelled_orders) + "件"], ["取消額", yen(t.cancelled_amount)]].map(([k, v]) => el("div", { class: "card" }, el("span", { class: "muted" }, k), el("b", {}, v))));
  $("hours").replaceChildren(hoursChart(d.by_hour));
  const maxQ = Math.max(0, ...d.by_product.map(p => p.quantity));
  $("products").replaceChildren(table(["商品", "数量", "", "売上"], d.by_product.map(p => ({ cells: [named(p.image_hash, p.name), num(p.quantity), bar(p.quantity, maxQ), yen(p.sales)] }))));
  const genders = ["male", "female", "other", null], ages = ["child", "student", "adult", "senior", null];
  const cell = (a, g) => { const s = d.segments.find(x => x.age === a && x.gender === g); return s ? num(s.orders) + "件 / " + yen(s.sales) : "—"; };
  const usedAges = ages.filter(a => a !== null || d.segments.some(s => s.age === null)), usedGenders = genders.filter(g => g !== null || d.segments.some(s => s.gender === null));
  $("segments").replaceChildren(table(["年代＼性別", ...usedGenders.map(g => g ? GENDER[g] : "未設定")], usedAges.map(a => ({ cells: [a ? AGE[a] : "未設定", ...usedGenders.map(g => cell(a, g))] }))));
  // Negative stock is allowed (sold beyond the count); highlight it, and mark stop-at-zero items that are sold out.
  $("groups").replaceChildren(table(["グループ", "件数", "売上"], d.groups.map(g => ({ cells: [g.group ? GROUP[g.group] : "未設定", num(g.orders), yen(g.sales)] }))));
  $("stock").replaceChildren(table(["商品", "在庫", "販売数"], d.stock.map(s => ({ warn: s.stock < 0,
    cells: [named(s.image_hash, s.name + (s.active ? "" : "（停止中）") + (s.stop_at_zero && s.stock <= 0 ? "（売り切れ）" : "")), s.stock < 0 ? "−" + num(-s.stock) : num(s.stock), num(s.sold)] }))));
  $("devices").replaceChildren(table(["端末", "会計数", "売上", "最終受信"], d.devices.map(x => ({ cells: [x.device_label || (x.device_id ? x.device_id.slice(0, 8) : "0.3.0以前"), num(x.orders), yen(x.sales), jst(x.last_received_at)] }))));
  const label = id => { const x = d.devices.find(v => v.device_id === id); return x?.device_label || (id ? id.slice(0, 8) : "—"); };
  $("recent").replaceChildren(table(["整理番号", "時刻", "金額", "端末"], d.recent.map(o => ({ warn: o.cancelled,
    cells: [(o.ticket_no ?? "—") + (o.cancelled ? "（取消）" : ""), jst(o.created_at), yen(o.total), label(o.device_id)] }))));
  $("sessions").replaceChildren(table(["端末", "開始", "締め", "準備金", "理論値", "実査", "差額", "売上", "取消", "件数"], d.sessions.map(s => ({
    warn: s.difference != null && s.difference !== 0,
    cells: [s.device_label, jst(s.opened_at), s.closed_at ? jst(s.closed_at) : "営業中", yen(s.float_total), yen(s.expected_total), yen(s.counted_total),
      s.difference == null ? "—" : (s.difference > 0 ? "+" : "") + yen(s.difference), yen(s.sales_total), yen(s.cancel_total), num(s.order_count)] }))));
}
async function load() {
  const t = token();
  $("login").hidden = !!t; if (!t || loading) return;
  loading = true;
  try {
    const q = $("all").checked ? "" : "?date=" + encodeURIComponent($("date").value || today());
    const r = await fetch("/v1/dashboard" + q, { headers: { Authorization: "Bearer " + t }, cache: "no-store" });
    if (r.status === 401) { store("remove"); memoryToken = null; $("view").hidden = true; $("login").hidden = false; $("error").textContent = "トークンが違います。"; return; }
    if (!r.ok) throw new Error("HTTP " + r.status);
    render(await r.json()); $("view").hidden = false; $("error").textContent = "";
    $("updated").textContent = "更新 " + new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", timeStyle: "medium" }).format(new Date());
  } catch (e) { $("error").textContent = "読み込みに失敗しました（" + e.message + "）。30秒後に再試行します。"; }
  finally { loading = false; }
}
$("date").value = today();
$("login").addEventListener("submit", e => { e.preventDefault(); const v = $("token").value.trim(); if (!v) return; memoryToken = v; store("set", v); $("token").value = ""; load(); });
$("logout").addEventListener("click", () => { store("remove"); memoryToken = null; images.forEach(p => p.then(URL.revokeObjectURL, () => {})); images.clear(); $("view").hidden = true; $("login").hidden = false; });
$("refresh").addEventListener("click", load); $("date").addEventListener("change", () => { $("all").checked = false; load(); }); $("all").addEventListener("change", load);
setInterval(() => { if (!document.hidden) load(); }, 30000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) load(); });
load();
</script>
</body>
</html>`;
