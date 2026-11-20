-- Third customer axis (solo/friends/family/couple/group) and per-device ticket numbers. Additive only;
-- existing rows are filled from the payload (idempotent: only empty columns with a payload value).
ALTER TABLE cloud_orders ADD COLUMN customer_group TEXT;
ALTER TABLE cloud_orders ADD COLUMN ticket_no TEXT;
UPDATE cloud_orders SET customer_group=json_extract(payload,'$.customer_group')
WHERE customer_group IS NULL AND json_extract(payload,'$.customer_group') IS NOT NULL;
UPDATE cloud_orders SET ticket_no=json_extract(payload,'$.ticket_no')
WHERE ticket_no IS NULL AND json_extract(payload,'$.ticket_no') IS NOT NULL;
