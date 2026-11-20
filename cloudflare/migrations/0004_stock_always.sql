-- Revision 2: every product tracks stock (negative allowed); stop_at_zero opts a product into "sold out at 0".
-- Additive only: no rows are deleted and no existing column changes meaning for the deployed Worker.
ALTER TABLE cloud_products ADD COLUMN stop_at_zero INTEGER NOT NULL DEFAULT 0;
-- Formerly untracked products now report a stock: give them a fresh feed seq (after the shop's maximum) so devices receive it.
UPDATE cloud_products SET track_stock=1, seq=m.base+r.n
FROM (SELECT shop_id,id,ROW_NUMBER() OVER (PARTITION BY shop_id ORDER BY id) AS n FROM cloud_products WHERE track_stock<>1) AS r,
  (SELECT s.shop_id,MAX(COALESCE((SELECT MAX(seq) FROM cloud_orders WHERE shop_id=s.shop_id),0),
    COALESCE((SELECT MAX(seq) FROM cloud_products WHERE shop_id=s.shop_id),0)) AS base
   FROM (SELECT DISTINCT shop_id FROM cloud_products WHERE track_stock<>1) AS s) AS m
WHERE cloud_products.shop_id=r.shop_id AND cloud_products.id=r.id AND m.shop_id=r.shop_id;
