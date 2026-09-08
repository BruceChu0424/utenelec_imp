-- V480: 委外=自制同构直下（2026-09-05）。
-- 委外准备中心·分析来源页签新增车间进度列：读模型按委托行
-- （production_plans.material_analysis_item_id = preparation_item_id）
-- 聚合 production_execution_segments 状态。生产计划表此前没有该列索引，
-- 数据量增大后 LATERAL 逐行回表会退化为顺序扫描——补部分索引
-- （仅未删除计划行），同时服务委托行直查与进度聚合两条路径。

CREATE INDEX IF NOT EXISTS idx_production_plans_analysis_item
    ON production_plans(material_analysis_item_id)
    WHERE material_analysis_item_id IS NOT NULL AND is_deleted = FALSE;
