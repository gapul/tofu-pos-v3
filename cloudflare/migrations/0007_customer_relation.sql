-- Fourth customer axis (acquaintance/relative/member/tofu_fan/general). Additive only;
-- existing rows are filled from the payload (idempotent: only empty columns with a payload value).
ALTER TABLE cloud_orders ADD COLUMN customer_relation TEXT;
UPDATE cloud_orders SET customer_relation=json_extract(payload,'$.customer_relation')
WHERE customer_relation IS NULL AND json_extract(payload,'$.customer_relation') IS NOT NULL;
