import { MAX_BYTES, AGES, GENDERS, GROUPS, RELATIONS, DENOMINATIONS, json, digest, requireValue, chars, text, money, integer, date, normalize, readBody, readBytes } from "./lib.js";
import { DASHBOARD_HTML } from "./dashboard.js";
import { PRIVACY_HTML } from "./privacy.js";

const MAX_ORDERS = 50;
const FEED_BYTES = 512 * 1024;
const IMAGE_BYTES = 512 * 1024;
const HASH = /^[a-f0-9]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Next shop-wide feed sequence; evaluated inside the writing statement, so D1's serialized batches keep it unique.
const SEQ = "(MAX(COALESCE((SELECT MAX(seq) FROM cloud_orders WHERE shop_id=?),0),COALESCE((SELECT MAX(seq) FROM cloud_products WHERE shop_id=?),0))+1)";
// Every product tracks stock (revision 2); the track_stock column is legacy and ignored.
// Stock is derived at read time from indexed aggregates: adjustments minus non-cancelled sales. It may be negative.
const STOCK = `(COALESCE((SELECT SUM(e.delta) FROM cloud_stock_events e WHERE e.shop_id=p.shop_id AND e.product_id=p.id),0)
  -COALESCE((SELECT SUM(l.quantity) FROM cloud_order_lines l WHERE l.shop_id=p.shop_id AND l.product_id=p.id AND l.cancelled=0),0))`;
const PRODUCT = `SELECT p.id,p.name,p.price,p.active,p.stop_at_zero,p.image_hash,p.version,p.seq,${STOCK} AS stock FROM cloud_products p`;
// track_stock stays in the response, always true, for early 0.4.0 builds.
const productOut = row => ({ id: row.id, name: row.name, price: row.price, active: row.active === 1, track_stock: true,
  stop_at_zero: row.stop_at_zero === 1, image_hash: row.image_hash ?? null, version: row.version, stock: row.stock, seq: row.seq });

async function parse(request, validate) {
  try { return { value: validate(await readBody(request)) }; }
  catch (error) { return { response: json({ error: error.message }, error.message === "too large" ? 413 : 400) }; }
}
function list(body, key, max) {
  requireValue(body && body.schema_version === 1 && Array.isArray(body[key]) && body[key].length >= 1 && body[key].length <= max, "invalid batch");
  return body[key];
}
function unique(items, message) { requireValue(new Set(items.map(x => x.id)).size === items.length, message); return items; }

