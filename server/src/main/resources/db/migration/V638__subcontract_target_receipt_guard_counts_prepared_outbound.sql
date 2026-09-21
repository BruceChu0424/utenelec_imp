-- ============ 委外回厂先出后进守卫计入前置自制出仓行 (2026-09-21) ============
-- 背景(ADR-062 §十): 委外前置自制的订货可以超过通知量, 上限 = 任务锁定给本申请的量 + 同货色
-- 公共可用量——锁定份落 PREPARED_OUTBOUND、超出份落 DIRECT_OUTBOUND, 两条计划行挂在同一条订货明细。
-- V436/V581 的回厂守卫 fn_assert_subcontract_target_outbound_receipt 只在明细含 DIRECT/MAKE_THEN/
-- COMPONENT 行时激活, 但「已审出仓量 v_issued / 已消费量 v_consumed」两个合计共用的 JOIN 只认这三种
-- 流向、不认 PREPARED_OUTBOUND: 混合明细出仓 33(30 前置 + 3 公共)后回厂 33, v_issued 只算到 3,
-- COMMIT 抛 "subcontract target receipt exceeds approved target-item outbound"。Java 镜像
-- (SubcontractOutboundFlowSql.ISSUED_TARGET_BASE_SUM 与回厂消费)一直按全部流向合计, 两边口径不一。
-- 直下单「现货目标件 PREPARED + 余量 MAKE_THEN」(V535 directPreparedLineage)的混合明细同受影响。
--
-- 本迁移: 只给该 JOIN 的流向集合补上 'PREPARED_OUTBOUND'; 激活条件(明细含 DIRECT/MAKE_THEN/COMPONENT
-- 行才检查)一个字节不动——纯 PREPARED 明细仍按 ADR-085 §四「V507 白名单不含 PREPARED_OUTBOUND」的
-- 既定口径暂不受该守卫约束(单独排期)。V580 式形状纪律: 取定义、行尾归一 LF、锚点恰好一处才替换,
-- 不中宁可失败(23514); 已是补丁后形状(例如 dev 库先手工执行过)则跳过。不加表、不加列、不改行、不动触发器。
DO $v638$
DECLARE
    definition TEXT;
    patched TEXT;
    anchor TEXT;
    replacement TEXT;
    activation TEXT;
    hits INTEGER;
BEGIN
    SELECT replace(pg_get_functiondef(
               'fn_assert_subcontract_target_outbound_receipt(uuid)'::regprocedure), E'\r\n', E'\n')
      INTO definition;
    anchor := E'    JOIN subcontract_material_plan_items plan_item ON plan_item.id=item.plan_item_id\n'
           || E'      AND plan_item.flow_mode IN (\n'
           || E'          ''DIRECT_OUTBOUND'',''MAKE_THEN_OUTBOUND'',''COMPONENT_OUTBOUND'')\n';
    replacement := E'    JOIN subcontract_material_plan_items plan_item ON plan_item.id=item.plan_item_id\n'
                || E'      AND plan_item.flow_mode IN (\n'
                || E'          ''DIRECT_OUTBOUND'',''MAKE_THEN_OUTBOUND'',''COMPONENT_OUTBOUND'',''PREPARED_OUTBOUND'')\n';
    activation := E'          AND plan_item.flow_mode IN (\n'
               || E'              ''DIRECT_OUTBOUND'',''MAKE_THEN_OUTBOUND'',''COMPONENT_OUTBOUND'')\n';
    IF strpos(definition, replacement) > 0 AND strpos(definition, activation) > 0 THEN
        RAISE NOTICE 'V638: fn_assert_subcontract_target_outbound_receipt already counts PREPARED_OUTBOUND, nothing to do';
        RETURN;
    END IF;
    hits := (length(definition) - length(replace(definition, anchor, ''))) / length(anchor);
    IF hits <> 1 THEN
        RAISE EXCEPTION 'V638 receipt guard source mismatch: issued/consumed join anchor hit % times', hits
            USING ERRCODE = '23514';
    END IF;
    IF strpos(definition, activation) = 0 THEN
        RAISE EXCEPTION 'V638 receipt guard source mismatch: activation condition not found'
            USING ERRCODE = '23514';
    END IF;
    patched := replace(definition, anchor, replacement);
    IF strpos(patched, activation) = 0 THEN
        RAISE EXCEPTION 'V638 receipt guard source mismatch: activation condition must stay untouched'
            USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END $v638$;

