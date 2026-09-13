-- Current sales multi-select creates one atomic batch of physical-source drafts.
-- Keep identity on the existing audited/soft-deleted document, without a second registry.
ALTER TABLE sales_shipments
    ADD COLUMN batch_request_key VARCHAR(128),
    ADD COLUMN batch_request_hash VARCHAR(64),
    ADD COLUMN batch_position INTEGER,
    ADD CONSTRAINT ck_sales_shipment_batch_identity CHECK (
        (batch_request_key IS NULL AND batch_request_hash IS NULL AND batch_position IS NULL)
        OR (batch_request_key IS NOT NULL AND batch_request_hash IS NOT NULL AND batch_position IS NOT NULL
            AND batch_request_key=btrim(batch_request_key) AND length(batch_request_key) BETWEEN 8 AND 128
            AND batch_request_hash ~ '^[0-9a-f]{64}$' AND batch_position>0 AND created_by IS NOT NULL));
CREATE UNIQUE INDEX uq_sales_shipment_batch_position
    ON sales_shipments(created_by,batch_request_key,batch_position)
    WHERE batch_request_key IS NOT NULL;

CREATE FUNCTION fn_guard_sales_shipment_batch_identity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.batch_request_key IS NOT NULL OR NEW.batch_request_key IS NOT NULL)
       AND ROW(NEW.batch_request_key,NEW.batch_request_hash,NEW.batch_position,NEW.created_by)
       IS DISTINCT FROM ROW(OLD.batch_request_key,OLD.batch_request_hash,OLD.batch_position,OLD.created_by) THEN
        RAISE EXCEPTION 'sales shipment batch identity is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_sales_shipment_batch_identity
    BEFORE UPDATE ON sales_shipments FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_shipment_batch_identity();
ALTER TABLE sales_shipments ENABLE ALWAYS TRIGGER trg_guard_sales_shipment_batch_identity;

COMMENT ON COLUMN sales_shipments.batch_request_key IS
    '本次批量出货意图幂等键；由原制单人、请求指纹及批内序号确定，软删除也不得复用';
