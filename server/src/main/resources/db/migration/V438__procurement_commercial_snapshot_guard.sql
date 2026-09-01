-- V438: purchase/subcontract orders must freeze complete commercial facts before finance review.

CREATE OR REPLACE FUNCTION fn_guard_procurement_finance_commercial_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_currency UUID;
    v_rate NUMERIC;
    v_tax NUMERIC;
    v_settlement UUID;
    v_total_original NUMERIC;
    v_total_local NUMERIC;
    v_item_original NUMERIC;
    v_item_local NUMERIC;
    v_item_count BIGINT;
    v_invalid_items BIGINT;
    v_order_found BOOLEAN:=FALSE;
    v_currency_active BOOLEAN;
    v_settlement_active BOOLEAN;
BEGIN
    IF NEW.status NOT IN ('PENDING', 'APPROVED') THEN RETURN NEW; END IF;
    IF NEW.order_type='PURCHASE' THEN
        SELECT currency_id,exchange_rate,tax_rate,settlement_method_id,
               total_original,total_local
          INTO v_currency,v_rate,v_tax,v_settlement,v_total_original,v_total_local
          FROM purchase_orders
         WHERE id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         FOR UPDATE;
        v_order_found:=FOUND;
        PERFORM 1 FROM purchase_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         ORDER BY id FOR UPDATE;
        SELECT COUNT(*),COALESCE(SUM(amount_original),0),COALESCE(SUM(amount_local),0),
               COUNT(*) FILTER(WHERE qty IS NULL OR qty<=0 OR price IS NULL OR price<0
                 OR amount_original IS NULL OR amount_original<0
                 OR amount_local IS NULL OR amount_local<0
                 OR amount_original<>ROUND(qty*price,4)
                 OR amount_local<>ROUND(amount_original*v_rate,4))
          INTO v_item_count,v_item_original,v_item_local,v_invalid_items
          FROM purchase_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE;
    ELSIF NEW.order_type='SUBCONTRACT' THEN
        SELECT currency_id,exchange_rate,tax_rate,settlement_method_id,
               total_original,total_local
          INTO v_currency,v_rate,v_tax,v_settlement,v_total_original,v_total_local
          FROM subcontract_orders
         WHERE id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         FOR UPDATE;
        v_order_found:=FOUND;
        PERFORM 1 FROM subcontract_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         ORDER BY id FOR UPDATE;
        SELECT COUNT(*),COALESCE(SUM(amount_original),0),COALESCE(SUM(amount_local),0),
               COUNT(*) FILTER(WHERE qty IS NULL OR qty<=0 OR price IS NULL OR price<0
                 OR amount_original IS NULL OR amount_original<0
                 OR amount_local IS NULL OR amount_local<0
                 OR amount_original<>ROUND(qty*price,4)
                 OR amount_local<>ROUND(amount_original*v_rate,4))
          INTO v_item_count,v_item_original,v_item_local,v_invalid_items
          FROM subcontract_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE;
    ELSE
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='unsupported procurement finance order type',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    IF NOT v_order_found THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='procurement finance source order is missing',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    SELECT EXISTS(SELECT 1 FROM currencies
        WHERE id=v_currency AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE)
      INTO v_currency_active;
    SELECT EXISTS(SELECT 1 FROM settlement_methods
        WHERE id=v_settlement AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE)
      INTO v_settlement_active;
    IF v_currency IS NULL OR NOT COALESCE(v_currency_active,FALSE)
       OR v_rate IS NULL OR v_rate<=0
       OR v_tax IS NULL OR v_tax<0 OR v_tax>100
       OR v_settlement IS NULL OR NOT COALESCE(v_settlement_active,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance review requires active currency, positive rate, 0..100 tax and active settlement method',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    IF v_item_count=0 OR v_invalid_items<>0
       OR v_total_original IS DISTINCT FROM v_item_original
       OR v_total_local IS DISTINCT FROM v_item_local
       OR NEW.amount_snapshot IS DISTINCT FROM v_total_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='procurement finance snapshot amount or locked item set is incomplete/inconsistent',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_procurement_finance_commercial_snapshot
    ON procurement_order_approval_cases;
CREATE TRIGGER trg_guard_procurement_finance_commercial_snapshot
    BEFORE INSERT OR UPDATE OF status,order_type,order_id
    ON procurement_order_approval_cases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_finance_commercial_snapshot();
ALTER TABLE procurement_order_approval_cases
    ENABLE ALWAYS TRIGGER trg_guard_procurement_finance_commercial_snapshot;

CREATE OR REPLACE FUNCTION procurement_order_commercial_locked(
    p_order_type TEXT,p_order_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS(
        SELECT 1 FROM procurement_order_approval_cases approval
        WHERE approval.order_type=p_order_type
          AND approval.order_id=p_order_id
          AND approval.status IN('PENDING','APPROVED'))
$$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_order_header_commercial_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_type TEXT:=TG_ARGV[0];
BEGIN
    IF procurement_order_commercial_locked(v_type,OLD.id)
       AND (NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
        OR NEW.currency_id IS DISTINCT FROM OLD.currency_id
        OR NEW.exchange_rate IS DISTINCT FROM OLD.exchange_rate
        OR NEW.tax_rate IS DISTINCT FROM OLD.tax_rate
        OR NEW.settlement_method_id IS DISTINCT FROM OLD.settlement_method_id
        OR NEW.total_original IS DISTINCT FROM OLD.total_original
        OR NEW.total_local IS DISTINCT FROM OLD.total_local) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed procurement order commercial header is frozen',
            CONSTRAINT='procurement_order_commercial_header_freeze_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_order_item_commercial_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_type TEXT:=TG_ARGV[0];
    v_order_id UUID:=CASE WHEN TG_OP='DELETE' THEN OLD.order_id ELSE NEW.order_id END;
BEGIN
    IF NOT procurement_order_commercial_locked(v_type,v_order_id)
       AND (TG_OP<>'UPDATE'
            OR NOT procurement_order_commercial_locked(v_type,OLD.order_id)) THEN
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF TG_OP IN('INSERT','DELETE') THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed procurement order items cannot be inserted or deleted',
            CONSTRAINT='procurement_order_commercial_item_freeze_guard';
    END IF;
    IF NEW.order_id IS DISTINCT FROM OLD.order_id
       OR NEW.bill_no IS DISTINCT FROM OLD.bill_no
       OR NEW.bill_date IS DISTINCT FROM OLD.bill_date
       OR NEW.line_no IS DISTINCT FROM OLD.line_no
       OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
       OR NEW.color_id IS DISTINCT FROM OLD.color_id
       OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
       OR NEW.unit_rate IS DISTINCT FROM OLD.unit_rate
       OR NEW.qty IS DISTINCT FROM OLD.qty
       OR NEW.price IS DISTINCT FROM OLD.price
       OR NEW.amount_original IS DISTINCT FROM OLD.amount_original
       OR NEW.amount_local IS DISTINCT FROM OLD.amount_local
       OR NEW.deliver_date IS DISTINCT FROM OLD.deliver_date
       OR NEW.weight IS DISTINCT FROM OLD.weight
       OR NEW.source_doc_no IS DISTINCT FROM OLD.source_doc_no
       OR NEW.remark IS DISTINCT FROM OLD.remark
       OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed procurement order item commercial facts are frozen',
            CONSTRAINT='procurement_order_commercial_item_freeze_guard';
    END IF;
    IF v_type='PURCHASE'
       AND NEW.request_item_id IS DISTINCT FROM OLD.request_item_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed purchase source item is frozen',
            CONSTRAINT='procurement_order_commercial_item_freeze_guard';
    END IF;
    IF v_type='SUBCONTRACT'
       AND NEW.application_item_id IS DISTINCT FROM OLD.application_item_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed subcontract source item is frozen',
            CONSTRAINT='procurement_order_commercial_item_freeze_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_purchase_order_commercial_header
    BEFORE UPDATE OF supplier_id,currency_id,exchange_rate,tax_rate,
        settlement_method_id,total_original,total_local
    ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_order_header_commercial_mutation('PURCHASE');
ALTER TABLE purchase_orders ENABLE ALWAYS TRIGGER trg_guard_purchase_order_commercial_header;

CREATE TRIGGER trg_guard_subcontract_order_commercial_header
    BEFORE UPDATE OF supplier_id,currency_id,exchange_rate,tax_rate,
        settlement_method_id,total_original,total_local
    ON subcontract_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_order_header_commercial_mutation('SUBCONTRACT');
ALTER TABLE subcontract_orders ENABLE ALWAYS TRIGGER trg_guard_subcontract_order_commercial_header;

CREATE TRIGGER trg_guard_purchase_order_commercial_items
    BEFORE INSERT OR DELETE OR UPDATE OF order_id,bill_no,bill_date,line_no,
        goods_id,color_id,unit_id,unit_rate,qty,price,amount_original,amount_local,
        request_item_id,deliver_date,weight,source_doc_no,remark,is_deleted
    ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_order_item_commercial_mutation('PURCHASE');
ALTER TABLE purchase_order_items ENABLE ALWAYS TRIGGER trg_guard_purchase_order_commercial_items;

CREATE TRIGGER trg_guard_subcontract_order_commercial_items
    BEFORE INSERT OR DELETE OR UPDATE OF order_id,bill_no,bill_date,line_no,
        goods_id,color_id,unit_id,unit_rate,qty,price,amount_original,amount_local,
        application_item_id,deliver_date,weight,source_doc_no,remark,is_deleted
    ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_order_item_commercial_mutation('SUBCONTRACT');
ALTER TABLE subcontract_order_items ENABLE ALWAYS TRIGGER trg_guard_subcontract_order_commercial_items;

COMMENT ON COLUMN subcontract_wastes.deduct_amount IS
    'V304 legacy deduction suggestion only. V330+ new waste approval never posts AP; finance decides a separate claim receivable, legal AP offset, cash or physical compensation.';
COMMENT ON COLUMN subcontract_wastes.deduct_posted IS
    'Historical V304 negative-AP marker retained only for readable/reversible old rows; new waste approvals keep FALSE.';
