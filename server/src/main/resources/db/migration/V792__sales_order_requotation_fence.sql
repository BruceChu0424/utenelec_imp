-- Forward-only evidence: a safely terminated order may begin an independent negotiation.
-- Do not infer replacements for historical orders. The first explicit action records the fact.
ALTER TABLE sales_orders
    ADD COLUMN requoted_to_id UUID REFERENCES sales_quotes(id) ON DELETE RESTRICT,
    ADD COLUMN requoted_at TIMESTAMPTZ,
    ADD COLUMN requoted_by UUID,
    ADD CONSTRAINT ck_sales_order_requotation_evidence CHECK (
        (requoted_to_id IS NULL AND requoted_at IS NULL AND requoted_by IS NULL)
        OR (requoted_to_id IS NOT NULL AND requoted_at IS NOT NULL AND requoted_by IS NOT NULL));

CREATE INDEX idx_sales_orders_requoted_to ON sales_orders(requoted_to_id)
    WHERE requoted_to_id IS NOT NULL;

CREATE FUNCTION fn_sales_order_requotation_fence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- The existing authenticated maintenance reset remains the only exceptional cleanup capability.
    IF public.fn_business_test_reset_active() THEN RETURN NEW; END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.requoted_to_id IS NOT NULL THEN
            RAISE EXCEPTION 'Requotation evidence must be appended to an existing terminated order'
                USING ERRCODE='55000';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.requoted_to_id IS NOT NULL THEN
        IF (to_jsonb(NEW) - ARRAY['version','updated_at','updated_by'])
                IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['version','updated_at','updated_by']) THEN
            RAISE EXCEPTION 'Requoted order is permanently read-only; its original and replacement evidence must be retained'
                USING ERRCODE='55000';
        END IF;
    ELSIF NEW.requoted_to_id IS NOT NULL THEN
        IF NOT (OLD.is_deleted OR OLD.status = -1 OR (OLD.status = 1 AND OLD.is_stopped))
                OR (to_jsonb(NEW) - ARRAY['requoted_to_id','requoted_at','requoted_by','version','updated_at','updated_by'])
                    IS DISTINCT FROM
                   (to_jsonb(OLD) - ARRAY['requoted_to_id','requoted_at','requoted_by','version','updated_at','updated_by'])
                OR NEW.source_quote_id IS DISTINCT FROM OLD.source_quote_id
                OR NOT EXISTS (SELECT 1 FROM sales_quotes replacement
                               WHERE replacement.id = NEW.requoted_to_id
                                 AND replacement.origin_quote_id = OLD.source_quote_id) THEN
            RAISE EXCEPTION 'Only an already terminated source order may record its linked requotation'
                USING ERRCODE='55000';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sales_order_requotation_fence BEFORE INSERT OR UPDATE ON sales_orders
    FOR EACH ROW EXECUTE FUNCTION fn_sales_order_requotation_fence();
ALTER TABLE sales_orders ENABLE ALWAYS TRIGGER trg_sales_order_requotation_fence;

COMMENT ON COLUMN sales_orders.requoted_to_id IS
    'First explicitly linked renegotiation quote; immutable even if that quote is later cancelled or soft-deleted. This order cannot resume.';