async function sync(request, env) {
  const parsed = await parse(request, body => unique(list(body, "orders", MAX_ORDERS).map(normalize), "duplicate order"));
  if (parsed.response) return parsed.response;
  const orders = parsed.value, shop = env.SHOP_ID;
  const placeholders = orders.map(() => "?").join(",");
  const select = () => env.DB.prepare(`SELECT id,revision,base_hash,payload_hash FROM cloud_orders WHERE shop_id=? AND id IN (${placeholders})`)
    .bind(shop, ...orders.map(x => x.id));
  const current = new Map((await select().all()).results.map(row => [row.id, row]));
  const records = await Promise.all(orders.map(async order => {
    const payload = JSON.stringify(order);
    const base = JSON.stringify({ ...order, revision: 1, cancelled_at: null, cancellation_reason: null });
    return { order, payload, hash: await digest(payload), baseHash: await digest(base) };
  }));
  const writes = [], won = [], now = new Date().toISOString();
  for (const record of records) {
    const { order, payload, hash, baseHash } = record;
    const existing = current.get(order.id);
    // A lost response causes a read only: identical retries never rewrite D1.
    if (existing && (existing.payload_hash === hash || existing.revision >= order.revision || existing.base_hash !== baseHash)) continue;
    writes.push(env.DB.prepare(`INSERT INTO cloud_orders(shop_id,id,revision,base_hash,payload_hash,payload,total_yen,cancelled,received_at,seq,device_id,customer_age,customer_gender,customer_group,ticket_no,customer_relation,created_at)
      VALUES(?,?,?,?,?,?,?,?,?,${SEQ},?,?,?,?,?,?,?) ON CONFLICT(shop_id,id) DO UPDATE SET revision=excluded.revision,payload_hash=excluded.payload_hash,
      payload=excluded.payload,total_yen=excluded.total_yen,cancelled=excluded.cancelled,received_at=excluded.received_at,seq=excluded.seq,
      device_id=excluded.device_id,customer_age=excluded.customer_age,customer_gender=excluded.customer_gender,customer_group=excluded.customer_group,ticket_no=excluded.ticket_no,customer_relation=excluded.customer_relation,created_at=excluded.created_at
      WHERE excluded.revision>cloud_orders.revision AND excluded.base_hash=cloud_orders.base_hash`)
      .bind(shop, order.id, order.revision, baseHash, hash, payload, order.total, order.revision === 2 ? 1 : 0, now, shop, shop,
        order.device_id ?? null, order.customer_age ?? null, order.customer_gender ?? null, order.customer_group ?? null, order.ticket_no ?? null, order.customer_relation ?? null, order.created_at));
    won.push([order.id, hash]);
  }
  if (writes.length) {
    // Lines and stock seq follow only rows whose stored hash is ours (the EXISTS guard as a join), so a
    // concurrent identical replay rewrites the same line rows (idempotent REPLACE) and never double counts.
    const keys = JSON.stringify(won);
    const winners = "FROM json_each(?) k, cloud_orders o, json_each(o.payload,'$.lines') j WHERE o.shop_id=? AND o.id=json_extract(k.value,'$[0]') AND o.payload_hash=json_extract(k.value,'$[1]')";
    writes.push(env.DB.prepare(`INSERT OR REPLACE INTO cloud_order_lines(shop_id,order_id,product_id,quantity,price,cancelled)
      SELECT o.shop_id,o.id,json_extract(j.value,'$.product_id'),json_extract(j.value,'$.quantity'),json_extract(j.value,'$.price'),o.cancelled ${winners}`)
      .bind(keys, shop));
    writes.push(env.DB.prepare(`UPDATE cloud_products SET seq=m.base+r.n FROM (SELECT ${SEQ}-1 AS base) m,
      (SELECT p.id AS id,ROW_NUMBER() OVER (ORDER BY p.id) AS n FROM cloud_products p WHERE p.shop_id=?
        AND p.id IN (SELECT json_extract(j.value,'$.product_id') ${winners})) r
      WHERE cloud_products.shop_id=? AND cloud_products.id=r.id`).bind(shop, shop, shop, keys, shop, shop));
  }
  // Verify the winning hashes within the same transaction, including concurrent requests.
  const rows = writes.length ? (await env.DB.batch([...writes, select()])).at(-1).results : [...current.values()];
  const stored = new Map(rows.map(row => [row.id, row]));
  const accepted = [], conflicts = [];
  for (const { order, hash } of records) {
    if (stored.get(order.id)?.payload_hash === hash) accepted.push({ id: order.id, revision: order.revision });
    else conflicts.push({ id: order.id, reason: "revision_or_content_conflict" });
  }
  return json({ schema_version: 1, accepted, conflicts });
}
// Catalogs are immutable, content-addressed snapshots. Replays are read-only.
async function catalogs(request, env) {
  if (request.method === "GET") {
    const before = new URL(request.url).searchParams.get("before");
    let query = "SELECT id,product_count,received_at FROM cloud_catalogs WHERE shop_id=?", values = [env.SHOP_ID];
    if (before) {
      const parts = before.split("|");
      if (parts.length !== 2 || !date(parts[0]) || !/^[a-f0-9]{64}$/.test(parts[1])) return json({ error: "invalid cursor" },400);
      query += " AND (received_at,id)<(?,?)"; values.push(...parts);
    }
    const rows = (await env.DB.prepare(query+" ORDER BY received_at DESC,id DESC LIMIT 21").bind(...values).all()).results;
    const catalogs = rows.slice(0,20), last = catalogs.at(-1);
    return json({ schema_version: 1, catalogs, next: rows.length > 20 ? last.received_at+"|"+last.id : null });
  }
  const parsed = await parse(request, body => {
    requireValue(body && body.schema_version === 1 && Array.isArray(body.products) && body.products.length <= 1000, "invalid catalog");
    const products = body.products.map(p => {
      requireValue(p && text(p.id, 128) && text(p.name, MAX_BYTES) && p.name.trim() && money(p.price), "invalid product");
      return { id: p.id, name: p.name, price: p.price };
    }).sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    return unique(products, "duplicate product");
  });
  if (parsed.response) return parsed.response;
  const products = parsed.value, payload = JSON.stringify(products), id = await digest(payload);
  const existing = await env.DB.prepare("SELECT id FROM cloud_catalogs WHERE shop_id=? AND id=?").bind(env.SHOP_ID, id).all();
  if (!existing.results.length) {
    await env.DB.batch([env.DB.prepare("INSERT OR IGNORE INTO cloud_catalogs VALUES(?,?,?,?,?)")
      .bind(env.SHOP_ID, id, payload, products.length, new Date().toISOString())]);
  }
  return json({ schema_version: 1, id, product_count: products.length });
}
async function restore(request, env) {
  const url = new URL(request.url), after = url.searchParams.get("after") ?? "", catalog = url.searchParams.get("catalog_id") ?? "";
  if (after.length > 128 || (catalog && !/^[a-f0-9]{64}$/.test(catalog))) return json({ error: "invalid cursor/catalog" }, 400);
  let products = [];
  if (!after && catalog) {
    const rows = await env.DB.prepare("SELECT payload FROM cloud_catalogs WHERE shop_id=? AND id=?").bind(env.SHOP_ID, catalog).all();
    if (!rows.results.length) return json({ error: "catalog not found" }, 404);
    products = JSON.parse(rows.results[0].payload);
  }
  // Bound SQL output as well as the HTTP response. Window only the next 50 indexed rows,
  // never the entire shop. A single large order is still returned and can make progress.
  const rows = await env.DB.prepare(`SELECT id,payload FROM (
    SELECT id,payload,SUM(length(CAST(payload AS BLOB))) OVER (ORDER BY id) AS bytes,
    ROW_NUMBER() OVER (ORDER BY id) AS position FROM (
      SELECT id,payload FROM cloud_orders WHERE shop_id=? AND id>? ORDER BY id LIMIT 50
    )
  ) WHERE bytes<=? OR position=1 ORDER BY id`).bind(env.SHOP_ID, after, MAX_BYTES).all();
  return json({ schema_version: 1, catalog_id: catalog || null, after,
    products, orders: rows.results.map(row => JSON.parse(row.payload)),
    next: rows.results.length ? rows.results.at(-1).id : null });
}
// The cloud owns the product master. Optimistic versions: a stale base_version never overwrites.
// A missing row is created whatever base_version says (e.g. the cloud DB was reset), so every result carries a product.
async function products(request, env) {
  const parsed = await parse(request, body => unique(list(body, "products", 100).map(p => {
    requireValue(p && typeof p === "object" && text(p.id, 128), "invalid product id");
    const name = typeof p.name === "string" ? p.name.trim() : "", length = chars(name);
    requireValue(length >= 1 && length <= 100, "invalid name");
    requireValue(money(p.price) && typeof p.active === "boolean" && (p.stop_at_zero == null || typeof p.stop_at_zero === "boolean") && integer(p.base_version, 0, Number.MAX_SAFE_INTEGER), "invalid product");
    // image_hash is versioned content like the name: omitted means "no photo", never "unchanged".
    requireValue(p.image_hash == null || (typeof p.image_hash === "string" && HASH.test(p.image_hash)), "invalid image_hash");
    return { id: p.id, name, price: p.price, active: p.active ? 1 : 0, stop_at_zero: p.stop_at_zero ? 1 : 0, image_hash: p.image_hash ?? null, base_version: p.base_version };
  }), "duplicate product"));
  if (parsed.response) return parsed.response;
  const items = parsed.value, shop = env.SHOP_ID, ids = JSON.stringify(items.map(p => p.id));
  // Devices upload images first; a reference to an unknown image rejects the request before any write.
  const hashes = [...new Set(items.map(p => p.image_hash).filter(Boolean))];
  if (hashes.length) {
    const found = new Set((await env.DB.prepare("SELECT hash FROM cloud_images WHERE shop_id=? AND hash IN (SELECT value FROM json_each(?))")
      .bind(shop, JSON.stringify(hashes)).all()).results.map(r => r.hash));
    const missing = items.filter(p => p.image_hash && !found.has(p.image_hash));
    if (missing.length) return json({ error: "unknown image_hash", products: missing.map(p => p.id), image_hashes: [...new Set(missing.map(p => p.image_hash))] }, 400);
  }
  const select = () => env.DB.prepare(`${PRODUCT} WHERE p.shop_id=? AND p.id IN (SELECT value FROM json_each(?))`).bind(shop, ids);
  const current = new Map((await select().all()).results.map(row => [row.id, row]));
  const same = (row, p) => row && row.name === p.name && row.price === p.price && row.active === p.active && row.stop_at_zero === p.stop_at_zero && (row.image_hash ?? null) === p.image_hash;
  const writes = [], now = new Date().toISOString();
  for (const p of items) {
    const row = current.get(p.id);
    if (same(row, p)) continue;
    if (!row) writes.push(env.DB.prepare(`INSERT INTO cloud_products(shop_id,id,name,price,active,track_stock,stop_at_zero,image_hash,version,seq,updated_at)
      VALUES(?,?,?,?,?,1,?,?,1,${SEQ},?) ON CONFLICT(shop_id,id) DO NOTHING`).bind(shop, p.id, p.name, p.price, p.active, p.stop_at_zero, p.image_hash, shop, shop, now));
    else if (row && row.version === p.base_version) writes.push(env.DB.prepare(`UPDATE cloud_products SET name=?,price=?,active=?,track_stock=1,stop_at_zero=?,image_hash=?,
      version=version+1,seq=${SEQ},updated_at=? WHERE shop_id=? AND id=? AND version=?`)
      .bind(p.name, p.price, p.active, p.stop_at_zero, p.image_hash, shop, shop, now, shop, p.id, p.base_version));
  }
  // Status is decided from the row stored after the batch, so concurrent editors cannot both "win".
  const rows = writes.length ? (await env.DB.batch([...writes, select()])).at(-1).results : [...current.values()];
  const stored = new Map(rows.map(row => [row.id, row]));
  const results = items.map(p => {
    const row = stored.get(p.id);
    return { id: p.id, status: same(row, p) ? "applied" : "conflict", product: row ? productOut(row) : null };
  });
  return json({ schema_version: 1, results });
}
async function stock(request, env) {
  const parsed = await parse(request, body => unique(list(body, "events", 100).map(e => {
    requireValue(e && typeof e === "object" && typeof e.id === "string" && UUID.test(e.id) && text(e.product_id, 128), "invalid event");
    requireValue((e.kind === "add" || e.kind === "set") && date(e.created_at), "invalid event");
    requireValue(e.kind === "add" ? integer(e.quantity, -1_000_000, 1_000_000) : integer(e.quantity, 0, 1_000_000), "invalid quantity");
    requireValue(e.reason == null || (typeof e.reason === "string" && chars(e.reason) <= 200), "invalid reason");
    return { id: e.id, product_id: e.product_id, kind: e.kind, quantity: e.quantity, reason: e.reason ?? null, created_at: e.created_at };
  }), "duplicate event"));
  if (parsed.response) return parsed.response;
  const events = parsed.value, shop = env.SHOP_ID, ids = JSON.stringify(events.map(e => e.id));
  const productIds = [...new Set(events.map(e => e.product_id))];
  const reads = () => [
    env.DB.prepare("SELECT id,product_id FROM cloud_stock_events WHERE shop_id=? AND id IN (SELECT value FROM json_each(?))").bind(shop, ids),
    env.DB.prepare(`${PRODUCT} WHERE p.shop_id=? AND p.id IN (SELECT value FROM json_each(?))`).bind(shop, JSON.stringify(productIds))
  ];
  let [stored, rows] = (await env.DB.batch(reads())).map(r => r.results);
  const known = new Set(stored.map(r => r.id)), fresh = events.filter(e => !known.has(e.id));
  if (fresh.length) {
    // Events apply in request order inside one transaction; "set" computes its delta from the stock at that moment.
    const now = new Date().toISOString(), freshIds = JSON.stringify(fresh.map(e => e.id));
    const writes = fresh.map(e => env.DB.prepare(`INSERT OR IGNORE INTO cloud_stock_events(shop_id,id,product_id,delta,kind,reason,created_at,received_at)
      SELECT p.shop_id,?,p.id,${e.kind === "set" ? `?-(${STOCK})` : "?"},?,?,?,? FROM cloud_products p WHERE p.shop_id=? AND p.id=?`)
      .bind(e.id, e.quantity, e.kind, e.reason, e.created_at, now, shop, e.product_id));
    for (const id of new Set(fresh.map(e => e.product_id))) writes.push(env.DB.prepare(`UPDATE cloud_products SET seq=${SEQ} WHERE shop_id=? AND id=?
      AND EXISTS(SELECT 1 FROM cloud_stock_events WHERE shop_id=? AND product_id=? AND received_at=? AND id IN (SELECT value FROM json_each(?)))`)
      .bind(shop, shop, shop, id, shop, id, now, freshIds));
    const results = await env.DB.batch([...writes, ...reads()]);
    stored = results.at(-2).results; rows = results.at(-1).results;
  }
  const storedProduct = new Map(stored.map(r => [r.id, r.product_id])), productMap = new Map(rows.map(r => [r.id, r]));
  const accepted = [], rejected = [];
  for (const e of events) {
    if (storedProduct.get(e.id) === e.product_id) { accepted.push(e.id); continue; }
    const p = productMap.get(e.product_id);
    rejected.push({ id: e.id, reason: storedProduct.has(e.id) ? "id_conflict" : !p ? "product_not_found" : "conflict" });
  }
  return json({ schema_version: 1, accepted, rejected, products: rows.map(productOut) });
}
function cash(value, nullable) {
  if (value == null && nullable) return [null, null];
  requireValue(value && typeof value === "object" && !Array.isArray(value), "invalid denominations");
  const counts = {}; let total = 0;
  for (const key of Object.keys(value)) requireValue(DENOMINATIONS.includes(key) && integer(value[key], 0, 9999), "invalid denominations");
  for (const key of DENOMINATIONS) { counts[key] = value[key] ?? 0; total += Number(key) * counts[key]; }
  return [counts, total];
}
// Drawer sessions upsert by id; a closed session is immutable (identical replays still succeed).
async function sessions(request, env) {
  const parsed = await parse(request, body => unique(list(body, "sessions", 20).map(s => {
    requireValue(s && typeof s === "object" && text(s.id, 128) && text(s.device_id, 64) && text(s.device_label, 64), "invalid session");
    requireValue(date(s.opened_at) && (s.closed_at == null || (date(s.closed_at) && Date.parse(s.closed_at) >= Date.parse(s.opened_at))), "invalid session time");
    const [float, floatTotal] = cash(s.float, false), [counted, countedTotal] = cash(s.counted, true);
    requireValue(s.float_total === floatTotal && (s.counted_total ?? null) === countedTotal, "invalid totals");
    const optional = value => value == null || money(value);
    requireValue((s.expected_total == null || integer(s.expected_total, -1_000_000_000, 1_000_000_000)) && optional(s.sales_total) && optional(s.cancel_total) && (s.order_count == null || integer(s.order_count, 0, 1_000_000)), "invalid totals");
    return { id: s.id, device_id: s.device_id, device_label: s.device_label, opened_at: s.opened_at, closed_at: s.closed_at ?? null,
      float, float_total: floatTotal, counted, counted_total: countedTotal, expected_total: s.expected_total ?? null,
      sales_total: s.sales_total ?? null, cancel_total: s.cancel_total ?? null, order_count: s.order_count ?? null };
  }), "duplicate session"));
  if (parsed.response) return parsed.response;
  const items = parsed.value.map(s => ({ ...s, payload: JSON.stringify(s) })), shop = env.SHOP_ID;
  const select = () => env.DB.prepare("SELECT id,closed_at,payload FROM cloud_sessions WHERE shop_id=? AND id IN (SELECT value FROM json_each(?))")
    .bind(shop, JSON.stringify(items.map(s => s.id)));
  const current = new Map((await select().all()).results.map(row => [row.id, row]));
  const writes = [], now = new Date().toISOString();
  for (const s of items) {
    const row = current.get(s.id);
    if (row && (row.payload === s.payload || row.closed_at != null)) continue;
    writes.push(env.DB.prepare(`INSERT INTO cloud_sessions(shop_id,id,device_id,device_label,opened_at,closed_at,payload,received_at) VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(shop_id,id) DO UPDATE SET device_id=excluded.device_id,device_label=excluded.device_label,opened_at=excluded.opened_at,
      closed_at=excluded.closed_at,payload=excluded.payload,received_at=excluded.received_at WHERE cloud_sessions.closed_at IS NULL`)
      .bind(shop, s.id, s.device_id, s.device_label, s.opened_at, s.closed_at, s.payload, now));
  }
  const rows = writes.length ? (await env.DB.batch([...writes, select()])).at(-1).results : [...current.values()];
  const stored = new Map(rows.map(row => [row.id, row.payload]));
  const accepted = [], rejected = [];
  for (const s of items) {
    if (stored.get(s.id) === s.payload) accepted.push(s.id); else rejected.push({ id: s.id, reason: "closed" });
  }
  return json({ schema_version: 1, accepted, rejected });
}
// Change feed for other devices' orders, products and stock. Read-only and bounded in D1 and HTTP.
async function feed(request, env) {
  const raw = new URL(request.url).searchParams.get("after") ?? "0";
  if (!/^(0|[1-9]\d{0,14})$/.test(raw)) return json({ error: "invalid after" }, 400);
  const after = Number(raw), shop = env.SHOP_ID;
  const [orderRows, productRows] = (await env.DB.batch([
    env.DB.prepare(`SELECT seq,payload,n FROM (
      SELECT seq,payload,SUM(length(CAST(payload AS BLOB))) OVER (ORDER BY seq) AS bytes,ROW_NUMBER() OVER (ORDER BY seq) AS position,COUNT(*) OVER () AS n
      FROM (SELECT seq,payload FROM cloud_orders WHERE shop_id=? AND seq>? ORDER BY seq LIMIT 100)
    ) WHERE bytes<=? OR position=1 ORDER BY seq`).bind(shop, after, FEED_BYTES),
    env.DB.prepare(`${PRODUCT} WHERE p.shop_id=? AND p.seq>? ORDER BY p.seq LIMIT 1000`).bind(shop, after)
  ])).map(r => r.results);
  // A truncated source list caps the merge at its last seq; otherwise later rows of the other list would skip it.
  let limit = Infinity;
  if (orderRows.length && (orderRows[0].n >= 100 || orderRows[0].n > orderRows.length)) limit = orderRows.at(-1).seq;
  if (productRows.length >= 1000) limit = Math.min(limit, productRows.at(-1).seq);
  const items = [...orderRows.map(r => ({ seq: r.seq, order: { ...JSON.parse(r.payload), seq: r.seq } })),
    ...productRows.map(r => ({ seq: r.seq, product: productOut(r) }))].filter(x => x.seq <= limit).sort((a, b) => a.seq - b.seq);
  const orders = [], products = [], encoder = new TextEncoder();
  let hasMore = limit !== Infinity, bytes = 0, next = after;
  for (const item of items) {
    const size = encoder.encode(JSON.stringify(item.order ?? item.product)).byteLength;
    if (orders.length + products.length > 0 && bytes + size > FEED_BYTES) { hasMore = true; break; }
    bytes += size; next = item.seq;
    if (item.order) orders.push(item.order); else products.push(item.product);
  }
  return json({ schema_version: 1, after, next, has_more: hasMore, products, orders });
}
// JST calendar day -> half-open UTC bounds without the zone suffix, so ".123Z" timestamps compare correctly.
function jstDay(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const start = Date.parse(value + "T00:00:00+09:00");
  if (!Number.isFinite(start) || new Date(start + 9 * 3600_000).toISOString().slice(0, 10) !== value) return null;
  return [new Date(start).toISOString().slice(0, 19), new Date(start + 86400_000).toISOString().slice(0, 19)];
}
async function dashboard(request, env) {
  const value = new URL(request.url).searchParams.get("date");
  const range = value == null ? null : jstDay(value);
  if (value != null && !range) return json({ error: "invalid date" }, 400);
  const shop = env.SHOP_ID, where = range ? " AND o.created_at>=? AND o.created_at<?" : "", args = range ? [shop, ...range] : [shop];
  const q = (sql, ...values) => env.DB.prepare(sql).bind(...values);
  const [totals, hours, byProduct, segments, groups, relations, stockRows, devices, sessionRows, recent] = (await env.DB.batch([
    q(`SELECT COALESCE(SUM(CASE WHEN o.cancelled=0 THEN o.total_yen END),0) AS net_sales,COALESCE(SUM(o.cancelled=0),0) AS orders,
      COALESCE(SUM(o.cancelled=1),0) AS cancelled_orders,COALESCE(SUM(CASE WHEN o.cancelled=1 THEN o.total_yen END),0) AS cancelled_amount
      FROM cloud_orders o WHERE o.shop_id=?${where}`, ...args),
    q(`SELECT CAST(strftime('%H',o.created_at,'+9 hours') AS INTEGER) AS hour,SUM(o.total_yen) AS sales,COUNT(*) AS orders
      FROM cloud_orders o WHERE o.shop_id=? AND o.cancelled=0${where} GROUP BY hour`, ...args),
    q(`SELECT g.id,g.quantity,g.sales,(SELECT p.image_hash FROM cloud_products p WHERE p.shop_id=? AND p.id=g.id) AS image_hash,COALESCE((SELECT substr(p.name,1,100) FROM cloud_products p WHERE p.shop_id=? AND p.id=g.id),
        (SELECT substr(json_extract(j.value,'$.name'),1,100) FROM cloud_orders s, json_each(s.payload,'$.lines') j
          WHERE s.shop_id=? AND s.id=g.sample AND json_extract(j.value,'$.product_id')=g.id),g.id) AS name
      FROM (SELECT l.product_id AS id,SUM(l.quantity) AS quantity,SUM(l.quantity*l.price) AS sales,MIN(l.order_id) AS sample
        FROM cloud_order_lines l JOIN cloud_orders o ON o.shop_id=l.shop_id AND o.id=l.order_id
        WHERE l.shop_id=? AND l.cancelled=0${where} GROUP BY l.product_id) g ORDER BY g.sales DESC,g.id LIMIT 500`, shop, shop, shop, ...args),
    q(`SELECT o.customer_age AS age,o.customer_gender AS gender,COUNT(*) AS orders,SUM(o.total_yen) AS sales
      FROM cloud_orders o WHERE o.shop_id=? AND o.cancelled=0${where} GROUP BY o.customer_age,o.customer_gender`, ...args),
    q(`SELECT o.customer_group AS grp,COUNT(*) AS orders,SUM(o.total_yen) AS sales
      FROM cloud_orders o WHERE o.shop_id=? AND o.cancelled=0${where} GROUP BY o.customer_group`, ...args),
    q(`SELECT o.customer_relation AS rel,COUNT(*) AS orders,SUM(o.total_yen) AS sales
      FROM cloud_orders o WHERE o.shop_id=? AND o.cancelled=0${where} GROUP BY o.customer_relation`, ...args),
    q(`SELECT p.id,substr(p.name,1,100) AS name,p.active,p.stop_at_zero,p.image_hash,${STOCK} AS stock,(SELECT COALESCE(SUM(l.quantity),0) FROM cloud_order_lines l
        JOIN cloud_orders o ON o.shop_id=l.shop_id AND o.id=l.order_id WHERE l.shop_id=p.shop_id AND l.product_id=p.id AND l.cancelled=0${where}) AS sold
      FROM cloud_products p WHERE p.shop_id=? ORDER BY stock,p.id LIMIT 500`, ...(range ?? []), shop),
    q(`SELECT o.device_id,(SELECT s.device_label FROM cloud_sessions s WHERE s.shop_id=o.shop_id AND s.device_id=o.device_id ORDER BY s.opened_at DESC LIMIT 1) AS device_label,
      COALESCE(SUM(o.cancelled=0),0) AS orders,COALESCE(SUM(CASE WHEN o.cancelled=0 THEN o.total_yen END),0) AS sales,MAX(o.received_at) AS last_received_at
      FROM cloud_orders o WHERE o.shop_id=?${where} GROUP BY o.device_id ORDER BY sales DESC LIMIT 100`, ...args),
    q(`SELECT id,device_label,payload FROM cloud_sessions WHERE shop_id=?${range ? " AND opened_at>=? AND opened_at<?" : ""}
      ORDER BY opened_at DESC LIMIT 100`, ...args),
    q(`SELECT o.id,o.ticket_no,o.created_at,o.total_yen AS total,o.cancelled,o.device_id FROM cloud_orders o WHERE o.shop_id=?${where}
      ORDER BY o.created_at DESC,o.id DESC LIMIT 20`, ...args)
  ])).map(r => r.results);
  const t = totals[0], hourMap = new Map(hours.map(h => [h.hour, h]));
  return json({ schema_version: 1, date: value,
    totals: { ...t, average: t.orders ? Math.round(t.net_sales / t.orders) : 0 },
    by_hour: Array.from({ length: 24 }, (_, hour) => ({ hour, sales: hourMap.get(hour)?.sales ?? 0, orders: hourMap.get(hour)?.orders ?? 0 })),
    by_product: byProduct.map(r => ({ id: r.id, name: r.name, image_hash: r.image_hash ?? null, quantity: r.quantity, sales: r.sales })),
    segments: segments.map(r => ({ age: AGES.includes(r.age) ? r.age : null, gender: GENDERS.includes(r.gender) ? r.gender : null, orders: r.orders, sales: r.sales })),
    groups: groups.map(r => ({ group: GROUPS.includes(r.grp) ? r.grp : null, orders: r.orders, sales: r.sales }))
      .sort((a, b) => (a.group ? GROUPS.indexOf(a.group) : 99) - (b.group ? GROUPS.indexOf(b.group) : 99)),
    relations: relations.map(r => ({ relation: RELATIONS.includes(r.rel) ? r.rel : null, orders: r.orders, sales: r.sales }))
      .sort((a, b) => (a.relation ? RELATIONS.indexOf(a.relation) : 99) - (b.relation ? RELATIONS.indexOf(b.relation) : 99)),
    stock: stockRows.map(r => ({ id: r.id, name: r.name, active: r.active === 1, stop_at_zero: r.stop_at_zero === 1, image_hash: r.image_hash ?? null, stock: r.stock, sold: r.sold })),
    devices, recent: recent.map(r => ({ ...r, cancelled: r.cancelled === 1 })), sessions: sessionRows.map(row => {
      const s = JSON.parse(row.payload);
      return { id: row.id, device_label: row.device_label, opened_at: s.opened_at, closed_at: s.closed_at, float_total: s.float_total,
        expected_total: s.expected_total, counted_total: s.counted_total,
        difference: s.counted_total != null && s.expected_total != null ? s.counted_total - s.expected_total : null,
        sales_total: s.sales_total, cancel_total: s.cancel_total, order_count: s.order_count };
    }) });
}
// Product photos: content-addressed JPEG blobs. Identical uploads are read-only.
async function uploadImage(request, env) {
  let bytes;
  try { bytes = await readBytes(request, IMAGE_BYTES); }
  catch (error) { return json({ error: error.message }, error.message === "too large" ? 413 : 400); }
  if (bytes.byteLength < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) return json({ error: "not a JPEG" }, 400);
  const hash = await digest(bytes), shop = env.SHOP_ID;
  const existing = await env.DB.prepare("SELECT 1 AS found FROM cloud_images WHERE shop_id=? AND hash=?").bind(shop, hash).all();
  if (!existing.results.length) {
    // BLOBs bind as Uint8Array (accepted by D1 and node:sqlite alike).
    await env.DB.batch([env.DB.prepare("INSERT OR IGNORE INTO cloud_images(shop_id,hash,content_type,bytes,size,created_at) VALUES(?,?,?,?,?,?)")
      .bind(shop, hash, "image/jpeg", bytes, bytes.byteLength, new Date().toISOString())]);
  }
  return json({ schema_version: 1, hash, size: bytes.byteLength });
}
async function getImage(request, env, hash) {
  const headers = { "Cache-Control": "private, max-age=31536000, immutable", ETag: `"${hash}"`, "X-Content-Type-Options": "nosniff" };
  const match = request.headers.get("If-None-Match");
  if (match && match.split(",").some(tag => tag.trim().replace(/^W\//, "") === `"${hash}"`)) {
    const found = await env.DB.prepare("SELECT 1 AS found FROM cloud_images WHERE shop_id=? AND hash=?").bind(env.SHOP_ID, hash).all();
    if (found.results.length) return new Response(null, { status: 304, headers });
  }
  const rows = (await env.DB.prepare("SELECT content_type,bytes FROM cloud_images WHERE shop_id=? AND hash=?").bind(env.SHOP_ID, hash).all()).results;
  if (!rows.length) return json({ error: "not found" }, 404);
  // D1 returns BLOBs as number arrays; node:sqlite as Uint8Array.
  return new Response(new Uint8Array(rows[0].bytes), { headers: { ...headers, "Content-Type": rows[0].content_type } });
}
async function authorized(request, expected) {
  const auth = request.headers.get("Authorization") ?? "";
  return auth.startsWith("Bearer ") && auth.length <= 1024 && await digest(auth.slice(7)) === expected;
}
const DEVICE_ROUTES = new Map([["POST /v1/sync", sync], ["GET /v1/catalogs", catalogs], ["POST /v1/catalogs", catalogs],
  ["GET /v1/restore", restore], ["POST /v1/products", products], ["POST /v1/stock", stock], ["POST /v1/sessions", sessions], ["GET /v1/feed", feed], ["POST /v1/images", uploadImage]]);
const PAGE_HEADERS = { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data: blob:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" };
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname, key = request.method + " " + path;
    if (key === "GET /dashboard") return new Response(DASHBOARD_HTML, { headers: PAGE_HEADERS });
    if (key === "GET /privacy") return new Response(PRIVACY_HTML, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=3600" } });
    const image = request.method === "GET" && /^\/v1\/images\/([a-f0-9]{64})$/.exec(path)?.[1];
    const route = DEVICE_ROUTES.get(key);
    if (!route && !image && key !== "GET /v1/dashboard") return json({ error: "not found" }, 404);
    const publicDashboard = env.DASHBOARD_PUBLIC === "true";
    try {
      if (image) {
        // Read-only: either the device token or the dashboard token may fetch a photo, or anyone when the dashboard is public.
        if (!env.SHOP_ID || !(env.DEVICE_TOKEN_SHA256 || env.DASHBOARD_TOKEN_SHA256 || publicDashboard)) return json({ error: "not configured" }, 503);
        const ok = publicDashboard || (env.DEVICE_TOKEN_SHA256 && await authorized(request, env.DEVICE_TOKEN_SHA256)) ||
          (env.DASHBOARD_TOKEN_SHA256 && await authorized(request, env.DASHBOARD_TOKEN_SHA256));
        if (!ok) return json({ error: "unauthorized" }, 401);
        return await getImage(request, env, image);
      }
      if (!route) {
        // DASHBOARD_PUBLIC="true" opens the read-only aggregate to anyone with the URL.
        if (publicDashboard && env.SHOP_ID) return await dashboard(request, env);
        // Separate secret: device tokens cannot read the dashboard, the dashboard token cannot write.
        if (!env.DASHBOARD_TOKEN_SHA256 || !env.SHOP_ID || env.DASHBOARD_TOKEN_SHA256 === env.DEVICE_TOKEN_SHA256) return json({ error: "not configured" }, 503);
        if (!await authorized(request, env.DASHBOARD_TOKEN_SHA256)) return json({ error: "unauthorized" }, 401);
        return await dashboard(request, env);
      }
      if (!env.DEVICE_TOKEN_SHA256 || !env.SHOP_ID) return json({ error: "not configured" }, 503);
      if (!await authorized(request, env.DEVICE_TOKEN_SHA256)) return json({ error: "unauthorized" }, 401);
      const type = (request.headers.get("Content-Type") ?? "").split(";")[0].trim().toLowerCase();
      if (key === "POST /v1/images" && type !== "image/jpeg") return json({ error: "image/jpeg required" }, 415);
      if (request.method === "POST" && key !== "POST /v1/images" && !request.headers.get("Content-Type")?.startsWith("application/json")) return json({ error: "JSON required" }, 415);
      return await route(request, env);
    } catch { return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "60" }); }
  }
};
