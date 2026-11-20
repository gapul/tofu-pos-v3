-- Immutable product snapshots: a new/empty phone cannot erase a previous backup.
CREATE TABLE cloud_catalogs (
  shop_id TEXT NOT NULL,
  id TEXT NOT NULL,
  payload TEXT NOT NULL,
  product_count INTEGER NOT NULL,
  received_at TEXT NOT NULL,
  PRIMARY KEY(shop_id,id)
);
CREATE INDEX catalog_history ON cloud_catalogs(shop_id,received_at DESC,id DESC);
