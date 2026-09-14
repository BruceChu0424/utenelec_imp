-- =====================================================================
-- V577：下达车间允许超量，超出部分按「公共备货产出」单独分账
-- =====================================================================
-- 背景（2026-09-14 用户口径）：
--   「生产是可以超出数量下达的；超出部分就是公共的，其他计划可以占用——
--     你看看采购，参考下。」
--   采购/无子层委外早已有这套分账（preplan_supply_actions.public_surplus_qty，
--   V472）：精确需求归 allocation/exact，富余量单记公共切片。生产侧此前完全
--   没有落点——计划量被 V234 的三道守恒钉死在需求量以内：
--     ① production_material_analysis_item_qty_chk：submitted+approved<=requested
--     ② V478：submitted+approved+root_fulfilled<=requested
--     ③ fn_sync_material_analysis_plan_link_qty：pi.qty 必须恰等于 link.submitted_qty
--   所以只要本批数量>剩余需求，事务必然回滚。
--
-- 本次做法（不动 ①②，只松开 ③）：
--   计划关联行新增 public_surplus_qty，把一次下达拆成两笔——
--     submitted_qty      = 归本需求的量（照旧驱动 items.submitted_qty 与齐套投影）
--     public_surplus_qty = 超出需求、按公共备货产出记账的量（不绑定任何需求）
--   计划行数量 = 两者之和。items 的 requested/submitted/approved 一个字节不动，
--   ①② 两条 CHECK 与 growMakeAnchorQuotasAfterSourcePreview 的锚点配额算法
--   因此完全不受影响；多做出来的成品入库后不被本需求消耗，自然留在公共库存，
--   其他计划按既有公共库存口径直接使用。
--
-- 刻意不做的事：
--   · 不抬高任何 items.requested_qty。抬需求会污染锚点配额增长算法
--     （openQuota = requested − inbound 一旦高于物理缺口，后续新增销售来源的
--      合法需求增长会被静默吞成 0），也会与 syncRequestedQuantities 的来源对账脱钩。
--   · 不给超出部分自动展开下层物料需求。锚点行本就不展开自己的 BOM
--     （MaterialAnalysisService#loadBomTrees 过滤 MAKE_COMPONENT/SUBCONTRACT_MAKE），
--      父件计划产出也按物理缺口封顶；多做那部分的料由计划员另行安排，
--      下达前前端已二次确认（ADR-070 §2.7「额外数量尚未形成下层材料需求」）。
--   · 销售订单来源的顶层行仍然不允许超量（应用层 requireOverQuantityAllowed 拒绝）：
--     那会同时踩到 production_plan_sales_allocations 的「分摊合计=计划数量」守恒
--     与 ProductionPlanService 的「排产量≤订单未满足需求」。
--
-- 版本号：本分支迁移头为 V575；V576 由并行的「财务主档改造」分支占用
--   （见 memory/finance-master-rework），此处顺延取 V577 避免撞号。
--   两个分支合并后 reset_business_data.sql 的 (max_version, count) 白名单
--   需要一并重算（本次登记 (577, 534)）。
-- =====================================================================

ALTER TABLE production_material_analysis_plan_links
    ADD COLUMN IF NOT EXISTS public_surplus_qty NUMERIC(18,4) NOT NULL DEFAULT 0;

ALTER TABLE production_material_analysis_plan_links
    DROP CONSTRAINT IF EXISTS production_material_analysis_plan_link_qty_chk;

-- 原约束是 submitted_qty > 0。拆账后「整批都是公共备货产出」是合法形态
-- （剩余需求已为 0 却仍要多做一批），故改为两者非负、合计为正。
ALTER TABLE production_material_analysis_plan_links
    ADD CONSTRAINT production_material_analysis_plan_link_qty_chk CHECK (
        submitted_qty >= 0
        AND public_surplus_qty >= 0
        AND submitted_qty + public_surplus_qty > 0
    );

COMMENT ON COLUMN production_material_analysis_plan_links.public_surplus_qty IS
    '本次下达中超出该任务行剩余需求、按公共备货产出记账的量；不绑定需求、不进 allocation/exact，产出入库即公共库存';

-- 触发器形状补丁（沿用 V478 既有做法：读当前定义 → 断言形状 → 定点替换 → 重建）。
-- 当前活动定义来自 V490；这里只改两处，其余逻辑逐字保留，避免整函数复制带来的漂移。
DO $$
DECLARE
    definition TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'fn_sync_material_analysis_plan_link_qty()'::regprocedure) INTO definition;

    IF position('AND pi.qty = NEW.submitted_qty' IN definition) = 0
       OR position('OR OLD.submitted_qty IS DISTINCT FROM NEW.submitted_qty' IN definition) = 0 THEN
        RAISE EXCEPTION 'V577 analysis plan-link function shape changed';
    END IF;

    -- ③ 计划行数量对账：与「归需求量 + 公共备货产出量」之和相等。
    definition := replace(definition,
        'AND pi.qty = NEW.submitted_qty',
        'AND pi.qty = NEW.submitted_qty + COALESCE(NEW.public_surplus_qty, 0)');

    -- 关联行身份不可变：新列与 submitted_qty 同级，禁止事后改写。
    definition := replace(definition,
        'OR OLD.submitted_qty IS DISTINCT FROM NEW.submitted_qty',
        'OR OLD.submitted_qty IS DISTINCT FROM NEW.submitted_qty'
            || E'\n        OR OLD.public_surplus_qty IS DISTINCT FROM NEW.public_surplus_qty');

    EXECUTE definition;
END;
$$;
