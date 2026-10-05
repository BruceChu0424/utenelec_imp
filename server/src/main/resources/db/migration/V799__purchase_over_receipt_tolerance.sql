-- =====================================================================
-- V799 采购允许超收比例, 超出部分走财务审批 (ADR-144)
-- =====================================================================
-- 用户口径(2026-10-04)：采购下单可以给每行填一个「允许超收%」, 累计实收在
-- 订货量 + 允许超收量以内照常入库立应付, 超过才转财务审批(沿用 ADR-019 到货异常)。
--
-- 本迁移：
--   1. fn_purchase_over_receipt_tolerance(qty, pct): 允许超收量唯一口径
--      ROUND(qty * COALESCE(pct,0) / 100, 4)(订货单位, 四舍五入), Java 同式
--      (PurchaseOverReceiptTolerance)。
--   2. goods.purchase_allowed_over_receipt_pct: 货品记忆值(保存采购订货单按货品最后一行
--      非空值回写, 空行不清记忆; /last-terms 预填)。先加列, 本迁移不做任何 UPDATE(V593 规矩)。
--   3. purchase_order_items.allowed_over_receipt_pct: 订货明细允许超收%, 空 = 0。
--      采购专用冻结触发器(照 V760 fn_guard_procurement_total_input): 只有草稿且未进入
--      财务审核/已批准的订单能改; 共享的 V438 商业冻结触发器不重建。
--   4. procurement_arrival_exceptions 四个快照列(只采购写): 订货量、允许超收%、允许超收量、
--      此前净收货量, 到货异常通知与任务卡据此写「订 Q, 允许超收 p%(最多 Q+T), 此前已收 R ...」。
--   5. 现时定义锚点补丁(pg_get_functiondef + 命中次数核对, V760 写法):
--      - fn_guard_procurement_received_with_arrival_allowance(采购/委外共用, TG_ARGV[0]):
--        只在 PURCHASE 分支加 T(当前订货量, p);
--      - fn_guard_return_allowance(采购/委外/销售共用): 只在 purchase_order_items 分支加 T × 换算率;
--      - fn_procurement_approval_display_snapshot: 明细多出 allowedOverReceiptPct。
--      共享函数一律经 to_jsonb(NEW) 读比例, 不直接写 NEW.allowed_over_receipt_pct
--      (委外/销售表没有这列, 直接引用会在它们的触发器上报错)。
-- 委外订货不加超收比例(ADR-144 §四), 委外回厂口径不变。不加表、不改存量数据。
-- =====================================================================

