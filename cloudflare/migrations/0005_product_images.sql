-- Product photos (stored in D1: the deploy token has no R2 access). Additive only.
-- Images are content-addressed by SHA-256 and immutable; products reference them by image_hash (null = no photo).
CREATE TABLE cloud_images (
  shop_id TEXT NOT NULL,
  hash TEXT NOT NULL,
  content_type TEXT NOT NULL,
  bytes BLOB NOT NULL,
  size INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(shop_id,hash)
);
ALTER TABLE cloud_products ADD COLUMN image_hash TEXT;
