-- Run once right after deploying the 0.4.0 Worker (safe to run any number of times):
--   pnpm exec wrangler d1 execute tofu-pos-v3 --remote --file repair/0003_after_deploy.sql
-- Orders accepted by the 0.3.0 Worker between migration 0003 and the 0.4.0 deploy have seq=0
-- (invisible to /v1/feed), no created_at/device columns and no cloud_order_lines rows.
-- Only seq=0 orders are touched; rows the 0.4.0 Worker wrote (seq>0) are left as they are.
-- Requires migrations up to 0007 (customer_group, ticket_no and customer_relation columns).
-- The work list is a real table (not TEMP) so an interrupted run can be resumed; it is dropped at the end.
CREATE TABLE IF NOT EXISTS repair_0003_orders (shop_id TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(shop_id,id));
INSERT OR IGNORE INTO repair_0003_orders(shop_id,id) SELECT shop_id,id FROM cloud_orders WHERE seq=0;
-- Lines first, while the rows are still identifiable by seq=0. REPLACE is idempotent.
INSERT OR REPLACE INTO cloud_order_lines(shop_id,order_id,product_id,quantity,price,cancelled)
SELECT o.shop_id,o.id,json_extract(j.value,'$.product_id'),json_extract(j.value,'$.quantity'),json_extract(j.value,'$.price'),o.cancelled
FROM cloud_orders o, json_each(o.payload,'$.lines') j WHERE o.seq=0;
-- New seq after the shop's current maximum (orders and products), in primary-key order.
UPDATE cloud_orders SET seq=m.base+r.n,
  device_id=json_extract(cloud_orders.payload,'$.device_id'),
  customer_age=json_extract(cloud_orders.payload,'$.customer_age'),
  customer_gender=json_extract(cloud_orders.payload,'$.customer_gender'),
  customer_group=json_extract(cloud_orders.payload,'$.customer_group'),
  ticket_no=json_extract(cloud_orders.payload,'$.ticket_no'),
  customer_relation=json_extract(cloud_orders.payload,'$.customer_relation'),
  created_at=json_extract(cloud_orders.payload,'$.created_at')
FROM (SELECT shop_id,id,ROW_NUMBER() OVER (PARTITION BY shop_id ORDER BY id) AS n FROM cloud_orders WHERE seq=0) AS r,
  (SELECT s.shop_id,MAX(COALESCE((SELECT MAX(seq) FROM cloud_orders WHERE shop_id=s.shop_id),0),
    COALESCE((SELECT MAX(seq) FROM cloud_products WHERE shop_id=s.shop_id),0)) AS base
   FROM (SELECT DISTINCT shop_id FROM cloud_orders WHERE seq=0) AS s) AS m
WHERE cloud_orders.shop_id=r.shop_id AND cloud_orders.id=r.id AND m.shop_id=r.shop_id;
-- Stock of products sold by those orders changed: advance their seq so the feed delivers it.
UPDATE cloud_products SET seq=m.base+r.n
FROM (SELECT p.shop_id,p.id,ROW_NUMBER() OVER (PARTITION BY p.shop_id ORDER BY p.id) AS n FROM cloud_products p
    WHERE EXISTS(SELECT 1 FROM repair_0003_orders x JOIN cloud_order_lines l ON l.shop_id=x.shop_id AND l.order_id=x.id
      WHERE x.shop_id=p.shop_id AND l.product_id=p.id)) AS r,
  (SELECT s.shop_id,MAX(COALESCE((SELECT MAX(seq) FROM cloud_orders WHERE shop_id=s.shop_id),0),
    COALESCE((SELECT MAX(seq) FROM cloud_products WHERE shop_id=s.shop_id),0)) AS base
   FROM (SELECT DISTINCT shop_id FROM repair_0003_orders) AS s) AS m
WHERE cloud_products.shop_id=r.shop_id AND cloud_products.id=r.id AND m.shop_id=r.shop_id;
DROP TABLE repair_0003_orders;
