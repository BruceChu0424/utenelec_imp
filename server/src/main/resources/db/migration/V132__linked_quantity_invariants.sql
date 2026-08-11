-- Protect cumulative source-document quantities against concurrent approval.
--
-- Historical rows are intentionally not rewritten here: the legacy system
-- contains accepted over-delivery records. These guards allow a corrective
-- decrease on such rows, but reject any new increase beyond the source limit.
-- PostgreSQL serializes concurrent UPDATEs on the same row, so the trigger sees
-- the latest committed counter and closes the check-then-update race.

CREATE OR REPLACE FUNCTION fn_guard_processed_quantity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_row       jsonb := to_jsonb(NEW);
    v_old_row       jsonb;
    v_counter_name  text := TG_ARGV[0];
    v_base_name     text := TG_ARGV[1];
    v_allow_name    text := NULLIF(TG_ARGV[2], '');
    v_new_counter   numeric;
    v_old_counter   numeric;
    v_capacity      numeric;
BEGIN
    v_old_row := CASE WHEN TG_OP = 'INSERT' THEN '{}'::jsonb ELSE to_jsonb(OLD) END;
    v_new_counter := COALESCE((v_new_row ->> v_counter_name)::numeric, 0);
    v_old_counter := COALESCE((v_old_row ->> v_counter_name)::numeric, 0);
    v_capacity := COALESCE((v_new_row ->> v_base_name)::numeric, 0)
        + CASE
            WHEN v_allow_name IS NULL THEN 0
            ELSE COALESCE((v_new_row ->> v_allow_name)::numeric, 0)
          END;

    IF v_new_counter < 0 THEN
        RAISE EXCEPTION '% cannot be negative', v_counter_name
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;

    IF v_new_counter > v_old_counter AND v_new_counter > v_capacity THEN
        RAISE EXCEPTION '% exceeds remaining source quantity', v_counter_name
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_return_allowance()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_row        jsonb := to_jsonb(NEW);
    v_old_row        jsonb;
    v_return_name    text := TG_ARGV[0];
    v_processed_name text := TG_ARGV[1];
    v_base_name      text := NULLIF(TG_ARGV[2], '');
    v_new_returned   numeric;
    v_old_returned   numeric;
    v_processed      numeric;
    v_base           numeric;
BEGIN
    v_old_row := CASE WHEN TG_OP = 'INSERT' THEN '{}'::jsonb ELSE to_jsonb(OLD) END;
    v_new_returned := COALESCE((v_new_row ->> v_return_name)::numeric, 0);
    v_old_returned := COALESCE((v_old_row ->> v_return_name)::numeric, 0);
    v_processed := COALESCE((v_new_row ->> v_processed_name)::numeric, 0);
    v_base := CASE
        WHEN v_base_name IS NULL THEN 0
        ELSE COALESCE((v_new_row ->> v_base_name)::numeric, 0)
    END;

    IF v_new_returned < 0 THEN
        RAISE EXCEPTION '% cannot be negative', v_return_name
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;

    IF v_new_returned > v_old_returned AND v_new_returned > v_processed THEN
        RAISE EXCEPTION '% exceeds processed quantity', v_return_name
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;

    -- Reversing a return must not make a previously reprocessed source invalid.
    IF v_base_name IS NOT NULL
       AND v_new_returned < v_old_returned
       AND v_processed > v_base + v_new_returned THEN
        RAISE EXCEPTION 'return reversal would exceed source quantity'
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_combined_quantities()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_row       jsonb := to_jsonb(NEW);
    v_old_row       jsonb;
    v_first_name    text := TG_ARGV[0];
    v_second_name   text := TG_ARGV[1];
    v_capacity_name text := TG_ARGV[2];
    v_new_first     numeric;
    v_new_second    numeric;
    v_old_total     numeric;
    v_new_total     numeric;
    v_capacity      numeric;
BEGIN
    v_old_row := CASE WHEN TG_OP = 'INSERT' THEN '{}'::jsonb ELSE to_jsonb(OLD) END;
    v_new_first := COALESCE((v_new_row ->> v_first_name)::numeric, 0);
    v_new_second := COALESCE((v_new_row ->> v_second_name)::numeric, 0);
    v_old_total := COALESCE((v_old_row ->> v_first_name)::numeric, 0)
        + COALESCE((v_old_row ->> v_second_name)::numeric, 0);
    v_new_total := v_new_first + v_new_second;
    v_capacity := COALESCE((v_new_row ->> v_capacity_name)::numeric, 0);

    IF v_new_first < 0 OR v_new_second < 0 THEN
        RAISE EXCEPTION 'linked quantities cannot be negative'
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;

    IF v_new_total > v_old_total AND v_new_total > v_capacity THEN
        RAISE EXCEPTION 'combined linked quantities exceed source quantity'
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;

    RETURN NEW;
END;
$$;

-- Purchase: order -> receipt -> return.
CREATE TRIGGER trg_purchase_order_received_guard
    BEFORE INSERT OR UPDATE OF received_qty ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'received_qty', 'qty', 'returned_qty');

CREATE TRIGGER trg_purchase_order_returned_guard
    BEFORE INSERT OR UPDATE OF returned_qty ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_return_allowance(
        'returned_qty', 'received_qty', 'qty');

CREATE TRIGGER trg_purchase_receipt_returned_guard
    BEFORE INSERT OR UPDATE OF returned_qty ON purchase_receipt_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'returned_qty', 'qty', '');

-- Sales: order -> shipment -> return.
CREATE TRIGGER trg_sales_order_shipped_guard
    BEFORE INSERT OR UPDATE OF shipped_qty ON sales_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'shipped_qty', 'qty', 'returned_qty');

CREATE TRIGGER trg_sales_order_returned_guard
    BEFORE INSERT OR UPDATE OF returned_qty ON sales_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_return_allowance(
        'returned_qty', 'shipped_qty', 'qty');

CREATE TRIGGER trg_sales_shipment_returned_guard
    BEFORE INSERT OR UPDATE OF returned_qty ON sales_shipment_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'returned_qty', 'qty', '');

-- Subcontract: order -> receipt/issue -> product/material return or waste.
CREATE TRIGGER trg_subcontract_order_received_guard
    BEFORE INSERT OR UPDATE OF received_qty ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'received_qty', 'qty', 'returned_qty');

CREATE TRIGGER trg_subcontract_order_returned_guard
    BEFORE INSERT OR UPDATE OF returned_qty ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_return_allowance(
        'returned_qty', 'received_qty', 'qty');

CREATE TRIGGER trg_subcontract_order_issued_guard
    BEFORE INSERT OR UPDATE OF issued_qty ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'issued_qty', 'qty', 'material_returned_qty');

CREATE TRIGGER trg_subcontract_order_material_returned_guard
    BEFORE INSERT OR UPDATE OF material_returned_qty ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_return_allowance(
        'material_returned_qty', 'issued_qty', 'qty');

CREATE TRIGGER trg_subcontract_receipt_returned_guard
    BEFORE INSERT OR UPDATE OF returned_qty ON subcontract_receipt_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'returned_qty', 'qty', '');

CREATE TRIGGER trg_subcontract_issue_disposition_guard
    BEFORE INSERT OR UPDATE OF returned_qty, wasted_qty
    ON subcontract_material_issue_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_combined_quantities(
        'returned_qty', 'wasted_qty', 'qty');
