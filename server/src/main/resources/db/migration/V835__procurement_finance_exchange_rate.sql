-- =====================================================================
-- V835：订货财务审批落「财务汇率」——case 级新列，不回写订单
-- =====================================================================
-- 用户口径（2026-10-10）：采购/委外创建订货单时不填汇率（订单表头默认 1），
-- 财务审批时填写当日汇率。订单侧保持提交事实不动——V438 商业快照冻结守卫
-- 在 case PENDING/APPROVED 期间禁止改动订单表头汇率/total_local 与行
-- amount_local，因此财务审批时填写的汇率必须落在 case 上，不写回订单：
--   · finance_exchange_rate：财务审批通过时填写的当日汇率（缺省视为 1）；
--   · finance_total_local = total_original × finance_exchange_rate 的完整
--     乘积（ADR-112 财务不四舍五入；4 位原币金额 × 6 位汇率最多 10 位小数，
--     NUMERIC(30,10) 可无损承载，对齐订单金额列口径的放大精度）；
--   · submission_snapshot / display_snapshot / snapshot_hash 一概不动——
--     提交快照是「提交事实」，财务汇率是「审批决定」，两者分离。
--
-- 触发器核对：V438 的 trg_guard_procurement_finance_commercial_snapshot
-- 挂在 BEFORE INSERT OR UPDATE OF status,order_type,order_id 上，函数体
-- 只校验 amount_snapshot 与订单 total_local 一致，不读 finance_* 新列；
-- 单独 UPDATE finance_* 列不触发该守卫，与 approve 同事务写入 status 时
-- 亦通过原有校验（amount_snapshot 不变）。订单表头/行冻结触发器的列清单
-- 也不含本表新列，财务汇率不构成解冻路径。
-- =====================================================================

ALTER TABLE procurement_order_approval_cases
    ADD COLUMN finance_exchange_rate NUMERIC(18,6),
    ADD COLUMN finance_total_local   NUMERIC(30,10);

COMMENT ON COLUMN procurement_order_approval_cases.finance_exchange_rate IS
    'V835 财务审批通过时填写的当日汇率（缺省 1）；仅 APPROVED 事件写入，驳回/未决为 NULL；不回写订单表头（V438 冻结）';
COMMENT ON COLUMN procurement_order_approval_cases.finance_total_local IS
    'V835 财务折合本币 = submission_snapshot.totalOriginal × finance_exchange_rate 的完整乘积（不舍入）；待审列表折合本币在为空时回落 amount_snapshot';

DO $v835_self_check$
BEGIN
    IF to_regclass('procurement_order_approval_cases') IS NULL THEN
        RAISE EXCEPTION 'V835 approval case table missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'procurement_order_approval_cases'
                     AND column_name = 'finance_exchange_rate'
                     AND data_type = 'numeric'
                     AND numeric_precision = 18 AND numeric_scale = 6)
       OR NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'procurement_order_approval_cases'
                     AND column_name = 'finance_total_local'
                     AND data_type = 'numeric'
                     AND numeric_precision = 30 AND numeric_scale = 10) THEN
        RAISE EXCEPTION 'V835 finance rate columns missing or wrong precision';
    END IF;
END;
$v835_self_check$;