COMMENT ON FUNCTION fn_assert_subcontract_target_outbound_receipt(UUID) IS
    'V436/V581 委外回厂先出后进与供应商处消费守恒; V638: 已审出仓量/已消费量合计计入 PREPARED_OUTBOUND 行(前置自制订货超量的混合明细), 激活条件不变';

-- ============ 草稿订货行金额归一 (同一用户反馈的另一半, 2026-09-21) ============
-- 此前客户端把「数量×单价」按 double 相乘后原样送来(3×0.10 = 0.30000000000000004), 服务端原样落库;
-- 送审时 requireFinanceCommercialAuthority 精确比对必拒「金额与数量、单价或汇率不一致」, 用户误以为是
-- 超量下单被拦。服务端自本批起按数量×单价×表头汇率精确重算; 这里把仍在草稿态(status=0)、单价非空且
-- 金额与精确乘积不等的采购/委外订货行一次归一, 表头合计随之按明细重算——已审/红冲/取消单一个字节不动。
UPDATE purchase_order_items oi
   SET amount_original = oi.qty * oi.price,
       amount_local = oi.qty * oi.price * COALESCE(po.exchange_rate, 1)
  FROM purchase_orders po
 WHERE po.id = oi.order_id AND po.status = 0 AND COALESCE(po.is_deleted, FALSE) = FALSE
   AND COALESCE(oi.is_deleted, FALSE) = FALSE AND oi.price IS NOT NULL AND oi.qty IS NOT NULL
   AND (oi.amount_original IS DISTINCT FROM oi.qty * oi.price
        OR oi.amount_local IS DISTINCT FROM oi.qty * oi.price * COALESCE(po.exchange_rate, 1));
UPDATE purchase_orders po
   SET total_original = totals.original, total_local = totals.local
  FROM (SELECT order_id, SUM(COALESCE(amount_original, 0)) AS original, SUM(COALESCE(amount_local, 0)) AS local
          FROM purchase_order_items WHERE COALESCE(is_deleted, FALSE) = FALSE GROUP BY order_id) totals
 WHERE po.id = totals.order_id AND po.status = 0 AND COALESCE(po.is_deleted, FALSE) = FALSE
   AND (po.total_original IS DISTINCT FROM totals.original OR po.total_local IS DISTINCT FROM totals.local);

UPDATE subcontract_order_items oi
   SET amount_original = oi.qty * oi.price,
       amount_local = oi.qty * oi.price * COALESCE(so.exchange_rate, 1)
  FROM subcontract_orders so
 WHERE so.id = oi.order_id AND so.status = 0 AND COALESCE(so.is_deleted, FALSE) = FALSE
   AND COALESCE(oi.is_deleted, FALSE) = FALSE AND oi.price IS NOT NULL AND oi.qty IS NOT NULL
   AND (oi.amount_original IS DISTINCT FROM oi.qty * oi.price
        OR oi.amount_local IS DISTINCT FROM oi.qty * oi.price * COALESCE(so.exchange_rate, 1));
UPDATE subcontract_orders so
   SET total_original = totals.original, total_local = totals.local
  FROM (SELECT order_id, SUM(COALESCE(amount_original, 0)) AS original, SUM(COALESCE(amount_local, 0)) AS local
          FROM subcontract_order_items WHERE COALESCE(is_deleted, FALSE) = FALSE GROUP BY order_id) totals
 WHERE so.id = totals.order_id AND so.status = 0 AND COALESCE(so.is_deleted, FALSE) = FALSE
   AND (so.total_original IS DISTINCT FROM totals.original OR so.total_local IS DISTINCT FROM totals.local);
