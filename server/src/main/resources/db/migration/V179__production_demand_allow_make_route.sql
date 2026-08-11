-- 放宽 production_material_demand_segment_shape_chk：允许执行分段需求采用 MAKE 路线。
--
-- 背景：V155 建立执行分段时，自制件（source_type=自制）在排产层就被
-- ProductionExecutionPlanningService.supportedSupplyRoute 直接拒收（throw conflict），
-- 因此 DB 层的形状校验另加一道 `supply_route <> 'MAKE'` 作为兜底，确保 MAKE 永不入库。
--
-- 现状：自制件派生内核（generateSelfMadeSubplansForPackage）上线后，supportedSupplyRoute
-- 已改为把自制件映射成 ROUTE_MAKE —— 自制件需参与齐套判定、消耗半成品现货库存，其缺口
-- 不再走采购/委外（proposedShortage 按路线严格过滤，MAKE 天然排除），而由子生产计划供给。
-- 于是 MAKE 物料会正常生成执行分段需求，但 V155 的兜底约束仍拒绝它，导致确认计划包时
-- INSERT production_material_demands 报 23514 违反约束（HHH100503 批次中止）。
--
-- 解法：去掉 `AND supply_route <> 'MAKE'` 这一条。形状校验的其余部分（要么三段字段全空，
-- 要么 execution_segment_id / source_plan_item_id / per_product_qty 同时非空且 per_product_qty>0）
-- 保持不变。历史上不存在 MAKE 分段需求，重建约束不与现有数据冲突。

ALTER TABLE production_material_demands
    DROP CONSTRAINT production_material_demand_segment_shape_chk;

ALTER TABLE production_material_demands
    ADD CONSTRAINT production_material_demand_segment_shape_chk
        CHECK (
            (
                execution_segment_id IS NULL
                AND source_plan_item_id IS NULL
                AND per_product_qty IS NULL
            )
            OR
            (
                execution_segment_id IS NOT NULL
                AND source_plan_item_id IS NOT NULL
                AND per_product_qty IS NOT NULL
                AND per_product_qty > 0
            )
        );
