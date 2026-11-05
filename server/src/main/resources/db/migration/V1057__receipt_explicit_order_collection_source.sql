-- Ordinary collections select a shipment AR. An optional explicit order constrains attribution inside that AR; NULL never means cross-batch allocation.
ALTER TABLE finance_receipt_lines
    ADD COLUMN requested_sales_order_id uuid REFERENCES sales_orders(id);
ALTER TABLE finance_receipt_lines ADD COLUMN applied_source_doc_type varchar(64),ADD COLUMN applied_source_doc_id uuid,ADD COLUMN applied_source_doc_no text;
ALTER TABLE finance_receipts ADD COLUMN order_selection_version smallint NOT NULL DEFAULT 0;
ALTER TABLE finance_receipts ADD CONSTRAINT receipt_new_order_prepayment_source
    CHECK(order_selection_version=0 OR receipt_kind<>'CUSTOMER_PREPAYMENT' OR sales_order_id IS NOT NULL);
COMMENT ON COLUMN finance_receipt_lines.requested_sales_order_id IS
    '显式选定的本次收款订货单；NULL保留历史FIFO来源，不追填伪造订单';

CREATE FUNCTION fn_guard_receipt_requested_order_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='finance_receipts' THEN
        IF OLD.order_selection_version IS DISTINCT FROM NEW.order_selection_version THEN
            RAISE EXCEPTION '收款订单来源合同版本不可降级或改写' USING ERRCODE='23514',CONSTRAINT='receipt_order_selection_version_immutable';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.requested_sales_order_id IS DISTINCT FROM NEW.requested_sales_order_id
       AND EXISTS(SELECT 1 FROM finance_receipts WHERE id=OLD.receipt_id AND status<>0) THEN
        RAISE EXCEPTION '已审核或反转收款明细的订货单来源不可修改'
            USING ERRCODE='23514',CONSTRAINT='receipt_requested_order_immutable';
    END IF;
    RETURN NEW;
END $$;
CREATE FUNCTION fn_guard_receipt_applied_source_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.applied_source_doc_type IS DISTINCT FROM OLD.applied_source_doc_type
        OR NEW.applied_source_doc_id IS DISTINCT FROM OLD.applied_source_doc_id
        OR NEW.applied_source_doc_no IS DISTINCT FROM OLD.applied_source_doc_no)
       AND EXISTS(SELECT 1 FROM finance_receipts WHERE id=OLD.receipt_id AND status<>0) THEN
        RAISE EXCEPTION '已审核收款的原始出货来源快照不可修改'
            USING ERRCODE='23514',CONSTRAINT='receipt_applied_source_snapshot_immutable';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_receipt_applied_source_snapshot BEFORE UPDATE OF applied_source_doc_type,applied_source_doc_id,applied_source_doc_no
    ON finance_receipt_lines FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_applied_source_snapshot();
CREATE TRIGGER trg_guard_receipt_requested_order_immutable
    BEFORE UPDATE OF requested_sales_order_id ON finance_receipt_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_requested_order_immutable();
CREATE TRIGGER trg_guard_receipt_order_selection_version
    BEFORE UPDATE OF order_selection_version ON finance_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_requested_order_immutable();

CREATE FUNCTION fn_guard_receipt_requested_order_attribution() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_line uuid;
BEGIN
    IF TG_TABLE_NAME='finance_receipt_lines' THEN target_line:=NEW.id;
    ELSE target_line:=NEW.receipt_line_id; END IF;
    IF EXISTS(
        SELECT 1 FROM finance_receipt_lines line
        JOIN finance_receipts receipt ON receipt.id=line.receipt_id
        WHERE line.id=target_line AND line.requested_sales_order_id IS NOT NULL AND (NOT EXISTS(
                SELECT 1 FROM ar_ap_source_refs ref JOIN sales_orders orders ON orders.id=ref.source_id
                WHERE ref.ledger_id=line.applied_ledger_id AND ref.source_type='SALES_ORDER'
                  AND orders.id=line.requested_sales_order_id AND orders.client_id=receipt.client_id
                  AND orders.currency_id=line.currency_id)
               OR EXISTS(SELECT 1 FROM finance_receipt_source_allocations allocation
                    WHERE allocation.receipt_line_id=line.id
                      AND allocation.sales_order_id IS DISTINCT FROM line.requested_sales_order_id))) THEN
        RAISE EXCEPTION '收款分配必须准确归属于本次明确选择的订货单'
            USING ERRCODE='23514',CONSTRAINT='receipt_requested_order_attribution';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_receipt_requested_order_from_line
    AFTER INSERT OR UPDATE ON finance_receipt_lines DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_requested_order_attribution();
CREATE CONSTRAINT TRIGGER trg_receipt_requested_order_from_allocation
    AFTER INSERT OR UPDATE ON finance_receipt_source_allocations DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_requested_order_attribution();

-- Fulfilment closure is not financial settlement. A normally completed order
-- may retain an actual deposit/overpayment without reopening its goods chain.
-- Preserve V499's unchanged-identity historical reversal exception and recheck
-- the current order on a new registration, changed identity or new approval.
CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_order()
RETURNS TRIGGER AS $v1057_order_financial$
DECLARE
    v_client UUID; v_currency UUID; v_status SMALLINT; v_deleted BOOLEAN;
    v_stopped BOOLEAN;
BEGIN
    IF NEW.sales_order_id IS NULL THEN RETURN NEW; END IF;
    IF TG_OP='UPDATE' THEN
        IF NEW.sales_order_id IS NOT DISTINCT FROM OLD.sales_order_id
           AND NEW.client_id IS NOT DISTINCT FROM OLD.client_id
           AND NEW.currency_id IS NOT DISTINCT FROM OLD.currency_id
           AND NEW.receipt_kind IS NOT DISTINCT FROM OLD.receipt_kind
           AND NOT (NEW.status=1 AND OLD.status IS DISTINCT FROM 1) THEN
            RETURN NEW;
        END IF;
    END IF;
    SELECT client_id,currency_id,status,is_deleted,is_stopped
      INTO v_client,v_currency,v_status,v_deleted,v_stopped
    FROM sales_orders WHERE id=NEW.sales_order_id;
    IF v_client IS NULL OR COALESCE(v_deleted,FALSE) OR v_status IS DISTINCT FROM 1
       OR COALESCE(v_stopped,FALSE)
       OR v_client IS DISTINCT FROM NEW.client_id OR v_currency IS DISTINCT FROM NEW.currency_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='bound customer prepayment requires an active approved, non-stopped sales order with the same client and currency',
            CONSTRAINT='finance_receipts_sales_order_identity_guard';
    END IF;
    RETURN NEW;
END;
$v1057_order_financial$ LANGUAGE plpgsql;
