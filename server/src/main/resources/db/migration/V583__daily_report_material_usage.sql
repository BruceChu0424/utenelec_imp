-- V583 报工页同页登记实际用料：日报承载本次实耗，审核时与完工量同事务记账。
--
-- 背景(2026-09-14 用户需求)：车间原来要在「我的车间任务」右侧滑窗单独「登记实际用料」，
-- 报工与用料是两处操作。改为在生产日报明细表里，每个成品行下面挂它所属工单已领用的物料
-- 子行，直接填「本次实际用料」。
--
-- 为什么要建表而不是保存即结算：日报 create 只产出草稿(status=0)，要主管审核才增加完工量；
-- 而材料消耗(production_material_settlement_postings 的 CONSUMED)是立即生效的实账。
-- 若保存草稿就记实耗，草稿被删或日报红冲时实耗不会退回去，两套事实会长期对不上。
-- 所以本迁移让日报**先承载**用料数字(本表，不记账)，审核时才在同一笔事务里调结算，
-- 红冲时按 production_material_settlement_events.daily_report_id 反查并整体冲销。
--
-- 不改 V152 的材料守恒视图/触发器，不回填历史行：历史日报没有用料行，材料台账照旧从
-- 计划详情侧滑窗单独登记。

-- ===== 1. 日报承载的本次实际用料(草稿态事实，不是记账) =====
CREATE TABLE production_daily_report_material_usages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL REFERENCES production_daily_reports(id),
    line_no INT NOT NULL CHECK(line_no > 0),
    plan_id UUID NOT NULL REFERENCES production_plans(id),
    demand_id UUID NOT NULL REFERENCES production_material_demands(id),
    -- 物料所属执行段。分批生产时本批段可能一条需求都没有，料挂在前批原领料段上
    -- (V561 fn_production_material_usage_source_segments)，所以它不等于报工行的执行段。
    material_execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    -- 基本量(需求 unit_id 口径)，与 settlement 的 qty_base 同口径。允许 0：
    -- 「这批料一点没用」是合法事实，不能逼车间编一个正数。
    qty_base NUMERIC(18, 4) NOT NULL CHECK(qty_base >= 0),
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    updated_at TIMESTAMPTZ,
    -- 一张日报对一条物料需求只登记一次：同一工单出现在多个成品行时，前端把第二行的
    -- 物料子行做成只读镜像，避免同一份额度被两行各自当满额填。
    CONSTRAINT uq_daily_report_material_usage UNIQUE (report_id, demand_id)
);
CREATE INDEX idx_daily_report_material_usage_report
    ON production_daily_report_material_usages(report_id, line_no);
CREATE INDEX idx_daily_report_material_usage_demand
    ON production_daily_report_material_usages(demand_id);
CREATE INDEX idx_daily_report_material_usage_segment
    ON production_daily_report_material_usages(material_execution_segment_id);

-- 审计触发器(对齐全库口径：一表一 trg_audit_*，ALWAYS)。
-- 逐条字面写，不用 DO + format 动态生成：AuditTriggerCoverageMigrationContractTest
-- 要求新表自带**可评审**的行级审计触发器，判定方式就是在迁移正文里找
-- `create trigger trg_audit_<表>` / `after insert or update or delete on <表>` /
-- `for each row execute function fn_audit()` 三段字面量。
CREATE TRIGGER trg_audit_production_daily_report_material_usages
    AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_material_usages
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_daily_report_material_usages
    ENABLE ALWAYS TRIGGER trg_audit_production_daily_report_material_usages;

-- ===== 2. 收尾余料退仓意愿(报工时勾，审核时执行) =====
-- 为什么不在保存日报时就发退仓申请：退仓申请一提交就用 fn_material_issue_pending_return
-- 冻结该领料过账的额度，而实耗要到审核才登记；先冻后结会让审核时的 settle 撞
-- 「本次清账超过准确原领料未耗用数量」。所以顺序必须是「审核 → 先结实耗 → 再发退仓」，
-- 车间在报工时做的只是把意愿记下来。
ALTER TABLE production_daily_reports
    ADD COLUMN surplus_return_requested BOOLEAN NOT NULL DEFAULT FALSE;

-- ===== 3. 实耗溯源：这条结算是哪张日报登记的 =====
-- 可空：历史结算事件(计划详情侧滑窗单独登记的)没有日报来源，不回填。
-- 日报红冲时按它反查本单 POST 事件下的全部 CONSUMED 过账，逐条按 source_posting_id 冲销。
ALTER TABLE production_material_settlement_events
    ADD COLUMN daily_report_id UUID REFERENCES production_daily_reports(id);
CREATE INDEX idx_material_settlement_events_daily_report
    ON production_material_settlement_events(daily_report_id)
    WHERE daily_report_id IS NOT NULL;

COMMENT ON TABLE production_daily_report_material_usages IS '生产日报承载的本次实际用料(V583)；草稿态只是事实登记，审核时才转为 CONSUMED 结算';
COMMENT ON COLUMN production_daily_report_material_usages.material_execution_segment_id IS '物料所属执行段；分批生产时可能是前批原领料段，不等于报工行执行段';
COMMENT ON COLUMN production_daily_report_material_usages.qty_base IS '本次实际用料基本量；允许 0 表示本次没用这份料';
COMMENT ON COLUMN production_daily_reports.surplus_return_requested IS '收尾余料退仓意愿(V583)；审核时先结实耗再按剩余可退量生成退仓申请';
COMMENT ON COLUMN production_material_settlement_events.daily_report_id IS '本次结算由哪张生产日报审核触发(V583)；历史独立登记为 NULL';
