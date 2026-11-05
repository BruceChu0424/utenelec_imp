-- V1033 的数量采用触发器(trg_00_document_quantity_adoption，按触发器名先于
-- trg_*_gift_input_facts 执行)在 qty 变化时重写派生列 charged_base_qty/gift_base_qty，
-- V1047 已把 fn_is_proven_procurement_qty_revision 的「已核实改量」白名单扩展到这些
-- 采用列，但 V844 的 fn_guard_purchase_gift_input_facts 仍把重写后的采用列当成
-- 「已过账输入事实被篡改」整行拒绝——财务已批准订单的合法改量(changeQty)因此被
-- 'posted charged/free input and base facts are immutable' 误伤。
-- 本迁移只给该守卫的明细分支补上同一白名单：仅当本事务内存在匹配的
-- procurement_order_source_revisions 证据行、且除白名单列外其余输入事实
-- (quantity_semantics/gift_qty/gift_replacement_intent 等仍按原样冻结)未变时放行；
-- 任意独立篡改采用列或输入事实仍按原语义拒绝，守卫其余分支不变。
CREATE OR REPLACE FUNCTION fn_guard_purchase_gift_input_facts()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_old JSONB:=to_jsonb(OLD);v_new JSONB:=to_jsonb(NEW);v_status SMALLINT;
    v_header_table TEXT;v_parent_column TEXT;
BEGIN
    IF TG_TABLE_NAME IN ('purchase_requests','purchase_orders','purchase_receipts','purchase_returns') THEN
        IF OLD.status<>0 AND NEW.quantity_semantics IS DISTINCT FROM OLD.quantity_semantics THEN
            RAISE EXCEPTION 'posted purchase quantity semantics are immutable' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME='procurement_inspection_items' THEN
        IF NEW.quantity_tranche IS DISTINCT FROM OLD.quantity_tranche THEN
            RAISE EXCEPTION 'received inspection quantity tranche is immutable' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME='purchase_order_item_sources' THEN
        SELECT h.status INTO v_status FROM purchase_order_items i JOIN purchase_orders h ON h.id=i.order_id WHERE i.id=OLD.order_item_id;
        IF v_status<>0 AND NEW.allocated_gift_qty IS DISTINCT FROM OLD.allocated_gift_qty THEN
            RAISE EXCEPTION 'posted gift source allocation is immutable' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    v_header_table:=CASE TG_TABLE_NAME WHEN 'purchase_request_items' THEN 'purchase_requests'
        WHEN 'purchase_order_items' THEN 'purchase_orders' WHEN 'purchase_receipt_items' THEN 'purchase_receipts'
        WHEN 'purchase_return_items' THEN 'purchase_returns' END;
    v_parent_column:=CASE TG_TABLE_NAME WHEN 'purchase_request_items' THEN 'request_id'
        WHEN 'purchase_order_items' THEN 'order_id' WHEN 'purchase_receipt_items' THEN 'receipt_id'
        WHEN 'purchase_return_items' THEN 'return_id' END;
    EXECUTE format('SELECT status FROM %I WHERE id=$1',v_header_table) INTO v_status USING (v_old->>v_parent_column)::UUID;
    IF v_status<>0 AND (v_new->'quantity_semantics',v_new->'gift_qty',v_new->'charged_base_qty',v_new->'gift_base_qty',v_new->'gift_replacement_intent')
            IS DISTINCT FROM (v_old->'quantity_semantics',v_old->'gift_qty',v_old->'charged_base_qty',v_old->'gift_base_qty',v_old->'gift_replacement_intent')
            AND NOT fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,v_old,v_new) THEN
        RAISE EXCEPTION 'posted charged/free input and base facts are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
