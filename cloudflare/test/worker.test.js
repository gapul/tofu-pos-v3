import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import worker from "../src/worker.js";
import { digest, normalize, MAX_BYTES } from "../src/lib.js";

const migrations = readdirSync(new URL("../migrations/", import.meta.url)).filter(f => f.endsWith(".sql")).sort();

class LocalD1 {
  db = new DatabaseSync(":memory:"); reads = 0; writes = 0; beforeBatch;
  constructor(until = Infinity) { this.migrate(until); }
  applied = 0;
  migrate(until = Infinity) {
    for (; this.applied < Math.min(until, migrations.length); this.applied++) this.db.exec(readFileSync(new URL("../migrations/" + migrations[this.applied], import.meta.url), "utf8"));
  }
  prepare(sql) {
    const owner = this;
    return { bind(...values) { return {
      sql, values,
      async all() { owner.reads++; return { results: owner.db.prepare(sql).all(...values) }; }
    }; } };
  }
  async batch(statements) {
    this.beforeBatch?.(); this.beforeBatch = undefined;
    this.db.exec("BEGIN");
    try {
      const results = statements.map(statement => {
        if (/^SELECT/i.test(statement.sql)) { this.reads++; return { results: this.db.prepare(statement.sql).all(...statement.values) }; }
        const result = this.db.prepare(statement.sql).run(...statement.values);
        this.writes += Number(result.changes); return { results: [] };
      });
      this.db.exec("COMMIT"); return results;
    } catch (error) { this.db.exec("ROLLBACK"); throw error; }
  }
}
const token = "test-only-token-not-for-deployment-0123456789";
async function environment() { return { DB: new LocalD1(), SHOP_ID: "test-shop", DEVICE_TOKEN_SHA256: await digest(token) }; }
function order(id = "order-1", revision = 1) {
  return { id, revision, created_at: "2026-11-20T01:00:00Z", total: 1000, received: 2000, change_yen: 1000,
    cancelled_at: revision === 2 ? "2026-11-20T01:01:00Z" : null, cancellation_reason: revision === 2 ? "返金済み" : null,
    lines: [{ product_id: "tofu", name: "豆腐", price: 500, quantity: 2 }] };
}
async function send(env, orders, authorization = token) {
  return worker.fetch(new Request("https://test.example/v1/sync", { method: "POST", headers: { Authorization: "Bearer " + authorization, "Content-Type": "application/json" }, body: JSON.stringify({ schema_version: 1, orders }) }), env);
}
test("lost responses and 100 duplicate retries cause no extra D1 writes", async () => {
  const env = await environment();
  assert.equal((await send(env, [order()])).status, 200);
  const written = env.DB.writes;
  for (let i = 0; i < 100; i++) {
    const response = await send(env, [order()]);
    assert.deepEqual((await response.json()).accepted, [{ id: "order-1", revision: 1 }]);
  }
  assert.equal(env.DB.writes, written);
  assert.equal(env.DB.reads, 102); // initial select+verification, then one indexed select per retry.
  assert.equal(env.DB.db.prepare("SELECT COUNT(*) AS n FROM cloud_orders").get().n, 1);
});
test("cancellation wins; stale sales cannot resurrect revenue", async () => {
  const env = await environment(); await send(env, [order()]); await send(env, [order("order-1", 2)]);
  const written = env.DB.writes;
  const result = await (await send(env, [order()])).json();
  assert.equal(result.accepted.length, 0); assert.equal(result.conflicts.length, 1);
  assert.equal(env.DB.writes, written);
  assert.equal(env.DB.db.prepare("SELECT cancelled FROM cloud_orders").get().cancelled, 1);
  assert.equal(env.DB.db.prepare("SELECT SUM(CASE WHEN cancelled=0 THEN total_yen ELSE 0 END) AS revenue FROM cloud_orders").get().revenue, 0);
});
test("first upload can already be cancelled", async () => {
  const env = await environment();
  assert.deepEqual((await (await send(env, [order("cancelled", 2)])).json()).accepted, [{ id: "cancelled", revision: 2 }]);
});
test("same revision with changed content and altered cancellation totals are conflicts", async () => {
  const env = await environment(); await send(env, [order()]); const written = env.DB.writes;
  for (const revision of [1, 2]) {
    const changed = order("order-1", revision); changed.total = 1200; changed.change_yen = 800; changed.lines[0].price = 600;
    const result = await (await send(env, [changed])).json(); assert.equal(result.conflicts.length, 1);
  }
  assert.equal(env.DB.writes, written);
});
test("batch of 50 uses two reads, duplicate batch only one; shops are isolated", async () => {
  const env = await environment(); const orders = Array.from({ length: 50 }, (_, i) => order("o" + i));
  assert.equal((await (await send(env, orders)).json()).accepted.length, 50);
  // 50 order rows + 50 derived line rows (0.4.0); the replay stays read-only.
  assert.equal(env.DB.reads, 2); assert.equal(env.DB.writes, 100);
  await send(env, orders); assert.equal(env.DB.reads, 3); assert.equal(env.DB.writes, 100);
  await send({ ...env, SHOP_ID: "different-shop" }, [order("o0")]);
  assert.equal(env.DB.db.prepare("SELECT COUNT(*) AS n FROM cloud_orders WHERE id='o0'").get().n, 2);
});
test("invalid auth, totals, size, duplicates and oversized batch touch no database", async () => {
  const env = await environment(); assert.equal((await send(env, [order()], "wrong")).status, 401);
  const invalid = order(); invalid.total = 5;
  assert.equal((await send(env, [invalid])).status, 400);
  assert.equal((await send(env, [order(), order()])).status, 400);
  assert.equal((await send(env, Array.from({ length: 51 }, (_, i) => order("o" + i)))).status, 400);
  const huge = new Request("https://test.example/v1/sync", { method: "POST", headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" }, body: " ".repeat(MAX_BYTES + 1) });
  assert.equal((await worker.fetch(huge, env)).status, 413);
  assert.equal(env.DB.reads, 0); assert.equal(env.DB.writes, 0);
});
test("database failure returns Retry-After once, without server-side retry", async () => {
  const env = await environment(); let attempts = 0;
  env.DB.prepare = () => ({ bind: () => ({ all: async () => { attempts++; throw new Error("database unavailable"); } }) });
  const response = await send(env, [order()]); assert.equal(response.status, 503);
  assert.equal(response.headers.get("Retry-After"), "60"); assert.equal(attempts, 1);
});
test("concurrent conflicting insert cannot be overwritten by a cancellation", async () => {
  const env = await environment();
  const changed = order(); changed.total = 1200; changed.change_yen = 800; changed.lines[0].price = 600;
  const otherEnv = await environment(); await send(otherEnv, [changed]);
  const competing = otherEnv.DB.db.prepare("SELECT * FROM cloud_orders").get();
  env.DB.beforeBatch = () => env.DB.db.prepare(`INSERT INTO cloud_orders VALUES(${Object.keys(competing).map(() => "?").join(",")})`).run(...Object.values(competing));
  const result = await (await send(env, [order("order-1", 2)])).json();
  assert.equal(result.conflicts.length, 1);
  assert.equal(env.DB.db.prepare("SELECT total_yen,cancelled FROM cloud_orders").get().total_yen, 1200);
  assert.equal(env.DB.db.prepare("SELECT cancelled FROM cloud_orders").get().cancelled, 0);
});
test("valid local Unicode names and orders with over 1000 lines remain syncable", async () => {
  const env = await environment(); const unicode = order("unicode"); unicode.lines[0].name = "👨‍👩‍👧‍👦".repeat(100);
  assert.equal((await (await send(env, [unicode])).json()).accepted.length, 1);
  const many = order("many-lines"); many.total = 0; many.received = 0; many.change_yen = 0;
  many.lines = Array.from({ length: 1001 }, (_, i) => ({ product_id: "p" + i, name: "無料", price: 0, quantity: 1 }));
  assert.equal((await (await send(env, [many])).json()).accepted.length, 1);
});

async function backupCall(env, path, body, authorization = token) {
  return worker.fetch(new Request("https://test.example"+path, { method: body ? "POST" : "GET", headers: { Authorization: "Bearer "+authorization, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined }),env);
}
test("product snapshots retain all versions; identical and reordered retries write nothing", async () => {
  const env = await environment();
  const products = [{id:"b",name:"田楽",price:500},{id:"a",name:"豆腐",price:0}];
  const first = await (await backupCall(env,"/v1/catalogs",{schema_version:1,products})).json();
  const writes = env.DB.writes;
  const again = await (await backupCall(env,"/v1/catalogs",{schema_version:1,products:[...products].reverse()})).json();
  assert.equal(first.id,again.id); assert.equal(env.DB.writes,writes);
  await backupCall(env,"/v1/catalogs",{schema_version:1,products:[]});
  assert.equal(env.DB.db.prepare("SELECT COUNT(*) AS n FROM cloud_catalogs").get().n,2);
  const restored = await (await backupCall(env,"/v1/restore?catalog_id="+first.id)).json();
  assert.equal(restored.products.length,2); assert.equal(restored.products[0].id,"a");
  assert.equal(restored.next,null);
});
test("restore keyset pages return all orders and latest cancellation without any writes",async()=>{
  const env=await environment();
  const all=Array.from({length:61},(_,i)=>order("order-"+String(i).padStart(3,"0")));
  await send(env,all.slice(0,50));await send(env,all.slice(50));await send(env,[order("order-000",2)]);
  const writes=env.DB.writes;let after="",seen=[];
  for(let i=0;i<4;i++) {
    const result=await (await backupCall(env,"/v1/restore?after="+encodeURIComponent(after))).json();
    assert.equal(result.after,after);seen.push(...result.orders);
    if(result.next==null) break;after=result.next;
  }
  assert.equal(seen.length,61);assert.equal(new Set(seen.map(x=>x.id)).size,61);
  assert.equal(seen[0].revision,2);assert.equal(env.DB.writes,writes);
});
test("restore SQL bounds bytes before returning large payloads and advances cursor",async()=>{
  const env=await environment();
  for(let i=0;i<3;i++) { const huge=order("big-"+i);huge.lines[0].name="豆".repeat(50000);assert.equal((await send(env,[huge])).status,200); }
  const result=await (await backupCall(env,"/v1/restore")).json();
  assert.equal(result.orders.length,1);assert.equal(result.next,"big-0");
  const next=await (await backupCall(env,"/v1/restore?after="+result.next)).json();assert.equal(next.orders[0].id,"big-1");
});
test("backup read endpoints authenticate before database access and isolate shops",async()=>{
  const env=await environment();
  for(const path of ["/v1/catalogs","/v1/restore"])assert.equal((await backupCall(env,path,null,"bad")).status,401);
  assert.equal(env.DB.reads,0);assert.equal(env.DB.writes,0);
  const saved=await (await backupCall(env,"/v1/catalogs",{schema_version:1,products:[{id:"p",name:"豆腐",price:500}]})).json();
  await send(env,[order()]);const other={...env,SHOP_ID:"other"};
  assert.equal((await (await backupCall(other,"/v1/catalogs")).json()).catalogs.length,0);
  assert.equal((await (await backupCall(other,"/v1/restore")).json()).orders.length,0);
  assert.equal((await backupCall(other,"/v1/restore?catalog_id="+saved.id)).status,404);
});
test("malformed/oversized product backups and cursors are rejected without writes",async()=>{
  const env=await environment();
  for(const products of [[{id:"p",name:"豆腐",price:-1}],[{id:"p",name:"",price:1}],[{id:"p",name:"p",price:1},{id:"p",name:"p",price:1}],Array.from({length:1001},(_,i)=>({id:String(i),name:"p",price:1}))]) {
    assert.equal((await backupCall(env,"/v1/catalogs",{schema_version:1,products})).status,400);
  }
  assert.equal((await backupCall(env,"/v1/restore?catalog_id=bad")).status,400);
  assert.equal((await backupCall(env,"/v1/restore?after="+"a".repeat(129))).status,400);
  assert.equal(env.DB.writes,0);
});
test("catalog pagination keeps an old identical re-backup reachable beyond twenty versions",async()=>{
  const env=await environment();let first;
  for(let price=0;price<24;price++) {
    const r=await (await backupCall(env,"/v1/catalogs",{schema_version:1,products:[{id:"p",name:"豆腐",price}]})).json();
    if(price===0)first=r.id;
  }
  const writes=env.DB.writes;
  await backupCall(env,"/v1/catalogs",{schema_version:1,products:[{id:"p",name:"豆腐",price:0}]});
  assert.equal(env.DB.writes,writes);
  let before=null,ids=[];
  do { const page=await (await backupCall(env,"/v1/catalogs"+(before?"?before="+encodeURIComponent(before):""))).json();ids.push(...page.catalogs.map(c=>c.id));before=page.next; } while(before);
  assert.equal(new Set(ids).size,24);assert.ok(ids.includes(first));
});

// 0.4.0
const dashboardToken = "dashboard-only-token-not-for-deployment-9876543210";
async function v4env() { return { ...(await environment()), DASHBOARD_TOKEN_SHA256: await digest(dashboardToken) }; }
const uuid = i => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`;
const product = (id, extra = {}) => ({ id, name: "豆腐", price: 500, active: true, track_stock: true, base_version: 0, ...extra });
const stockEvent = (i, product_id, kind, quantity) => ({ id: uuid(i), product_id, kind, quantity, created_at: "2026-11-20T00:00:00Z" });
const productsCall = (env, products, auth) => backupCall(env, "/v1/products", { schema_version: 1, products }, auth);
const stockCall = (env, events, auth) => backupCall(env, "/v1/stock", { schema_version: 1, events }, auth);
const sessionsCall = (env, sessions, auth) => backupCall(env, "/v1/sessions", { schema_version: 1, sessions }, auth);
const stockOf = async (env, id) => (await (await backupCall(env, "/v1/feed")).json()).products.find(p => p.id === id).stock;
function v4order(id, extra = {}) { return { ...order(id), device_id: "device-a", customer_age: "student", customer_gender: "female", ...extra }; }

test("0.3.0 rows survive migration 0003 and their replays and cancellations are not conflicts", async () => {
  const DB = new LocalD1(2), env = { ...(await environment()), DB };
  // Exactly the 0.3.0 normalized shape (no optional keys).
  const legacy = o => ({ id: o.id, revision: o.revision, created_at: o.created_at, total: o.total, received: o.received, change_yen: o.change_yen,
    cancelled_at: o.cancelled_at, cancellation_reason: o.cancellation_reason, lines: o.lines });
  for (const id of ["b-old", "a-old"]) {
    const payload = JSON.stringify(legacy(order(id))), base = payload;
    DB.db.prepare("INSERT INTO cloud_orders VALUES(?,?,?,?,?,?,?,?,?)").run("test-shop", id, 1, await digest(base), await digest(payload), payload, 1000, 0, "2026-11-20T01:00:01Z");
  }
  DB.migrate();
  assert.deepEqual(DB.db.prepare("SELECT id,seq,created_at,device_id FROM cloud_orders ORDER BY id").all().map(r => ({ ...r })),
    [{ id: "a-old", seq: 1, created_at: "2026-11-20T01:00:00Z", device_id: null }, { id: "b-old", seq: 2, created_at: "2026-11-20T01:00:00Z", device_id: null }]);
  assert.equal(DB.db.prepare("SELECT SUM(quantity) AS n FROM cloud_order_lines WHERE cancelled=0").get().n, 4);
  const writes = DB.writes;
  assert.deepEqual((await (await send(env, [order("a-old"), order("b-old")])).json()).accepted.length, 2);
  assert.equal(DB.writes, writes);
  // Adding the optional fields changes base content: same revision with different content is a conflict.
  assert.equal((await (await send(env, [v4order("a-old")])).json()).conflicts.length, 1);
  assert.equal((await (await send(env, [order("a-old", 2)])).json()).accepted.length, 1);
  assert.deepEqual({ ...DB.db.prepare("SELECT seq,cancelled FROM cloud_orders WHERE id='a-old'").get() }, { seq: 3, cancelled: 1 });
  assert.equal(DB.db.prepare("SELECT cancelled FROM cloud_order_lines WHERE order_id='a-old'").get().cancelled, 1);
});
test("optional order fields are validated, stored, and omitted from payloads when null", async () => {
  const env = await v4env();
  for (const extra of [{ customer_age: "baby" }, { customer_gender: "x" }, { device_id: "" }, { device_id: "d".repeat(65) }, { customer_age: 1 }]) {
    assert.equal((await send(env, [v4order("bad", extra)])).status, 400);
  }
  assert.equal(env.DB.writes, 0);
  assert.equal((await (await send(env, [v4order("new"), { ...order("old"), device_id: null, customer_age: null }])).json()).accepted.length, 2);
  const rows = env.DB.db.prepare("SELECT id,payload,device_id,customer_age,customer_gender,created_at FROM cloud_orders ORDER BY id").all();
  assert.deepEqual([rows[0].device_id, rows[0].customer_age, rows[0].customer_gender, rows[0].created_at], ["device-a", "student", "female", "2026-11-20T01:00:00Z"]);
  assert.ok(JSON.parse(rows[0].payload).customer_gender === "female");
  assert.ok(!("device_id" in JSON.parse(rows[1].payload)) && !("customer_age" in JSON.parse(rows[1].payload)));
  // Optional fields are part of the content: same revision, different age is a conflict.
  assert.equal((await (await send(env, [v4order("new", { customer_age: "adult" })])).json()).conflicts.length, 1);
});
test("derived stock follows sales, cancellations, add and set; concurrent replays never double count", async () => {
  const env = await v4env();
  await productsCall(env, [product("tofu"), product("free", { track_stock: false })]);
  assert.deepEqual((await (await stockCall(env, [stockEvent(1, "tofu", "add", 10)])).json()).products.map(p => p.stock), [10]);
  // Two identical requests interleave: both read "absent" before either batch commits.
  const results = await Promise.all([send(env, [order()]), send(env, [order()])].map(async r => (await r).json()));
  assert.deepEqual(results.map(r => r.accepted.length), [1, 1]);
  assert.equal(env.DB.db.prepare("SELECT COUNT(*) AS n FROM cloud_order_lines").get().n, 1);
  assert.equal(await stockOf(env, "tofu"), 8);
  await send(env, [order("order-1", 2)]); assert.equal(await stockOf(env, "tofu"), 10);
  await Promise.all([send(env, [order("order-1", 2)]), send(env, [order("order-1", 2)])]); assert.equal(await stockOf(env, "tofu"), 10);
  const set = await (await stockCall(env, [stockEvent(2, "tofu", "set", 5), stockEvent(3, "tofu", "add", 1)])).json();
  assert.deepEqual(set.accepted, [uuid(2), uuid(3)]); assert.equal(set.products[0].stock, 6);
  assert.equal(env.DB.db.prepare("SELECT delta FROM cloud_stock_events WHERE id=?").get(uuid(2)).delta, -5);
  await send(env, [order("order-2")]); assert.equal(await stockOf(env, "tofu"), 4);
  const feed = await (await backupCall(env, "/v1/feed")).json();
  assert.equal(feed.products.find(p => p.id === "free").stock, 0); // every product tracks stock (revision 2)
  assert.ok(feed.products.find(p => p.id === "tofu").seq > feed.orders.find(o => o.id === "order-2").seq, "stock change bumps product seq");
});
test("products: create, update, stale conflict, idempotent retry, validation", async () => {
  const env = await v4env();
  let r = await (await productsCall(env, [product("p1", { name: "  豆腐  " })])).json();
  assert.deepEqual(r.results[0], { id: "p1", status: "applied", product: { id: "p1", name: "豆腐", price: 500, active: true, track_stock: true, stop_at_zero: false, image_hash: null, version: 1, stock: 0, seq: 1 } });
  let writes = env.DB.writes;
  r = await (await productsCall(env, [product("p1")])).json(); // lost response retry
  assert.equal(r.results[0].status, "applied"); assert.equal(env.DB.writes, writes);
  r = await (await productsCall(env, [product("p1", { price: 600, base_version: 1 })])).json();
  assert.equal(r.results[0].status, "applied"); assert.equal(r.results[0].product.version, 2); assert.equal(r.results[0].product.seq, 2);
  writes = env.DB.writes;
  r = await (await productsCall(env, [product("p1", { price: 700, base_version: 1 })])).json();
  assert.deepEqual(r.results.map(x => x.status), ["conflict"]);
  assert.equal(r.results[0].product.price, 600); assert.equal(env.DB.writes, writes);
  // A missing row is created even with base_version>0 (revision 7): applied, version 1, never product:null.
  r = await (await productsCall(env, [product("p2", { base_version: 3 })])).json();
  assert.equal(r.results[0].status, "applied"); assert.equal(r.results[0].product.version, 1);
  writes = env.DB.writes;
  r = await (await productsCall(env, [product("p1", { price: 600, base_version: 0 })])).json(); // same content as server: applied, no write
  assert.equal(r.results[0].status, "applied"); assert.equal(env.DB.writes, writes);
  for (const bad of [[product("x", { name: "   " })], [product("x", { name: "あ".repeat(101) })], [product("x", { price: 1_000_000_001 })],
    [product("x", { active: 1 })], [product("x", { stop_at_zero: "yes" })], [product("x", { base_version: -1 })], [product("x"), product("x")], Array.from({ length: 101 }, (_, i) => product("p" + i))]) {
    assert.equal((await productsCall(env, bad)).status, 400);
  }
  assert.equal(env.DB.writes, writes);
});
test("stock: id idempotency, rejected events and validation", async () => {
  const env = await v4env();
  await productsCall(env, [product("tofu"), product("free", { track_stock: false })]);
  const events = [stockEvent(1, "tofu", "add", 3), stockEvent(2, "free", "add", 1), stockEvent(3, "none", "set", 1)];
  const first = await (await stockCall(env, events)).json();
  // track_stock:false is ignored: events apply to every product; only unknown products are rejected.
  assert.deepEqual(first.accepted, [uuid(1), uuid(2)]);
  assert.deepEqual(first.rejected, [{ id: uuid(3), reason: "product_not_found" }]);
  const writes = env.DB.writes, again = await (await stockCall(env, events)).json();
  assert.deepEqual(again.accepted, first.accepted); assert.equal(env.DB.writes, writes); assert.equal(again.products.find(p => p.id === "tofu").stock, 3);
  for (const bad of [[{ ...stockEvent(4, "tofu", "add", 1), id: "not-uuid" }], [stockEvent(4, "tofu", "set", -1)], [stockEvent(4, "tofu", "add", 1_000_001)],
    [stockEvent(4, "tofu", "move", 1)], [{ ...stockEvent(4, "tofu", "add", 1), reason: "x".repeat(201) }], [stockEvent(4, "tofu", "add", 1), stockEvent(4, "tofu", "add", 1)]]) {
    assert.equal((await stockCall(env, bad)).status, 400);
  }
  assert.equal(env.DB.writes, writes);
});
const float = { "1000": 5, "100": 20 };
function session(extra = {}) {
  return { id: "s1", device_id: "device-a", device_label: "Pixel 8", opened_at: "2026-11-20T00:00:00Z", closed_at: null, float, float_total: 7000,
    counted: null, counted_total: null, expected_total: null, sales_total: 0, cancel_total: 0, order_count: 0, ...extra };
}
test("sessions: idempotent upsert, totals validated, closed sessions are immutable", async () => {
  const env = await v4env();
  assert.deepEqual((await (await sessionsCall(env, [session()])).json()).accepted, ["s1"]);
  let writes = env.DB.writes;
  await sessionsCall(env, [session()]); assert.equal(env.DB.writes, writes);
  assert.deepEqual((await (await sessionsCall(env, [session({ sales_total: 1000, order_count: 1 })])).json()).accepted, ["s1"]);
  const closed = session({ closed_at: "2026-11-20T08:00:00Z", counted: { "1000": 8, "100": 19 }, counted_total: 9900, expected_total: 8000, sales_total: 1000, order_count: 1 });
  assert.deepEqual((await (await sessionsCall(env, [closed])).json()).accepted, ["s1"]);
  writes = env.DB.writes;
  assert.deepEqual((await (await sessionsCall(env, [closed])).json()).accepted, ["s1"]);
  const changed = await (await sessionsCall(env, [{ ...closed, sales_total: 5 }])).json();
  assert.deepEqual(changed, { schema_version: 1, accepted: [], rejected: [{ id: "s1", reason: "closed" }] });
  assert.equal((await (await sessionsCall(env, [session()])).json()).accepted.length, 0);
  assert.equal(env.DB.writes, writes);
  for (const bad of [session({ float_total: 7001 }), session({ float: { "3000": 1 }, float_total: 3000 }), session({ counted: { "1000": 1 }, counted_total: null }),
    session({ float: { "1000": 10000 }, float_total: 10_000_000 }), session({ closed_at: "2026-11-19T00:00:00Z" }), session({ device_label: "" })]) {
    assert.equal((await sessionsCall(env, [bad])).status, 400);
  }
  assert.equal(env.DB.writes, writes);
});
test("feed returns orders and products in seq order, cut at 512KiB with has_more", async () => {
  const env = await v4env();
  await send(env, [order("o1")]); await productsCall(env, [product("miso")]); await send(env, [order("o2")]);
  let page = await (await backupCall(env, "/v1/feed")).json();
  assert.deepEqual([page.after, page.next, page.has_more], [0, 3, false]);
  assert.deepEqual([page.orders.map(o => [o.id, o.seq]), page.products.map(p => [p.id, p.seq])], [[["o1", 1], ["o2", 3]], [["miso", 2]]]);
  page = await (await backupCall(env, "/v1/feed?after=1")).json();
  assert.deepEqual([page.orders.map(o => o.id), page.products.length, page.next], [["o2"], 1, 3]);
  assert.deepEqual(await (await backupCall(env, "/v1/feed?after=3")).json(), { schema_version: 1, after: 3, next: 3, has_more: false, products: [], orders: [] });
  for (const bad of ["-1", "1.5", "abc", "01", "9".repeat(16)]) assert.equal((await backupCall(env, "/v1/feed?after=" + bad)).status, 400);
  for (let i = 0; i < 3; i++) { const big = order("big-" + i); big.lines[0].name = "a".repeat(200_000); await send(env, [big]); }
  const writes = env.DB.writes, seen = [];
  page = await (await backupCall(env, "/v1/feed?after=3")).json();
  assert.deepEqual([page.orders.map(o => o.id), page.has_more], [["big-0", "big-1"], true]);
  seen.push(...page.orders);
  page = await (await backupCall(env, "/v1/feed?after=" + page.next)).json();
  assert.deepEqual([page.orders.map(o => o.id), page.has_more], [["big-2"], false]);
  assert.equal(env.DB.writes, writes);
});
test("feed respects the 100-order window so products after it are not skipped", async () => {
  const env = await v4env();
  await send(env, Array.from({ length: 50 }, (_, i) => order("a" + String(i).padStart(2, "0"))));
  await send(env, Array.from({ length: 50 }, (_, i) => order("b" + String(i).padStart(2, "0"))));
  await send(env, [order("c")]); await productsCall(env, [product("late")]);
  const first = await (await backupCall(env, "/v1/feed")).json();
  assert.deepEqual([first.orders.length, first.products.length, first.next, first.has_more], [100, 0, 100, true]);
  const second = await (await backupCall(env, "/v1/feed?after=100")).json();
  assert.deepEqual([second.orders.map(o => o.id), second.products.map(p => p.id), second.has_more], [["c"], ["late"], false]);
});
test("dashboard auth is separate from device auth and aggregates per JST day", async () => {
  const env = await v4env();
  const dash = (q = "", auth = dashboardToken) => worker.fetch(new Request("https://test.example/v1/dashboard" + q, { headers: { Authorization: "Bearer " + auth } }), env);
  assert.equal((await dash("", token)).status, 401);
  assert.equal(env.DB.reads, 0);
  for (const [path, body] of [["/v1/sync", { schema_version: 1, orders: [order()] }], ["/v1/products", { schema_version: 1, products: [product("p")] }],
    ["/v1/stock", { schema_version: 1, events: [stockEvent(1, "p", "add", 1)] }], ["/v1/sessions", { schema_version: 1, sessions: [session()] }], ["/v1/feed"], ["/v1/restore"], ["/v1/catalogs"]]) {
    assert.equal((await backupCall(env, path, body, dashboardToken)).status, 401, path);
  }
  assert.equal(env.DB.writes, 0);
  assert.equal((await dash("", dashboardToken)).status, 200);
  assert.equal((await worker.fetch(new Request("https://test.example/v1/dashboard", { headers: { Authorization: "Bearer " + token } }), { ...env, DASHBOARD_TOKEN_SHA256: env.DEVICE_TOKEN_SHA256 })).status, 503);
  assert.equal((await worker.fetch(new Request("https://test.example/v1/dashboard"), { ...env, DASHBOARD_TOKEN_SHA256: undefined })).status, 503);
  await productsCall(env, [product("tofu"), product("dengaku", { name: "田楽", price: 300, track_stock: false })]);
  await stockCall(env, [stockEvent(1, "tofu", "add", 3)]);
  const at = (id, created_at, extra = {}) => ({ ...v4order(id, extra), created_at });
  await send(env, [
    at("x1", "2026-11-19T15:30:00Z"), // 2026-11-20 00:30 JST
    at("x2", "2026-11-20T03:10:00.123Z", { customer_age: "adult", customer_gender: "male", device_id: "device-b", total: 1300, received: 2000, change_yen: 700,
      lines: [{ product_id: "tofu", name: "豆腐", price: 500, quantity: 2 }, { product_id: "dengaku", name: "田楽", price: 300, quantity: 1 }] }),
    at("x3", "2026-11-20T15:00:00Z"), // next JST day
    { ...order("x4", 2), created_at: "2026-11-20T04:00:00Z" } // cancelled 0.3.0-style order
  ]);
  await sessionsCall(env, [session({ closed_at: "2026-11-20T08:00:00Z", counted: { "1000": 8, "100": 19 }, counted_total: 9900, expected_total: 9000, sales_total: 2300, order_count: 2 })]);
  const d = await (await dash("?date=2026-11-20")).json();
  assert.deepEqual(d.totals, { net_sales: 2300, orders: 2, cancelled_orders: 1, cancelled_amount: 1000, average: 1150 });
  assert.deepEqual(d.by_hour.filter(h => h.orders), [{ hour: 0, sales: 1000, orders: 1 }, { hour: 12, sales: 1300, orders: 1 }]);
  assert.equal(d.by_hour.length, 24);
  assert.deepEqual(d.by_product, [{ id: "tofu", name: "豆腐", image_hash: null, quantity: 4, sales: 2000 }, { id: "dengaku", name: "田楽", image_hash: null, quantity: 1, sales: 300 }]);
  assert.deepEqual(d.segments.sort((a, b) => a.sales - b.sales), [{ age: "student", gender: "female", orders: 1, sales: 1000 }, { age: "adult", gender: "male", orders: 1, sales: 1300 }]);
  assert.deepEqual(d.stock, [{ id: "tofu", name: "豆腐", active: true, stop_at_zero: false, image_hash: null, stock: -3, sold: 4 },
    { id: "dengaku", name: "田楽", active: true, stop_at_zero: false, image_hash: null, stock: -1, sold: 1 }]);
  assert.deepEqual(d.devices.map(x => [x.device_id, x.device_label, x.orders, x.sales]), [["device-b", null, 1, 1300], ["device-a", "Pixel 8", 1, 1000], [null, null, 0, 0]]);
  assert.equal(d.sessions[0].difference, 900); assert.equal(d.sessions[0].device_label, "Pixel 8");
  const all = await (await dash()).json();
  assert.equal(all.date, null); assert.equal(all.totals.net_sales, 3300); assert.equal(all.stock[0].sold, 6);
  for (const q of ["?date=2026-13-01", "?date=2026-02-30", "?date=today"]) assert.equal((await dash(q)).status, 400);
  const page = await worker.fetch(new Request("https://test.example/dashboard"), {});
  assert.equal(page.status, 200); assert.match(page.headers.get("Content-Type"), /text\/html/);
  assert.equal(page.headers.get("Cache-Control"), "no-store");
  const html = await page.text(); assert.match(html, /sessionStorage/); assert.match(html, /Asia\/Tokyo/); assert.doesNotMatch(html, /<script src/);
});

test("length limits count Unicode code points; expected_total may be negative", async () => {
  const env = await v4env(), emoji = "😀";
  await productsCall(env, [product("tofu")]);
  assert.equal((await (await productsCall(env, [product("e", { name: emoji.repeat(100) })])).json()).results[0].status, "applied");
  assert.equal((await productsCall(env, [product("e2", { name: emoji.repeat(101) })])).status, 400);
  assert.deepEqual((await (await stockCall(env, [{ ...stockEvent(1, "tofu", "add", 1), reason: emoji.repeat(200) }])).json()).accepted, [uuid(1)]);
  assert.equal((await stockCall(env, [{ ...stockEvent(2, "tofu", "add", 1), reason: emoji.repeat(201) }])).status, 400);
  assert.deepEqual((await (await sessionsCall(env, [session({ device_label: emoji.repeat(64) })])).json()).accepted, ["s1"]);
  assert.equal((await sessionsCall(env, [session({ id: "s2", device_label: emoji.repeat(65) })])).status, 400);
  const cancelled = order("c", 2); cancelled.cancellation_reason = emoji.repeat(800);
  assert.equal((await (await send(env, [cancelled])).json()).accepted.length, 1);
  cancelled.id = "c2"; cancelled.cancellation_reason = emoji.repeat(801);
  assert.equal((await send(env, [cancelled])).status, 400);
  assert.equal((await send(env, [v4order("d", { device_id: emoji.repeat(64) })])).status, 200);
  assert.equal((await send(env, [v4order("d2", { device_id: emoji.repeat(65) })])).status, 400);
  for (const expected_total of [-1_000_000_000, -1, 1_000_000_000]) {
    assert.deepEqual((await (await sessionsCall(env, [session({ id: "x" + expected_total, expected_total })])).json()).accepted, ["x" + expected_total]);
  }
  for (const expected_total of [-1_000_000_001, 1_000_000_001, 1.5, "1"]) assert.equal((await sessionsCall(env, [session({ id: "y", expected_total })])).status, 400);
});
test("repair SQL fixes orders the 0.3.0 Worker wrote after migration 0003, idempotently", async () => {
  const env = await v4env(), DB = env.DB, repair = readFileSync(new URL("../repair/0003_after_deploy.sql", import.meta.url), "utf8");
  await productsCall(env, [product("tofu")]); await stockCall(env, [stockEvent(1, "tofu", "add", 10)]);
  await send(env, [order("new-1")]);
  // What the 0.3.0 Worker inserts: the original nine columns only, so seq stays 0.
  for (const o of [order("old-b"), { ...v4order("old-a"), customer_group: "family", ticket_no: "7", customer_relation: "tofu_fan", revision: 2, cancelled_at: "2026-11-20T01:01:00Z", cancellation_reason: "返金済み" }]) {
    const payload = JSON.stringify(o);
    DB.db.prepare("INSERT INTO cloud_orders(shop_id,id,revision,base_hash,payload_hash,payload,total_yen,cancelled,received_at) VALUES(?,?,?,?,?,?,?,?,?)")
      .run("test-shop", o.id, o.revision, "x", await digest(payload), payload, 1000, o.revision === 2 ? 1 : 0, "2026-11-20T02:00:00Z");
  }
  const correct = { ...DB.db.prepare("SELECT * FROM cloud_orders WHERE id='new-1'").get() };
  const correctLines = DB.db.prepare("SELECT * FROM cloud_order_lines WHERE order_id='new-1'").all().map(r => ({ ...r }));
  const before = await (await backupCall(env, "/v1/feed")).json();
  assert.equal(before.orders.length, 1); assert.equal(await stockOf(env, "tofu"), 8); // the old rows are invisible
  DB.db.exec(repair);
  const rows = DB.db.prepare("SELECT id,seq,created_at,device_id,customer_age,customer_gender FROM cloud_orders WHERE id LIKE 'old-%' ORDER BY id").all().map(r => ({ ...r }));
  assert.deepEqual(rows, [{ id: "old-a", seq: 5, created_at: "2026-11-20T01:00:00Z", device_id: "device-a", customer_age: "student", customer_gender: "female" },
    { id: "old-b", seq: 6, created_at: "2026-11-20T01:00:00Z", device_id: null, customer_age: null, customer_gender: null }]);
  assert.deepEqual(DB.db.prepare("SELECT customer_group,ticket_no,customer_relation FROM cloud_orders WHERE id LIKE 'old-%' ORDER BY id").all()
    .map(r => [r.customer_group, r.ticket_no, r.customer_relation]), [["family", "7", "tofu_fan"], [null, null, null]]);
  assert.deepEqual({ ...DB.db.prepare("SELECT * FROM cloud_orders WHERE id='new-1'").get() }, correct);
  assert.deepEqual(DB.db.prepare("SELECT * FROM cloud_order_lines WHERE order_id='new-1'").all().map(r => ({ ...r })), correctLines);
  assert.equal(await stockOf(env, "tofu"), 6); // old-b sold 2, old-a is cancelled
  const feed = await (await backupCall(env, "/v1/feed?after=" + before.next)).json();
  assert.deepEqual([feed.orders.map(o => o.id), feed.products.map(p => [p.id, p.seq])], [["old-a", "old-b"], [["tofu", 7]]]);
  const snapshot = () => JSON.stringify(["cloud_orders", "cloud_order_lines", "cloud_products"].map(t => DB.db.prepare(`SELECT * FROM ${t} ORDER BY 1,2,3`).all()));
  const repaired = snapshot();
  DB.db.exec(repair); DB.db.exec(repair);
  assert.equal(snapshot(), repaired);
  assert.equal(DB.db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='repair_0003_orders'").get().n, 0);
});
test("migration 0004 keeps production rows, tracks every product and republishes formerly untracked ones", async () => {
  const DB = new LocalD1(3), env = { ...(await v4env()), DB };
  // Rows as the deployed 0.4.0 Worker wrote them (before 0004).
  const insert = DB.db.prepare("INSERT INTO cloud_products(shop_id,id,name,price,active,track_stock,version,seq,updated_at) VALUES(?,?,?,?,?,?,?,?,?)");
  insert.run("test-shop", "tofu", "豆腐", 500, 1, 1, 2, 3, "t"); insert.run("test-shop", "free", "水", 0, 1, 0, 1, 1, "t"); insert.run("test-shop", "tea", "茶", 100, 0, 0, 1, 2, "t");
  insert.run("other-shop", "x", "x", 1, 1, 0, 1, 1, "t");
  DB.db.prepare("INSERT INTO cloud_orders(shop_id,id,revision,base_hash,payload_hash,payload,total_yen,cancelled,received_at,seq) VALUES(?,?,?,?,?,?,?,?,?,?)")
    .run("test-shop", "o", 1, "b", "h", "{}", 0, 0, "t", 4);
  DB.db.prepare("INSERT INTO cloud_order_lines VALUES(?,?,?,?,?,?)").run("test-shop", "o", "free", 2, 0, 0);
  DB.migrate();
  const rows = DB.db.prepare("SELECT shop_id,id,name,price,active,track_stock,stop_at_zero,version,seq FROM cloud_products ORDER BY shop_id,id").all().map(r => ({ ...r }));
  assert.deepEqual(rows, [
    { shop_id: "other-shop", id: "x", name: "x", price: 1, active: 1, track_stock: 1, stop_at_zero: 0, version: 1, seq: 2 },
    { shop_id: "test-shop", id: "free", name: "水", price: 0, active: 1, track_stock: 1, stop_at_zero: 0, version: 1, seq: 5 },
    { shop_id: "test-shop", id: "tea", name: "茶", price: 100, active: 0, track_stock: 1, stop_at_zero: 0, version: 1, seq: 6 },
    { shop_id: "test-shop", id: "tofu", name: "豆腐", price: 500, active: 1, track_stock: 1, stop_at_zero: 0, version: 2, seq: 3 }]);
  const feed = await (await backupCall(env, "/v1/feed?after=4")).json();
  assert.deepEqual(feed.products.map(p => [p.id, p.stock, p.track_stock, p.stop_at_zero]), [["free", -2, true, false], ["tea", 0, true, false]]);
});
test("products: stop_at_zero is versioned content, track_stock is ignored and always true", async () => {
  const env = await v4env();
  let r = await (await productsCall(env, [product("p", { track_stock: false })])).json();
  assert.deepEqual([r.results[0].product.track_stock, r.results[0].product.stop_at_zero, r.results[0].product.stock], [true, false, 0]);
  let writes = env.DB.writes;
  // Only track_stock differs: same content, applied without a write.
  r = await (await productsCall(env, [product("p", { track_stock: true, base_version: 1 })])).json();
  assert.equal(r.results[0].status, "applied"); assert.equal(r.results[0].product.version, 1); assert.equal(env.DB.writes, writes);
  r = await (await productsCall(env, [product("p", { stop_at_zero: true, base_version: 1 })])).json();
  assert.deepEqual([r.results[0].status, r.results[0].product.stop_at_zero, r.results[0].product.version], ["applied", true, 2]);
  writes = env.DB.writes;
  r = await (await productsCall(env, [product("p", { stop_at_zero: false, base_version: 1 })])).json(); // stale editor
  assert.deepEqual([r.results[0].status, r.results[0].product.stop_at_zero], ["conflict", true]); assert.equal(env.DB.writes, writes);
  r = await (await productsCall(env, [{ id: "q", name: "味噌", price: 100, active: true, base_version: 0 }])).json(); // both flags omitted
  assert.deepEqual([r.results[0].status, r.results[0].product.stop_at_zero, r.results[0].product.track_stock], ["applied", false, true]);
  // Selling past zero is allowed and reported as a negative integer everywhere.
  await send(env, [{ ...order("neg"), lines: [{ product_id: "q", name: "味噌", price: 100, quantity: 3 }], total: 300, received: 300, change_yen: 0 }]);
  assert.equal(await stockOf(env, "q"), -3);
  assert.equal(env.DB.db.prepare("SELECT COUNT(*) AS n FROM cloud_products WHERE track_stock<>1").get().n, 0);
});

const jpeg = (fill = 1, size = 1000) => { const b = new Uint8Array(size).fill(fill); b.set([0xff, 0xd8, 0xff, 0xe0]); return b; };
const upload = (env, body, type = "image/jpeg", auth = token) => worker.fetch(new Request("https://test.example/v1/images",
  { method: "POST", headers: { Authorization: "Bearer " + auth, "Content-Type": type }, body }), env);
const getImage = (env, hash, auth = token, headers = {}) => worker.fetch(new Request("https://test.example/v1/images/" + hash,
  { headers: { Authorization: "Bearer " + auth, ...headers } }), env);
test("images: JPEG-only content-addressed upload, idempotent, immutable download for device and dashboard tokens", async () => {
  const env = await v4env(), body = jpeg();
  const r = await (await upload(env, body)).json();
  const hash = createHash("sha256").update(body).digest("hex");
  assert.deepEqual(r, { schema_version: 1, hash, size: 1000 });
  const writes = env.DB.writes;
  assert.deepEqual(await (await upload(env, body)).json(), r); assert.equal(env.DB.writes, writes);
  for (const auth of [token, dashboardToken]) {
    const res = await getImage(env, hash, auth);
    assert.equal(res.status, 200); assert.equal(res.headers.get("Content-Type"), "image/jpeg");
    assert.equal(res.headers.get("Cache-Control"), "private, max-age=31536000, immutable"); assert.equal(res.headers.get("ETag"), `"${hash}"`);
    assert.deepEqual(new Uint8Array(await res.arrayBuffer()), body);
  }
  const notModified = await getImage(env, hash, token, { "If-None-Match": `"${hash}"` });
  assert.equal(notModified.status, 304); assert.equal(notModified.headers.get("ETag"), `"${hash}"`);
  assert.equal((await getImage(env, "0".repeat(64))).status, 404);
  assert.equal((await getImage(env, "ABC")).status, 404);
  assert.equal((await getImage(env, hash, "wrong")).status, 401);
  // Upload is a write: the dashboard token is refused.
  assert.equal((await upload(env, jpeg(2), "image/jpeg", dashboardToken)).status, 401);
  assert.equal((await upload(env, jpeg(2), "image/png")).status, 415);
  assert.equal((await upload(env, jpeg(2), "application/json")).status, 415);
  assert.equal((await upload(env, new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2]))).status, 400);
  assert.equal((await upload(env, new Uint8Array(0))).status, 400);
  assert.equal((await upload(env, jpeg(3, 512 * 1024))).status, 200);
  assert.equal((await upload(env, jpeg(4, 512 * 1024 + 1))).status, 413);
  assert.equal(env.DB.db.prepare("SELECT COUNT(*) AS n FROM cloud_images").get().n, 2);
  assert.equal((await upload({ ...env, SHOP_ID: "other" }, body)).status, 200);
  assert.equal((await getImage({ ...env, SHOP_ID: "other2" }, hash)).status, 404);
});
test("products: image_hash is versioned content, must reference an uploaded image, and appears in feed and dashboard", async () => {
  const env = await v4env();
  const a = (await (await upload(env, jpeg(1))).json()).hash, b = (await (await upload(env, jpeg(2))).json()).hash;
  let writes = env.DB.writes;
  const missing = await productsCall(env, [product("p", { image_hash: "f".repeat(64) }), product("q")]);
  assert.equal(missing.status, 400); assert.deepEqual((await missing.json()).products, ["p"]); assert.equal(env.DB.writes, writes);
  for (const image_hash of ["F".repeat(64), "abc", 1]) assert.equal((await productsCall(env, [product("p", { image_hash })])).status, 400);
  let r = await (await productsCall(env, [product("p", { image_hash: a })])).json();
  assert.deepEqual([r.results[0].status, r.results[0].product.image_hash, r.results[0].product.version], ["applied", a, 1]);
  writes = env.DB.writes;
  r = await (await productsCall(env, [product("p", { image_hash: a, base_version: 1 })])).json();
  assert.equal(r.results[0].status, "applied"); assert.equal(env.DB.writes, writes);
  r = await (await productsCall(env, [product("p", { image_hash: b, base_version: 1 })])).json();
  assert.deepEqual([r.results[0].product.image_hash, r.results[0].product.version], [b, 2]);
  r = await (await productsCall(env, [product("p", { image_hash: a, base_version: 1 })])).json(); // stale editor
  assert.deepEqual([r.results[0].status, r.results[0].product.image_hash], ["conflict", b]);
  r = await (await productsCall(env, [product("p", { base_version: 2 })])).json(); // omitted means "remove the photo"
  assert.deepEqual([r.results[0].status, r.results[0].product.image_hash, r.results[0].product.version], ["applied", null, 3]);
  await productsCall(env, [product("p", { image_hash: a, base_version: 3 })]);
  assert.equal((await (await backupCall(env, "/v1/feed")).json()).products[0].image_hash, a);
  await send(env, [{ ...order("o"), lines: [{ product_id: "p", name: "豆腐", price: 500, quantity: 2 }] }]);
  const d = await (await worker.fetch(new Request("https://test.example/v1/dashboard", { headers: { Authorization: "Bearer " + dashboardToken } }), env)).json();
  assert.equal(d.by_product[0].image_hash, a); assert.equal(d.stock[0].image_hash, a);
  const html = await (await worker.fetch(new Request("https://test.example/dashboard"), {})).text();
  assert.match(html, /\/v1\/images\//); assert.match(html, /createObjectURL/);
});

test("customer_group: optional, validated, part of the content hash; existing payload hashes are unchanged", async () => {
  const env = await v4env();
  for (const customer_group of ["solo ", "team", 1, ""]) assert.equal((await send(env, [v4order("bad", { customer_group })])).status, 400);
  assert.equal(env.DB.writes, 0);
  // Exactly the 0.4.0 (pre-group) normalized payload: its hash must not change.
  const before = v4order("o40"), legacy = JSON.stringify({ id: before.id, revision: 1, created_at: before.created_at, total: before.total, received: before.received,
    change_yen: before.change_yen, cancelled_at: null, cancellation_reason: null, lines: before.lines, device_id: "device-a", customer_age: "student", customer_gender: "female" });
  await send(env, [{ ...before, customer_group: null }, v4order("g", { customer_group: "couple" })]);
  const row = env.DB.db.prepare("SELECT payload,payload_hash,base_hash,customer_group FROM cloud_orders WHERE id='o40'").get();
  assert.equal(row.payload, legacy); assert.equal(row.payload_hash, await digest(legacy)); assert.equal(row.base_hash, await digest(legacy)); assert.equal(row.customer_group, null);
  const g = env.DB.db.prepare("SELECT payload,customer_group FROM cloud_orders WHERE id='g'").get();
  assert.equal(g.customer_group, "couple"); assert.equal(JSON.parse(g.payload).customer_group, "couple");
  const writes = env.DB.writes;
  assert.equal((await (await send(env, [before])).json()).accepted.length, 1); assert.equal(env.DB.writes, writes);
  // Same revision with a group added or changed is a content conflict (base_hash includes it); cancellation must keep it.
  assert.equal((await (await send(env, [{ ...before, customer_group: "solo" }])).json()).conflicts.length, 1);
  assert.equal((await (await send(env, [v4order("g", { customer_group: "family" })])).json()).conflicts.length, 1);
  const cancel = { ...v4order("g", { customer_group: "couple" }), revision: 2, cancelled_at: "2026-11-20T01:01:00Z", cancellation_reason: "返金済み" };
  assert.equal((await (await send(env, [{ ...cancel, customer_group: null }])).json()).conflicts.length, 1);
  assert.equal((await (await send(env, [cancel])).json()).accepted.length, 1);
});
test("migration 0006 fills customer_group and ticket_no from existing payloads without touching other rows", async () => {
  const DB = new LocalD1(5), insert = DB.db.prepare("INSERT INTO cloud_orders(shop_id,id,revision,base_hash,payload_hash,payload,total_yen,cancelled,received_at,seq) VALUES(?,?,?,?,?,?,?,?,?,?)");
  insert.run("s", "with", 1, "b", "h1", JSON.stringify({ ...v4order("with"), customer_group: "friends", ticket_no: "A-1" }), 1000, 0, "t", 1);
  insert.run("s", "without", 1, "b", "h2", JSON.stringify(order("without")), 1000, 0, "t", 2);
  const before = DB.db.prepare("SELECT * FROM cloud_orders ORDER BY id").all().map(r => ({ ...r }));
  DB.migrate(6);
  const after = DB.db.prepare("SELECT * FROM cloud_orders ORDER BY id").all().map(r => ({ ...r }));
  assert.deepEqual(after.map(r => [r.customer_group, r.ticket_no]), [["friends", "A-1"], [null, null]]);
  assert.deepEqual(after.map(({ customer_group, ticket_no, ...rest }) => rest), before);
});
test("dashboard groups count orders and sales per group, including unset", async () => {
  const env = await v4env();
  await send(env, [v4order("a", { customer_group: "family" }), v4order("b", { customer_group: "solo" }), v4order("c", { customer_group: "family" }), v4order("d"),
    { ...v4order("e", { customer_group: "group" }), revision: 2, cancelled_at: "2026-11-20T01:01:00Z", cancellation_reason: "返金済み" }]);
  const d = await (await worker.fetch(new Request("https://test.example/v1/dashboard?date=2026-11-20", { headers: { Authorization: "Bearer " + dashboardToken } }), env)).json();
  assert.deepEqual(d.groups, [{ group: "solo", orders: 1, sales: 1000 }, { group: "family", orders: 2, sales: 2000 }, { group: null, orders: 1, sales: 1000 }]);
  const html = await (await worker.fetch(new Request("https://test.example/dashboard"), {})).text();
  assert.match(html, /グループ別/); assert.match(html, /カップル/);
});

test("ticket_no: optional, validated, stored, part of the content hash; existing hashes unchanged; shown in dashboard", async () => {
  const env = await v4env();
  for (const ticket_no of ["", "-12", "a-1", "ABC-1", "A-12345", "A--1", "12 ", 12, "Ａ-1"]) assert.equal((await send(env, [v4order("bad", { ticket_no })])).status, 400, String(ticket_no));
  assert.equal(env.DB.writes, 0);
  const accepted = ["1", "9999", "A1", "A-12", "AB-1234"];
  assert.equal((await (await send(env, accepted.map((ticket_no, i) => v4order("t" + i, { ticket_no })))).json()).accepted.length, 5);
  assert.deepEqual(env.DB.db.prepare("SELECT ticket_no FROM cloud_orders ORDER BY id").all().map(r => r.ticket_no), accepted);
  assert.equal(JSON.parse(env.DB.db.prepare("SELECT payload FROM cloud_orders WHERE id='t3'").get().payload).ticket_no, "A-12");
  // A pre-ticket order keeps its payload/hash and replays read-only.
  const plain = v4order("plain"), expected = JSON.stringify(normalize(plain));
  await send(env, [{ ...plain, ticket_no: null }]);
  const row = env.DB.db.prepare("SELECT payload,payload_hash,ticket_no FROM cloud_orders WHERE id='plain'").get();
  assert.equal(row.payload, expected); assert.ok(!row.payload.includes("ticket_no")); assert.equal(row.payload_hash, await digest(expected)); assert.equal(row.ticket_no, null);
  const writes = env.DB.writes;
  assert.equal((await (await send(env, [plain])).json()).accepted.length, 1); assert.equal(env.DB.writes, writes);
  // base_hash includes it: adding/changing the number at the same revision, or dropping it on cancellation, conflicts.
  assert.equal((await (await send(env, [{ ...plain, ticket_no: "5" }])).json()).conflicts.length, 1);
  assert.equal((await (await send(env, [v4order("t3", { ticket_no: "A-13" })])).json()).conflicts.length, 1);
  const cancel = { ...v4order("t3", { ticket_no: "A-12" }), revision: 2, cancelled_at: "2026-11-20T01:01:00Z", cancellation_reason: "返金済み" };
  assert.equal((await (await send(env, [{ ...cancel, ticket_no: null }])).json()).conflicts.length, 1);
  assert.equal((await (await send(env, [cancel])).json()).accepted.length, 1);
  assert.equal(env.DB.db.prepare("SELECT ticket_no FROM cloud_orders WHERE id='t3'").get().ticket_no, "A-12");
  const d = await (await worker.fetch(new Request("https://test.example/v1/dashboard", { headers: { Authorization: "Bearer " + dashboardToken } }), env)).json();
  assert.equal(d.recent.length, 6);
  assert.deepEqual(d.recent.find(o => o.id === "t3"), { id: "t3", ticket_no: "A-12", created_at: "2026-11-20T01:00:00Z", total: 1000, cancelled: true, device_id: "device-a" });
  assert.match(await (await worker.fetch(new Request("https://test.example/dashboard"), {})).text(), /整理番号/);
});

test("customer_relation: optional, validated, hashed; existing hashes unchanged; migration 0007 and dashboard relations", async () => {
  const env = await v4env();
  for (const customer_relation of ["fan", "Tofu_fan", 1, ""]) assert.equal((await send(env, [v4order("bad", { customer_relation })])).status, 400);
  assert.equal(env.DB.writes, 0);
  // The pre-relation payload (with group and ticket) must keep its exact bytes and hash.
  const before = v4order("o", { customer_group: "solo", ticket_no: "A-1" });
  const legacy = JSON.stringify({ id: "o", revision: 1, created_at: before.created_at, total: 1000, received: 2000, change_yen: 1000, cancelled_at: null,
    cancellation_reason: null, lines: before.lines, device_id: "device-a", customer_age: "student", customer_gender: "female", customer_group: "solo", ticket_no: "A-1" });
  await send(env, [{ ...before, customer_relation: null }, v4order("r", { customer_relation: "member" }), v4order("r2", { customer_relation: "member" }), v4order("r3", { customer_relation: "acquaintance" })]);
  const row = env.DB.db.prepare("SELECT payload,payload_hash,base_hash,customer_relation FROM cloud_orders WHERE id='o'").get();
  assert.equal(row.payload, legacy); assert.equal(row.payload_hash, await digest(legacy)); assert.equal(row.base_hash, await digest(legacy)); assert.equal(row.customer_relation, null);
  const writes = env.DB.writes;
  assert.equal((await (await send(env, [before])).json()).accepted.length, 1); assert.equal(env.DB.writes, writes);
  assert.equal(env.DB.db.prepare("SELECT customer_relation FROM cloud_orders WHERE id='r'").get().customer_relation, "member");
  assert.equal((await (await send(env, [{ ...before, customer_relation: "general" }])).json()).conflicts.length, 1);
  assert.equal((await (await send(env, [v4order("r", { customer_relation: "relative" })])).json()).conflicts.length, 1);
  const cancel = { ...v4order("r", { customer_relation: "member" }), revision: 2, cancelled_at: "2026-11-20T01:01:00Z", cancellation_reason: "返金済み" };
  assert.equal((await (await send(env, [{ ...cancel, customer_relation: null }])).json()).conflicts.length, 1);
  assert.equal((await (await send(env, [cancel])).json()).accepted.length, 1);
  const d = await (await worker.fetch(new Request("https://test.example/v1/dashboard", { headers: { Authorization: "Bearer " + dashboardToken } }), env)).json();
  assert.deepEqual(d.relations, [{ relation: "acquaintance", orders: 1, sales: 1000 }, { relation: "member", orders: 1, sales: 1000 }, { relation: null, orders: 1, sales: 1000 }]);
  assert.match(await (await worker.fetch(new Request("https://test.example/dashboard"), {})).text(), /関係別/);
  // Migration 0007 fills the column from payloads and leaves everything else as it was.
  const DB = new LocalD1(6), insert = DB.db.prepare("INSERT INTO cloud_orders(shop_id,id,revision,base_hash,payload_hash,payload,total_yen,cancelled,received_at,seq) VALUES(?,?,?,?,?,?,?,?,?,?)");
  insert.run("s", "with", 1, "b", "h1", JSON.stringify(v4order("with", { customer_relation: "relative" })), 1000, 0, "t", 1);
  insert.run("s", "without", 1, "b", "h2", JSON.stringify(order("without")), 1000, 0, "t", 2);
  const old = DB.db.prepare("SELECT * FROM cloud_orders ORDER BY id").all().map(r => ({ ...r }));
  DB.migrate();
  const now = DB.db.prepare("SELECT * FROM cloud_orders ORDER BY id").all().map(r => ({ ...r }));
  assert.deepEqual(now.map(r => r.customer_relation), ["relative", null]);
  assert.deepEqual(now.map(({ customer_relation, ...rest }) => rest), old);
});

test("DASHBOARD_PUBLIC opens the dashboard and photos without a token but never the device routes", async () => {
  const env = { ...(await v4env()), DASHBOARD_PUBLIC: "true" }, body = jpeg();
  const hash = (await (await upload(env, body)).json()).hash;
  assert.equal((await worker.fetch(new Request("https://test.example/v1/dashboard"), env)).status, 200);
  assert.equal((await worker.fetch(new Request("https://test.example/v1/dashboard"), { ...env, DASHBOARD_TOKEN_SHA256: undefined })).status, 200);
  assert.equal((await getImage(env, hash, "wrong")).status, 200);
  const writes = env.DB.writes;
  assert.equal((await backupCall(env, "/v1/sync", { schema_version: 1, orders: [order()] }, "wrong")).status, 401);
  assert.equal((await backupCall(env, "/v1/feed", undefined, dashboardToken)).status, 401);
  assert.equal((await upload(env, jpeg(2), "image/jpeg", "wrong")).status, 401);
  assert.equal(env.DB.writes, writes);
  assert.equal((await worker.fetch(new Request("https://test.example/v1/dashboard"), { ...env, DASHBOARD_PUBLIC: "1" })).status, 401);
});
