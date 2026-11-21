// Shared helpers. The Worker entry module may export only handlers (newer workerd rejects other exports).
export const MAX_BYTES = 256 * 1024;
export const MAX_MONEY = 1_000_000_000;
export const AGES = ["child", "student", "adult", "senior"];
export const GENDERS = ["male", "female", "other"];
export const GROUPS = ["solo", "friends", "family", "couple", "group"];
export const RELATIONS = ["acquaintance", "relative", "member", "tofu_fan", "general"];
// Ticket number: optional device prefix (1-2 capitals, optional hyphen) + per-device daily sequence, e.g. "12", "A-12".
export const TICKET = /^(?:[A-Z]{1,2}-?)?[0-9]{1,4}$/;
export const DENOMINATIONS = ["10000", "5000", "2000", "1000", "500", "100", "50", "10", "5", "1"];
export const json = (body, status = 200, headers = {}) => Response.json(body, {
  status, headers: { "Cache-Control": "no-store", ...headers }
});
export async function digest(input) {
  const hash = await crypto.subtle.digest("SHA-256", typeof input === "string" ? new TextEncoder().encode(input) : input);
  return [...new Uint8Array(hash)].map(x => x.toString(16).padStart(2, "0")).join("");
}
export function requireValue(condition, message) { if (!condition) throw new Error(message); }
// Limits count Unicode code points (same as Android/iOS). UTF-16 length is an upper bound, so it is a fast path.
export function chars(value) { let n = 0; for (const _ of value) n++; return n; }
export function text(value, limit) { return typeof value === "string" && value.length > 0 && (value.length <= limit || chars(value) <= limit); }
export function money(value) { return Number.isSafeInteger(value) && value >= 0 && value <= MAX_MONEY; }
export function integer(value, min, max) { return Number.isSafeInteger(value) && value >= min && value <= max; }
export function date(value) { return text(value, 40) && /Z$/.test(value) && Number.isFinite(Date.parse(value)); }
export function normalize(order) {
  requireValue(order && typeof order === "object", "invalid order");
  requireValue(text(order.id, 128), "invalid id");
  requireValue(order.revision === 1 || order.revision === 2, "invalid revision");
  requireValue(date(order.created_at), "invalid date");
  requireValue(money(order.total) && money(order.received) && money(order.change_yen), "invalid money");
  requireValue(order.received >= order.total && order.received - order.total === order.change_yen, "invalid change");
  requireValue(Array.isArray(order.lines) && order.lines.length >= 1, "invalid lines");
  requireValue(order.device_id == null || text(order.device_id, 64), "invalid device_id");
  requireValue(order.customer_age == null || AGES.includes(order.customer_age), "invalid customer_age");
  requireValue(order.customer_gender == null || GENDERS.includes(order.customer_gender), "invalid customer_gender");
  requireValue(order.customer_group == null || GROUPS.includes(order.customer_group), "invalid customer_group");
  requireValue(order.customer_relation == null || RELATIONS.includes(order.customer_relation), "invalid customer_relation");
  requireValue(order.ticket_no == null || (typeof order.ticket_no === "string" && order.ticket_no.length <= 8 && TICKET.test(order.ticket_no)), "invalid ticket_no");
  const ids = new Set();
  const lines = order.lines.map(line => {
    requireValue(line && text(line.product_id, 128) && text(line.name, MAX_BYTES) && line.name.trim(), "invalid product");
    requireValue(!ids.has(line.product_id), "duplicate product"); ids.add(line.product_id);
    requireValue(money(line.price) && Number.isInteger(line.quantity) && line.quantity >= 1 && line.quantity <= 999, "invalid quantity/price");
    return { product_id: line.product_id, name: line.name, price: line.price, quantity: line.quantity };
  });
  requireValue(lines.reduce((sum, line) => sum + line.price * line.quantity, 0) === order.total, "invalid total");
  const cancelled = order.revision === 2;
  requireValue(cancelled ? date(order.cancelled_at) && text(order.cancellation_reason, 800) && order.cancellation_reason.trim() : order.cancelled_at == null && order.cancellation_reason == null, "invalid cancellation");
  // Optional 0.4.0 fields are omitted when null so 0.3.0 payloads and hashes stay byte-identical.
  return {
    id: order.id, revision: order.revision, created_at: order.created_at, total: order.total,
    received: order.received, change_yen: order.change_yen,
    cancelled_at: cancelled ? order.cancelled_at : null,
    cancellation_reason: cancelled ? order.cancellation_reason : null, lines,
    ...(order.device_id != null && { device_id: order.device_id }),
    ...(order.customer_age != null && { customer_age: order.customer_age }),
    ...(order.customer_gender != null && { customer_gender: order.customer_gender }),
    ...(order.customer_group != null && { customer_group: order.customer_group }),
    ...(order.ticket_no != null && { ticket_no: order.ticket_no }),
    ...(order.customer_relation != null && { customer_relation: order.customer_relation })
  };
}
export async function readBody(request) {
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await readBytes(request, MAX_BYTES)));
}
export async function readBytes(request, limit) {
  const reader = request.body?.getReader();
  if (!reader) throw new Error("empty body");
  const chunks = []; let size = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) { await reader.cancel(); throw new Error("too large"); }
    chunks.push(value);
  }
  const data = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.byteLength; }
  return data;
}
