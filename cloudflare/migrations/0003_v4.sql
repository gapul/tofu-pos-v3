-- 0.4.0: change feed, cloud product master, derived stock, drawer sessions. Existing rows are kept.
ALTER TABLE cloud_orders ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
ALTER TABLE cloud_orders ADD COLUMN device_id TEXT;
ALTER TABLE cloud_orders ADD COLUMN customer_age TEXT;
ALTER TABLE cloud_orders ADD COLUMN customer_gender TEXT;
ALTER TABLE cloud_orders ADD COLUMN created_at TEXT;
-- Existing orders get seq 1..N per shop in primary-key order; the other columns come from the payload.
UPDATE cloud_orders SET seq=r.n,
  device_id=json_extract(cloud_orders.payload,'$.device_id'),
  customer_age=json_extract(cloud_orders.payload,'$.customer_age'),
  customer_gender=json_extract(cloud_orders.payload,'$.customer_gender'),
  created_at=json_extract(cloud_orders.payload,'$.created_at')
FROM (SELECT shop_id,id,ROW_NUMBER() OVER (PARTITION BY shop_id ORDER BY id) AS n FROM cloud_orders) AS r
WHERE cloud_orders.shop_id=r.shop_id AND cloud_orders.id=r.id;
CREATE INDEX cloud_orders_seq ON cloud_orders(shop_id,seq);
CREATE INDEX cloud_orders_created ON cloud_orders(shop_id,created_at);
CREATE TABLE cloud_order_lines (
  shop_id TEXT NOT NULL,
  order_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  quantity INTEGER NOT NULL,
  price INTEGER NOT NULL,
  cancelled INTEGER NOT NULL,
  PRIMARY KEY(shop_id,order_id,product_id)
);
CREATE INDEX cloud_order_lines_product ON cloud_order_lines(shop_id,product_id,cancelled);
INSERT OR REPLACE INTO cloud_order_lines(shop_id,order_id,product_id,quantity,price,cancelled)
SELECT o.shop_id,o.id,json_extract(j.value,'$.product_id'),json_extract(j.value,'$.quantity'),json_extract(j.value,'$.price'),o.cancelled
FROM cloud_orders o, json_each(o.payload,'$.lines') j;
CREATE TABLE cloud_products (
  shop_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  price INTEGER NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  track_stock INTEGER NOT NULL DEFAULT 0,
  version INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(shop_id,id)
);
CREATE INDEX cloud_products_seq ON cloud_products(shop_id,seq);
CREATE TABLE cloud_stock_events (
  shop_id TEXT NOT NULL,
  id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  delta INTEGER NOT NULL,
  kind TEXT NOT NULL,
  reason TEXT,
  created_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  PRIMARY KEY(shop_id,id)
);
CREATE INDEX cloud_stock_events_product ON cloud_stock_events(shop_id,product_id);
CREATE TABLE cloud_sessions (
  shop_id TEXT NOT NULL,
  id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  device_label TEXT NOT NULL,
  opened_at TEXT NOT NULL,
  closed_at TEXT,
  payload TEXT NOT NULL,
  received_at TEXT NOT NULL,
  PRIMARY KEY(shop_id,id)
);
CREATE INDEX cloud_sessions_opened ON cloud_sessions(shop_id,opened_at);
