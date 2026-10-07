-- 车间任务「物料到货进展」行动卡的产能水位 (ADR-165 / ADR-091 §九, 2026-10-06 修订二)。
-- publishWorkshopMaterialArrival 每次到货事件评估本段「当前可支撑产量」:
--   BATCH      = 分批领料核对页同一把尺子(冻结耗用曲线二分 × 仓库可用量, 剩余段自动扣前批);
--   CONTINUOUS = 已备预留产能 fn_execution_material_output_capacity(segment, FALSE)(已领走的料不占口径);
--   FULL_KIT   = 齐套是全有或全无: 仓库口径盖住全部缺口 = planned_qty, 否则 0。
-- 只有产能比该水位高才弹「可以生产 X 件」, 发卡后水位抬到当前值, 回落也同步下来;
-- NULL = 从未评估, 按 0 对待。列只在通知投递线程、段行锁内更新(值不变不写), 不入实体映射;
-- 表为 FULL 行级审计, 水位变化自然留痕, 不需要单独登记。
ALTER TABLE production_execution_segments
    ADD COLUMN arrival_notice_capacity numeric(18,4);

COMMENT ON COLUMN production_execution_segments.arrival_notice_capacity IS
    '上次到货进展行动卡评估时的可支撑产量水位(按路线取口径, 见 ADR-165): 比它高才发卡, 发卡或回落都同步成当前值; NULL=从未评估按 0';
