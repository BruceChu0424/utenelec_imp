-- V449：单人维护场景允许同一员工先后完成「品质放行」与「仓库入库确认」。
-- 应用层自 2026-09-01 起不再硬拒（详情接口保留 containsOwnRelease 标记供前端复核提示）；
-- 本迁移同步放开 V446 库级兜底中的同人限制（fn_validate_procurement_iqc_stock_in_item），
-- 其余身份/数量/金额/重量/库存投影校验原样保留。
CREATE OR REPLACE FUNCTION fn_validate_procurement_iqc_stock_in_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch procurement_iqc_stock_in_batches%ROWTYPE;
    v_event procurement_inspection_events%ROWTYPE;
    v_inspection procurement_inspection_items%ROWTYPE;
    v_movement stock_movements%ROWTYPE;
    v_confirmed NUMERIC(18,4);
    v_confirmed_amount NUMERIC(18,4);
    v_confirmed_weight NUMERIC(18,4);
    v_confirmed_has_weight BOOLEAN;
    v_expected_weight NUMERIC(18,4);
    v_event_confirmed NUMERIC(18,4);
    v_event_confirmed_amount NUMERIC(18,4);
    v_event_confirmed_weight NUMERIC(18,4);
    v_actor_employee_id UUID;
    v_actor_active BOOLEAN;
BEGIN
    SELECT * INTO v_batch
    FROM procurement_iqc_stock_in_batches
    WHERE id = NEW.batch_id;

    SELECT user_account.employee_id,
           user_account.status = 'active' AND user_account.is_deleted = FALSE
    INTO v_actor_employee_id, v_actor_active
    FROM users user_account
    WHERE user_account.id = v_batch.actor_user_id;

    SELECT * INTO v_event
    FROM procurement_inspection_events
    WHERE id = NEW.pass_event_id;

    SELECT * INTO v_inspection
    FROM procurement_inspection_items
    WHERE id = NEW.inspection_item_id;

    SELECT * INTO v_movement
    FROM stock_movements
    WHERE id = NEW.stock_movement_id;

    SELECT COALESCE(SUM(item.base_qty), 0),
           COALESCE(SUM(item.amount_local), 0),
           COALESCE(SUM(item.weight), 0),
           BOOL_OR(item.weight IS NOT NULL)
    INTO v_confirmed, v_confirmed_amount,
         v_confirmed_weight, v_confirmed_has_weight
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.inspection_item_id = NEW.inspection_item_id;

    v_expected_weight := CASE
        WHEN v_inspection.legacy_stocked_weight IS NULL
             AND COALESCE(v_confirmed_has_weight, FALSE) = FALSE
        THEN NULL
        ELSE COALESCE(v_inspection.legacy_stocked_weight, 0)
            + v_confirmed_weight
    END;

    SELECT COALESCE(SUM(item.base_qty), 0),
           COALESCE(SUM(item.amount_local), 0),
           COALESCE(SUM(item.weight), 0)
    INTO v_event_confirmed,
         v_event_confirmed_amount,
         v_event_confirmed_weight
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.pass_event_id = NEW.pass_event_id;

    IF v_batch.id IS NULL
       OR v_event.id IS NULL
       OR v_inspection.id IS NULL
       OR v_movement.id IS NULL
       OR v_event.action <> 'PASS'
       OR v_event.requires_warehouse_stock_in IS DISTINCT FROM TRUE
       OR v_event.base_qty <= 0
       OR NEW.expected_remaining_base_qty IS DISTINCT FROM
            v_event.base_qty - (v_event_confirmed - NEW.base_qty)
       OR v_event.released_amount_local IS NULL
       OR v_event_confirmed_amount IS DISTINCT FROM ROUND(
            v_event.released_amount_local * v_event_confirmed / v_event.base_qty,
            4)
       OR (
            v_event.released_weight IS NULL
            AND (NEW.weight IS NOT NULL OR NEW.weight_unit_id IS NOT NULL)
       )
       OR (
            v_event.released_weight IS NOT NULL
            AND (
                NEW.weight IS NULL
                OR NEW.weight_unit_id
                    IS DISTINCT FROM v_event.released_weight_unit_id
                OR v_event_confirmed_weight IS DISTINCT FROM ROUND(
                    v_event.released_weight
                        * v_event_confirmed / v_event.base_qty,
                    4)
            )
       )
       OR v_actor_active IS DISTINCT FROM TRUE
       OR v_actor_employee_id IS DISTINCT FROM v_batch.actor_employee_id
       OR v_event.inspection_item_id <> NEW.inspection_item_id
       OR v_event_confirmed > v_event.base_qty
       OR v_batch.receipt_type <> v_inspection.receipt_type
       OR v_batch.receipt_id <> v_inspection.receipt_id
       OR v_inspection.status = 'REVERSED'
       OR v_inspection.warehouse_id <> NEW.warehouse_id
       OR v_inspection.goods_id <> NEW.goods_id
       OR v_inspection.color_id IS DISTINCT FROM NEW.color_id
       OR v_movement.source_doc_type
            <> v_batch.receipt_type || '_RECEIPT'
       OR v_movement.source_doc_id <> v_batch.receipt_id
       OR v_movement.source_item_id <> NEW.id
       OR v_movement.warehouse_id <> NEW.warehouse_id
       OR v_movement.goods_id <> NEW.goods_id
       OR v_movement.color_id IS DISTINCT FROM NEW.color_id
       OR v_movement.direction <> 1
       OR v_movement.qty IS DISTINCT FROM NEW.base_qty
       OR COALESCE(v_movement.amount_local, 0)
            IS DISTINCT FROM NEW.amount_local
       OR v_movement.weight IS DISTINCT FROM NEW.weight
       OR v_movement.actual_weight_unit_id IS DISTINCT FROM NEW.weight_unit_id
       OR v_inspection.warehouse_stocked_base_qty
            IS DISTINCT FROM v_inspection.legacy_stocked_base_qty + v_confirmed
       OR v_inspection.warehouse_stocked_amount_local
            IS DISTINCT FROM v_inspection.legacy_stocked_amount_local
                + v_confirmed_amount
       OR v_inspection.warehouse_stocked_weight
            IS DISTINCT FROM v_expected_weight THEN
        RAISE EXCEPTION 'invalid procurement IQC warehouse stock-in identity or quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_iqc_stock_in_item_identity_chk';
    END IF;
    RETURN NEW;
END;
$$;
