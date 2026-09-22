-- ====== 委外回厂守恒守卫计入「财务已批准的委外商自带料」 (ADR-101, 2026-09-21) ======
-- 用户口径: 「超过就是得通知财务」。委外回厂此前有两道数量闸, 顺序上先撞的是守恒那道:
-- 我方发了 1000 个子件就只能交回 1000 个委外件, 交回 1050 直接抛
-- 「委外目标件尚未足额出仓且无足够IQC失败返修额度，禁止超量回仓」并整笔回滚——
-- 仓库看不懂、单子建不出来, 财务那边完全不知情, 多出来的 50 个实物落在账外。
--
-- 本轮改成: 超出「我方供料能做出来的数量」的部分不再硬拒, 而是照 ADR-019 落 PENDING_FINANCE
-- 到货异常并通知财务审核组(货不入库、不立应付、转到货异常任务中心), 文案说清多出来的部分用的
-- 是委外商自己的材料, 请财务确认价格和归属。服务端侧改的是 ProcurementArrivalControlService
-- (按实际供料量压上限)与 SubcontractReceiptService(异常闸先跑、守恒闸兜底)。
--
-- 守恒本身**不放开**: 只是把「财务已经批准的那份自带料」从守恒台账里摘出去——它不是我方发的料,
-- 本来就不该参与「发出去多少 = 交回来多少 + 退料 + 损耗 + 供应商处剩余」这个等式。没有财务批准
-- 就一个字节都过不去, 所以不会出现「不知道料从哪来」的库存。
--
-- 形状纪律同 V580/V638: 取 live 定义、行尾归一 LF、锚点恰好一处才替换, 不中宁可失败(23514);
-- 已是补丁后形状(dev 库先手工执行过)则跳过。不加表、不加列、不改行、不动触发器。
DO $v642$
DECLARE
    definition TEXT;
    patched TEXT;
    anchor TEXT;
    replacement TEXT;
    hits INTEGER;
BEGIN
    SELECT replace(pg_get_functiondef(
               'fn_assert_subcontract_target_outbound_receipt(uuid)'::regprocedure), E'\r\n', E'\n')
      INTO definition;
    anchor := E'    v_received:=v_received-v_replacement;\n';
    -- 自带料额度自钳位: 最多只能抵掉台账上真有的那部分, 于是 v_received 不会被它压成负数,
    -- 原有的 v_received<0 兜底(红冲/错账)仍然有效。
    replacement := E'    v_received:=v_received-v_replacement-LEAST(\n'
                || E'        GREATEST(COALESCE((\n'
                || E'            SELECT SUM(finance_excess.approved_excess_qty*COALESCE(excess_oi.unit_rate,1))\n'
                || E'            FROM procurement_arrival_exceptions finance_excess\n'
                || E'            JOIN subcontract_order_items excess_oi ON excess_oi.id=finance_excess.order_item_id\n'
                || E'            WHERE finance_excess.order_type=''SUBCONTRACT''\n'
                || E'              AND finance_excess.order_item_id=p_order_item_id\n'
                || E'              AND finance_excess.status IN (''RECEIPT_ADJUSTED'',''RECEIPT_POSTED'',''CLOSED'')\n'
                || E'              AND finance_excess.decision IN (''APPROVE_ALL'',''APPROVE_CUSTOM'')\n'
                || E'              AND finance_excess.approved_excess_qty>0),0),0),\n'
                || E'        GREATEST(v_received-v_replacement,0));\n';
    IF strpos(definition, replacement) > 0 THEN
        RAISE NOTICE 'V642: fn_assert_subcontract_target_outbound_receipt already credits finance-approved supplier material, nothing to do';
        RETURN;
    END IF;
    hits := (length(definition) - length(replace(definition, anchor, ''))) / length(anchor);
    IF hits <> 1 THEN
        RAISE EXCEPTION 'V642 receipt guard source mismatch: replacement netting anchor hit % times', hits
            USING ERRCODE = '23514';
    END IF;
    patched := replace(definition, anchor, replacement);
    -- V638 补上的 PREPARED_OUTBOUND 合计与 V581 的激活条件都必须原样留在补丁结果里。
    IF strpos(patched, E'''DIRECT_OUTBOUND'',''MAKE_THEN_OUTBOUND'',''COMPONENT_OUTBOUND'',''PREPARED_OUTBOUND''') = 0 THEN
        RAISE EXCEPTION 'V642 receipt guard source mismatch: V638 issued/consumed flow list missing'
            USING ERRCODE = '23514';
    END IF;
    IF strpos(patched, E'subcontract_target_outbound_consumption_guard') = 0 THEN
        RAISE EXCEPTION 'V642 receipt guard source mismatch: consumption guard must stay untouched'
            USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END $v642$;

COMMENT ON FUNCTION fn_assert_subcontract_target_outbound_receipt(UUID) IS
    'V436/V581 委外回厂先出后进与供应商处消费守恒; V638: 合计计入 PREPARED_OUTBOUND 行; V642(ADR-101): 财务已批准的委外商自带料不计入守恒台账(超量部分走 ADR-019 到货异常, 无财务批准仍然一个字节都过不去)';
