-- V468：物料分析路线学习预填查询索引（ADR-070 §2.3）。
-- GET /api/production/material-analyses/last-routes 按货品+颜色+单位跨分析取
-- 最近一次 confirmed_route（DISTINCT ON ... ORDER BY goods_id, color_id,
-- unit_id, created_at DESC, id DESC）。既有 dimension 索引以 analysis_id 打头，
-- 对跨分析按货品查询无效；分析量大后该预填查询会退化为全表排序。
-- 部分索引只覆盖有确认路线的活动行，预填只读这些行。
CREATE INDEX idx_production_material_analysis_material_last_route
    ON production_material_analysis_materials(
        goods_id, color_id, unit_id, created_at DESC, id DESC
    ) WHERE confirmed_route IS NOT NULL AND active = TRUE;
