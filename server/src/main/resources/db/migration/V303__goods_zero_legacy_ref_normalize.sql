-- =====================================================================
-- V303：goods 表 color_legacy_id / unit_legacy_id 的老库哨兵 0 归一化为 NULL。
-- 老库 B_Goods.Color / Unit 的 0 = 「未设置」（B_Color/B_Unit 均无 ID=0 行，
-- colors.legacy_id 实测范围 343-697），迁移时关系列已按 NULLIF(...,0) 解析，
-- 但 legacy 快照列原样保留了 0，导致列表/facets 的悬空引用兜底把 0 渲染成 "#0"。
-- 全代码库对 0 与 NULL 的处理完全等价（GoodsService.clearsReference、
-- migrate_reconciliation.sql 的 <> 0 条件），归一化不改变任何行为。
-- 注意：production_plan_costs.parent_legacy_id 的 0 是「BOM 顶层行」哨兵，不在此列。
-- 重跑幂等（UPDATE 命中的本就是 0）。
-- =====================================================================

UPDATE goods SET color_legacy_id = NULL WHERE color_legacy_id = 0;
UPDATE goods SET unit_legacy_id  = NULL WHERE unit_legacy_id  = 0;

-- 校验（日志可见）：SELECT count(*) FROM goods WHERE color_legacy_id = 0 OR unit_legacy_id = 0;  -- 期望 0
