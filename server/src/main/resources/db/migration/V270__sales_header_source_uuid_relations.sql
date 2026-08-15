-- Sales document source identity belongs to immutable UUID relations.
-- source_doc_no remains a display/audit snapshot only. Existing rows are
-- intentionally NOT backfilled from free-form numbers because legacy values
-- can contain concatenated or reused document numbers.

ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS source_order_id UUID;

ALTER TABLE sales_other_shipments
    ADD COLUMN IF NOT EXISTS source_order_id UUID;

ALTER TABLE sales_returns
    ADD COLUMN IF NOT EXISTS source_shipment_id UUID;

ALTER TABLE sales_shipments
    ADD CONSTRAINT fk_sales_shipments_source_order
    FOREIGN KEY (source_order_id) REFERENCES sales_orders(id)
    ON DELETE RESTRICT NOT VALID;

ALTER TABLE sales_other_shipments
    ADD CONSTRAINT fk_sales_other_shipments_source_order
    FOREIGN KEY (source_order_id) REFERENCES sales_orders(id)
    ON DELETE RESTRICT NOT VALID;

ALTER TABLE sales_returns
    ADD CONSTRAINT fk_sales_returns_source_shipment
    FOREIGN KEY (source_shipment_id) REFERENCES sales_shipments(id)
    ON DELETE RESTRICT NOT VALID;

ALTER TABLE sales_shipments
    VALIDATE CONSTRAINT fk_sales_shipments_source_order;
ALTER TABLE sales_other_shipments
    VALIDATE CONSTRAINT fk_sales_other_shipments_source_order;
ALTER TABLE sales_returns
    VALIDATE CONSTRAINT fk_sales_returns_source_shipment;

CREATE INDEX IF NOT EXISTS idx_sales_shipments_source_order
    ON sales_shipments(source_order_id)
    WHERE source_order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sales_other_shipments_source_order
    ON sales_other_shipments(source_order_id)
    WHERE source_order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sales_returns_source_shipment
    ON sales_returns(source_shipment_id)
    WHERE source_shipment_id IS NOT NULL;

COMMENT ON COLUMN sales_shipments.source_order_id IS
    'Source sales-order UUID derived from order_item_id; authoritative relation.';
COMMENT ON COLUMN sales_other_shipments.source_order_id IS
    'Optional source sales-order UUID derived from order_item_id; authoritative relation.';
COMMENT ON COLUMN sales_returns.source_shipment_id IS
    'Optional source sales-shipment UUID derived from out_item_id; authoritative relation.';
COMMENT ON COLUMN sales_shipments.source_doc_no IS
    'Source number snapshot only; never used to resolve identity or authorization.';
COMMENT ON COLUMN sales_other_shipments.source_doc_no IS
    'Source number snapshot only; never used to resolve identity or authorization.';
COMMENT ON COLUMN sales_returns.source_doc_no IS
    'Source number snapshot only; never used to resolve identity or authorization.';
