-- =====================================================================
-- V814 (ADR-165 / ADR-091 §九, 2026-10-06 修订二)
-- 车间任务「物料到货进展」行动卡的可支撑产能高水位。
--
-- publishWorkshopMaterialArrival 每次到货事件评估本段「当前可支撑产量」:
--   BATCH      = 分批领料核对页同一把尺子(冻结耗用曲线二分 × 仓库可用量, 剩余段自动扣前批);
--   CONTINUOUS = 已备预留产能 fn_execution_material_output_capacity(segment, FALSE)(已领走的料不占口径);
--   FULL_KIT   = 齐套是全有或全无: 仓库口径盖住全部缺口 = planned_qty, 否则 0。
-- 只有产能比该水位高才弹「可以生产 X 件」, 发卡后水位抬到当前值, 回落也同步下来;
-- 无行 = 从未评估, 按 0 对待。水位放 1:1 侧表而不是段表加列: 段表的 BEFORE UPDATE
-- 触发器会 bump lock_version/updated_at 并重验车间负责人, 每次水位变化会把在途的
-- 领料核对 CAS(「车间任务已变化, 请刷新」)顶失效。系统协调状态: 不挂行级审计,
-- 清空业务数据时清空(与 V798/V809 通知水位表同款)。
-- =====================================================================

CREATE TABLE production_execution_segment_notice_state (
    segment_id UUID PRIMARY KEY REFERENCES production_execution_segments(id) ON DELETE CASCADE,
    arrival_notice_capacity NUMERIC(18,4),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_execution_notice_capacity_chk
        CHECK (arrival_notice_capacity IS NULL OR arrival_notice_capacity >= 0)
);
COMMENT ON TABLE production_execution_segment_notice_state IS
    'V814(ADR-165): 车间任务「物料到货进展」行动卡的可支撑产能高水位(每个执行段一行). 产能 > 水位才发卡并抬高水位; 回落时同步下来, 不发卡. 系统协调状态, 不挂行级审计, 清空业务数据时清空';

-- ---------------------------------------------------------------------
-- 清空业务数据: 通知水位随业务清空(V798/V809 同款锚点插入, needle 单行无换行)
-- ---------------------------------------------------------------------
DO $reset_policy$
DECLARE
    definition TEXT;
    anchor TEXT := '(''subcontract_application_kit_notice_marks'', ''CLEAR''),';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('production_execution_segment_notice_state' IN definition) > 0 THEN
        RAISE EXCEPTION 'V814 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor,
        anchor || E'\n            (''production_execution_segment_notice_state'', ''CLEAR''),');
END;
$reset_policy$;

-- ---------------------------------------------------------------------
-- 自检
-- ---------------------------------------------------------------------
DO $v814_self_check$
BEGIN
    IF position('(''production_execution_segment_notice_state'', ''CLEAR'')'
                IN pg_get_functiondef('business_data_reset()'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'V814 business_data_reset must clear production_execution_segment_notice_state';
    END IF;
END;
$v814_self_check$;
