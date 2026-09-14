-- =====================================================================
-- V575 2026-09-13 货品主档新增采购批量口径：最小起订量 + 订货倍数
-- =====================================================================
-- 背景：采购天天遇到「本次净需求只要 100，但供应商起订 500、整箱 50」。
--   今天这两个数字只活在采购员脑子里或供应商邮件里，每次下单靠人肉抬量、
--   算错就是多付钱或被供应商退单。把它落到货品主档，下达采购时的数量默认按
--       建议下达量 = 向上取整到倍数( max(净需求, 起订量) )
--   预填。超出净需求的部分不是凭空造库存：它走既有的公共备货通道（同货品的
--   后续需求优先消耗这批多出来的量），口径与安全库存/公共备货一致。
--
-- 这是**软约束**：服务端不硬拦。采购员可以改小（谈下来了 / 急单先要 100 /
--   供应商清尾货），只是默认值按上面公式给。因此两列都可空——没填 = 供应商
--   没有批量要求，按净需求原样下达。
--
-- 列与取值：
-- ① goods.min_order_qty NUMERIC(18,4)：最小起订量（MOQ）。
--    CHECK：NULL 或 >= 0。允许 0（= 明确登记过「无起订量」，与 NULL「还没登记」
--    语义不同，采购看到 0 知道这是问过供应商的结论，不用再问一遍）。
-- ② goods.order_multiple_qty NUMERIC(18,4)：订货倍数 / 整包装量（整箱 50 即 50）。
--    CHECK：NULL 或 **> 0**（不是 >= 0）。这里刻意与 min_order_qty 取不同口径：
--    倍数要参与「向上取整到它的倍数」= 除法，0 会直接炸成除零；而「倍数 = 0」
--    在业务上也讲不通。服务端把提交上来的 0 归一成 NULL（视同未设），本 CHECK
--    只做兜底，正常路径不会撞到它。
--    数量单位沿用货品的基本单位（goods.unit_id），不再单独存单位。
--
-- 审计 / 清库白名单核实（只加列、不加表，两处都不用改）：
-- ① 审计触发器：goods 已在 AuditTriggerCoverageMigrationContractTest 的
--    REQUIRED_BUSINESS_TABLES 里，行级触发器按整行 to_jsonb 记录，新列自动
--    进快照，不需要动 allowlist，也不需要再发一版 refresh_audit_trigger_coverage。
-- ② 清空业务数据白名单（ops/reset_business_data.sql 与 business_data_reset()）
--    是**表级** CLEAR/PRESERVE 分类，goods 已登记为 PRESERVE。本次没有新表，
--    白名单不用改。两列是主档口径（供应商的批量要求），清业务数据时应随主档
--    保留，不进 CLEAR。
-- =====================================================================

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS min_order_qty       NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS order_multiple_qty  NUMERIC(18,4);

ALTER TABLE goods
    ADD CONSTRAINT goods_order_policy_qty_chk CHECK (
        (min_order_qty IS NULL OR min_order_qty >= 0)
        AND (order_multiple_qty IS NULL OR order_multiple_qty > 0));

COMMENT ON COLUMN goods.min_order_qty IS
    '最小起订量（供应商 MOQ，基本单位）；NULL=未登记，0=已确认无起订量。软约束：下达采购按它抬量预填，可人工改小。';
COMMENT ON COLUMN goods.order_multiple_qty IS
    '订货倍数/整包装量（基本单位，如整箱 50 存 50）；NULL=无倍数要求。软约束：下达采购向上取整到它的倍数预填，可人工改。0 由服务端归一为 NULL。';
