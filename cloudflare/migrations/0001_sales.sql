CREATE TABLE cloud_orders (
  shop_id TEXT NOT NULL,
  id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision IN (1, 2)),
  base_hash TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  payload TEXT NOT NULL,
  total_yen INTEGER NOT NULL,
  cancelled INTEGER NOT NULL CHECK(cancelled IN (0, 1)),
  received_at TEXT NOT NULL,
  PRIMARY KEY(shop_id, id)
);
