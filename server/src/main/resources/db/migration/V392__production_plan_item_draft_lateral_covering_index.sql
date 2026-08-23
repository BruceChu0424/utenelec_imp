-- V392: 销售候选/物料分析列表的“在制草稿”LATERAL 覆盖索引。
-- MaterialAnalysisService 的销售候选查询对每行 sales_order_item 执行
-- LEFT JOIN LATERAL (SELECT SUM(pi.qty) ... WHERE pi.sales_order_item_id = i.id
--   AND pi.is_deleted = FALSE ...)：idx_ppi_soitem 命中后仍需回表取 plan_id/qty。
-- 部分覆盖索引让该子查询走 index-only scan，列表页规模下消除逐行堆读。
-- active_analysis LATERAL 已由 idx_production_material_analysis_item_sales 覆盖，无需新增。

CREATE INDEX idx_ppi_soitem_alive_covering
    ON production_plan_items(sales_order_item_id)
    INCLUDE (plan_id, qty)
    WHERE is_deleted = FALSE;