-- 1. 允许超收量唯一口径
CREATE FUNCTION fn_purchase_over_receipt_tolerance(p_qty numeric, p_pct numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT ROUND(p_qty * COALESCE(p_pct, 0) / 100, 4)
$$;
COMMENT ON FUNCTION fn_purchase_over_receipt_tolerance(numeric, numeric) IS
    '采购允许超收量(ADR-144): ROUND(订货量 x 允许超收% / 100, 4), 订货单位; 比例为空按 0。Java 侧 PurchaseOverReceiptTolerance 同式';

-- 2. 货品记忆值
ALTER TABLE goods
    ADD COLUMN purchase_allowed_over_receipt_pct NUMERIC(5,2)
        CONSTRAINT goods_purchase_allowed_over_receipt_pct_range
        CHECK (purchase_allowed_over_receipt_pct IS NULL
               OR (purchase_allowed_over_receipt_pct >= 0 AND purchase_allowed_over_receipt_pct <= 100));
COMMENT ON COLUMN goods.purchase_allowed_over_receipt_pct IS
    '采购允许超收百分比默认值(记忆, ADR-144): 采购订货明细预填, 保存采购订货单时按该货品最后一行非空值回写; 空=未设';

-- 3. 订货明细允许超收%
ALTER TABLE purchase_order_items
    ADD COLUMN allowed_over_receipt_pct NUMERIC(5,2)
        CONSTRAINT purchase_order_items_allowed_over_receipt_pct_range
        CHECK (allowed_over_receipt_pct IS NULL
               OR (allowed_over_receipt_pct >= 0 AND allowed_over_receipt_pct <= 100));
COMMENT ON COLUMN purchase_order_items.allowed_over_receipt_pct IS
    '本行允许超收百分比(ADR-144): 累计净收货不超过 订货量 + ROUND(订货量 x 比例 / 100, 4) + 已退货 + 已过账财务批准超量 + 质检退回补货额度 即可直接入库立应付; 空=0; 财务审核后不可改';

CREATE FUNCTION fn_guard_purchase_order_allowed_over_receipt() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE parent_status smallint;
BEGIN
    IF NEW.allowed_over_receipt_pct IS NOT DISTINCT FROM OLD.allowed_over_receipt_pct THEN RETURN NEW; END IF;
    SELECT status INTO parent_status FROM purchase_orders WHERE id = OLD.order_id FOR SHARE;
    IF parent_status IS DISTINCT FROM 0
       OR procurement_order_commercial_locked('PURCHASE', OLD.order_id)
       OR procurement_order_commercial_locked('PURCHASE', NEW.order_id) THEN
        RAISE EXCEPTION 'Submitted or confirmed purchase over-receipt allowances are immutable'
            USING ERRCODE = '23514', CONSTRAINT = 'purchase_order_allowed_over_receipt_frozen';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_purchase_order_allowed_over_receipt_frozen BEFORE UPDATE OF allowed_over_receipt_pct
ON purchase_order_items FOR EACH ROW
WHEN (OLD.allowed_over_receipt_pct IS DISTINCT FROM NEW.allowed_over_receipt_pct)
EXECUTE FUNCTION fn_guard_purchase_order_allowed_over_receipt();

-- 4. 到货异常快照(只采购写; 首次登记与重新检出都写)
ALTER TABLE procurement_arrival_exceptions
    ADD COLUMN order_qty_snapshot NUMERIC(18,4),
    ADD COLUMN allowed_over_receipt_pct_snapshot NUMERIC(5,2),
    ADD COLUMN tolerance_qty_snapshot NUMERIC(18,4),
    ADD COLUMN prior_net_received_qty_snapshot NUMERIC(18,4),
    ADD CONSTRAINT procurement_arrival_exceptions_receipt_tolerance_snapshot_chk CHECK (
        (order_qty_snapshot IS NULL AND allowed_over_receipt_pct_snapshot IS NULL
         AND tolerance_qty_snapshot IS NULL AND prior_net_received_qty_snapshot IS NULL)
        OR (order_type = 'PURCHASE'
            AND order_qty_snapshot > 0
            AND (allowed_over_receipt_pct_snapshot IS NULL
                 OR (allowed_over_receipt_pct_snapshot >= 0 AND allowed_over_receipt_pct_snapshot <= 100))
            AND tolerance_qty_snapshot IS NOT NULL
            AND tolerance_qty_snapshot = fn_purchase_over_receipt_tolerance(
                    order_qty_snapshot, allowed_over_receipt_pct_snapshot)
            AND prior_net_received_qty_snapshot IS NOT NULL
            AND prior_net_received_qty_snapshot >= 0));
COMMENT ON COLUMN procurement_arrival_exceptions.order_qty_snapshot IS
    '登记(或重新检出)时的采购订货量(订货单位); 委外异常为空';
COMMENT ON COLUMN procurement_arrival_exceptions.allowed_over_receipt_pct_snapshot IS
    '登记(或重新检出)时订货明细的允许超收百分比; 空=0; 委外异常为空';
COMMENT ON COLUMN procurement_arrival_exceptions.tolerance_qty_snapshot IS
    '登记(或重新检出)时的允许超收量 = fn_purchase_over_receipt_tolerance(订货量, 比例); 委外异常为空';
COMMENT ON COLUMN procurement_arrival_exceptions.prior_net_received_qty_snapshot IS
    '本张收货之前的累计净收货量(已收 - 已退 - 质检退回, 订货单位); 委外异常为空';

-- 5. 共享函数现时定义锚点补丁
DO $migration$
DECLARE source text; anchor text;
BEGIN
    source := pg_get_functiondef('fn_guard_procurement_received_with_arrival_allowance()'::regprocedure);
    anchor := '+ v_iqc_replacement;';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V799 received allowance capacity anchor differs';
    END IF;
    EXECUTE replace(source, anchor, anchor || E'\n'
        || E'    -- ADR-144: purchase lines add the frozen over-receipt tolerance; the shared\n'
        || E'    -- subcontract trigger never reads the purchase-only column.\n'
        || E'    IF TG_ARGV[0]=''PURCHASE'' THEN\n'
        || E'        v_capacity := v_capacity + fn_purchase_over_receipt_tolerance(COALESCE(NEW.qty,0),\n'
        || E'            (to_jsonb(NEW)->>''allowed_over_receipt_pct'')::numeric);\n'
        || E'    END IF;');

    source := pg_get_functiondef('fn_guard_return_allowance()'::regprocedure);
    anchor := 'v_excess_base numeric := 0;';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V799 return allowance declaration anchor differs';
    END IF;
    source := replace(source, anchor, anchor || E'\n    v_tolerance_base numeric := 0;');
    anchor := 'v_rate := COALESCE((v_new_row->>''unit_rate'')::numeric,1);';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V799 return allowance rate anchor differs';
    END IF;
    source := replace(source, anchor, anchor || E'\n'
        || E'            IF TG_TABLE_NAME=''purchase_order_items'' THEN\n'
        || E'                v_tolerance_base := fn_purchase_over_receipt_tolerance(v_base,\n'
        || E'                    (v_new_row->>''allowed_over_receipt_pct'')::numeric)*v_rate;\n'
        || E'            END IF;');
    anchor := '+v_iqc_base+v_excess_base THEN';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V799 return allowance capacity anchor differs';
    END IF;
    EXECUTE replace(source, anchor, '+v_iqc_base+v_excess_base+v_tolerance_base THEN');

    source := pg_get_functiondef('fn_procurement_approval_display_snapshot()'::regprocedure);
    anchor := '''allowedLossPct'', trim_scale(NULLIF(to_jsonb(item) ->> ''allowed_loss_pct'', '''')::numeric)::text,';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V799 display snapshot anchor differs';
    END IF;
    EXECUTE replace(source, anchor, anchor || E'\n'
        || E'                    ''allowedOverReceiptPct'', trim_scale(NULLIF(to_jsonb(item) ->> ''allowed_over_receipt_pct'', '''')::numeric)::text,');
END;
$migration$;

-- 6. 补丁结果核对(fail closed)
DO $postcondition$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_guard_procurement_received_with_arrival_allowance'
                   AND prosrc LIKE '%fn_purchase_over_receipt_tolerance(COALESCE(NEW.qty,0)%')
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_guard_procurement_received_with_arrival_allowance'
                  AND prosrc LIKE '%NEW.allowed_over_receipt_pct%')
       OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_guard_return_allowance'
                      AND prosrc LIKE '%+v_iqc_base+v_excess_base+v_tolerance_base THEN%')
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_guard_return_allowance'
                  AND prosrc LIKE '%NEW.allowed_over_receipt_pct%')
       OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_procurement_approval_display_snapshot'
                      AND prosrc LIKE '%''allowedOverReceiptPct''%') THEN
        RAISE EXCEPTION 'V799 shared function patch postcondition failed';
    END IF;
END;
$postcondition$;
