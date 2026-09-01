-- V434: one atomic command may fully accept several production-generated
-- FINISHED_IN drafts.  Batch facts are append-only; individual confirmations
-- remain the quantity/inventory authority introduced by V338/V418.

CREATE TABLE production_finished_in_confirm_batches (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id         UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    actor_employee_id     UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    idempotency_key       VARCHAR(128) NOT NULL,
    request_hash          CHAR(64) NOT NULL,
    confirmed_count       INTEGER NOT NULL,
    response_snapshot     JSONB NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_finished_in_confirm_batch_actor_key_uk
        UNIQUE (actor_user_id, idempotency_key),
    CONSTRAINT production_finished_in_confirm_batch_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'),
    CONSTRAINT production_finished_in_confirm_batch_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT production_finished_in_confirm_batch_count_chk CHECK (
        confirmed_count BETWEEN 1 AND 50),
    CONSTRAINT production_finished_in_confirm_batch_snapshot_chk CHECK (
        jsonb_typeof(response_snapshot) = 'object')
);

CREATE TABLE production_finished_in_confirm_batch_items (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id              UUID NOT NULL
        REFERENCES production_finished_in_confirm_batches(id)
        ON DELETE RESTRICT,
    confirmation_id       UUID NOT NULL UNIQUE
        REFERENCES production_finished_in_confirmations(id)
        ON DELETE RESTRICT,
    stock_document_id     UUID NOT NULL UNIQUE
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    position              INTEGER NOT NULL,
    bill_no_snapshot      TEXT NOT NULL,
    status_snapshot       SMALLINT NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_finished_in_confirm_batch_item_position_chk CHECK (
        position BETWEEN 1 AND 50),
    CONSTRAINT production_finished_in_confirm_batch_item_bill_no_chk CHECK (
        NULLIF(btrim(bill_no_snapshot), '') IS NOT NULL),
    CONSTRAINT production_finished_in_confirm_batch_item_status_chk CHECK (
        status_snapshot = 1),
    CONSTRAINT production_finished_in_confirm_batch_item_batch_position_uk
        UNIQUE (batch_id, position),
    CONSTRAINT production_finished_in_confirm_batch_item_batch_document_uk
        UNIQUE (batch_id, stock_document_id)
);

CREATE INDEX idx_production_finished_in_confirm_batch_created
    ON production_finished_in_confirm_batches(created_at, id);
CREATE INDEX idx_production_finished_in_confirm_batch_items_batch
    ON production_finished_in_confirm_batch_items(batch_id, position);

CREATE TRIGGER trg_guard_production_finished_in_confirm_batches
    BEFORE UPDATE OR DELETE ON production_finished_in_confirm_batches
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_finished_in_confirmation();
CREATE TRIGGER trg_guard_production_finished_in_confirm_batch_items
    BEFORE UPDATE OR DELETE ON production_finished_in_confirm_batch_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_finished_in_confirmation();

CREATE TRIGGER trg_audit_production_finished_in_confirm_batches
    AFTER INSERT OR UPDATE OR DELETE
    ON production_finished_in_confirm_batches
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_finished_in_confirm_batch_items
    AFTER INSERT OR UPDATE OR DELETE
    ON production_finished_in_confirm_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE production_finished_in_confirm_batches IS
    '产成品最终点收原子批命令；actor+幂等键唯一，冻结请求哈希与结果快照';
COMMENT ON TABLE production_finished_in_confirm_batch_items IS
    '批命令内逐单冻结结果；关联既有逐单点收确认，不替代数量/库存权威';
