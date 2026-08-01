-- V188: immutable warehouse execution evidence for sales shipments.
--
-- V187 stores the current work state on the shipment header.  This ledger
-- preserves every transition and, critically, the exception/recovery reason.
-- Historical rows are not backfilled: doing so would invent facts that were
-- never captured.

CREATE TABLE sales_shipment_warehouse_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id UUID NOT NULL
        REFERENCES sales_shipments(id) ON DELETE RESTRICT,
    from_status TEXT,
    to_status TEXT NOT NULL,
    reason TEXT,
    actor_employee_id UUID,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT sales_shipment_warehouse_events_from_status_chk CHECK (
        from_status IS NULL OR from_status IN (
            'LEGACY_PENDING',
            'PENDING_PICK',
            'PICKING',
            'PICKED',
            'EXCEPTION',
            'SHIPPED',
            'CANCELLED',
            'REVERSED'
        )
    ),
    CONSTRAINT sales_shipment_warehouse_events_to_status_chk CHECK (
        to_status IN (
            'LEGACY_PENDING',
            'PENDING_PICK',
            'PICKING',
            'PICKED',
            'EXCEPTION',
            'SHIPPED',
            'CANCELLED',
            'REVERSED'
        )
    ),
    CONSTRAINT sales_shipment_warehouse_events_reason_chk CHECK (
        (to_status <> 'EXCEPTION'
            AND NOT (from_status = 'EXCEPTION'
                AND to_status = 'PENDING_PICK'))
        OR NULLIF(btrim(reason), '') IS NOT NULL
    )
);

CREATE INDEX idx_sales_shipment_warehouse_events_timeline
    ON sales_shipment_warehouse_events(
        shipment_id, occurred_at, id);

CREATE OR REPLACE FUNCTION
    fn_reject_sales_shipment_warehouse_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE =
            'sales_shipment_warehouse_events is append-only',
        DETAIL =
            'Warehouse transition evidence cannot be updated or deleted.',
        HINT =
            'Append the next state transition; never rewrite history.',
        CONSTRAINT =
            'sales_shipment_warehouse_events_append_only_guard';
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_00_reject_sales_shipment_warehouse_event_mutation
    BEFORE UPDATE OR DELETE
    ON sales_shipment_warehouse_events
    FOR EACH ROW
    EXECUTE FUNCTION
        fn_reject_sales_shipment_warehouse_event_mutation();

ALTER TABLE sales_shipment_warehouse_events
    ENABLE ALWAYS TRIGGER
        trg_00_reject_sales_shipment_warehouse_event_mutation;

CREATE TRIGGER trg_audit_sales_shipment_warehouse_events
    AFTER INSERT OR UPDATE OR DELETE
    ON sales_shipment_warehouse_events
    FOR EACH ROW
    EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE sales_shipment_warehouse_events IS
    '销售出货仓库状态追加式事件；异常及恢复原因永久保留，不回填历史假事实';
COMMENT ON COLUMN sales_shipment_warehouse_events.reason IS
    '异常原因、恢复处理说明或受控兼容说明；EXCEPTION 与恢复待拣货时必填';
