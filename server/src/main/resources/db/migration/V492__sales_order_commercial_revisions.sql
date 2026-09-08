-- Commercial revisions preserve the original and revised facts without replacing
-- historical order identities. Applied migrations remain unchanged.
ALTER TABLE sales_orders ADD COLUMN finance_review_revision BIGINT NOT NULL DEFAULT 0
    CHECK (finance_review_revision >= 0);
UPDATE sales_orders orders
SET finance_review_revision = changes.change_count
FROM (SELECT order_id, count(*) AS change_count
      FROM sales_order_qty_change_logs GROUP BY order_id) changes
WHERE orders.id = changes.order_id;
CREATE TABLE sales_order_revision_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES sales_orders(id) ON DELETE RESTRICT,
    before_snapshot JSONB NOT NULL CHECK (jsonb_typeof(before_snapshot) = 'object'),
    after_snapshot JSONB NOT NULL CHECK (jsonb_typeof(after_snapshot) = 'object'),
    changed_by_employee_id UUID REFERENCES employees(id) ON DELETE RESTRICT,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK (before_snapshot <> after_snapshot)
);
CREATE INDEX idx_sales_order_revision_logs_order
    ON sales_order_revision_logs(order_id, changed_at DESC);

CREATE FUNCTION fn_sales_order_revision_logs_immutable() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Sales order commercial revision facts are append-only';
END;
$$;
CREATE TRIGGER trg_sales_order_revision_logs_immutable
    BEFORE UPDATE OR DELETE ON sales_order_revision_logs
    FOR EACH ROW EXECUTE FUNCTION fn_sales_order_revision_logs_immutable();
CREATE TRIGGER trg_sales_order_qty_change_logs_immutable
    BEFORE UPDATE OR DELETE ON sales_order_qty_change_logs
    FOR EACH ROW EXECUTE FUNCTION fn_sales_order_revision_logs_immutable();
CREATE TRIGGER trg_audit_sales_order_revision_logs
    AFTER INSERT OR UPDATE OR DELETE ON sales_order_revision_logs
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

DO $$
DECLARE definition TEXT; needle TEXT := '(''sales_order_qty_change_logs'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position(needle IN definition) = 0 THEN
        RAISE EXCEPTION 'V492 cannot extend business_data_reset policy safely';
    END IF;
    definition := replace(definition, needle,
        '(''sales_order_revision_logs'', ''CLEAR''), ' || needle);
    EXECUTE definition;
END;
$$;
