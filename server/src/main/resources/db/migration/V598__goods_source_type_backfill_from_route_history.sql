-- =====================================================================
-- V598 2026-09-16 货品「来源」按历史路线确认一次性回填 (goods.source_type)
-- =====================================================================
-- 背景：物料分析准备页里改「供应方式」一直只写进分析行的 confirmed_route，
--   货品主档 goods.source_type 从来没有被更新过；而新分析的建议路线又是从主档
--   算出来的 (MaterialAnalysisService.suggestion：采购 -> BUY、自制 -> MAKE、
--   委外 -> SUBCONTRACT)，于是 2026-09-16 用户实测「在物料分析准备页改了供应
--   方式，下次进来还是老的」。同批 Java 改动把供应方式收口成**货品主档单一
--   事实源**：确认路线同事务回写 goods.source_type、建议路线只读主档、按历史
--   分析推导的 /last-routes 记忆整套退役。
--
--   回写只对**今后**的确认生效，库里既有的确认路线不会倒灌，存量货品的主档
--   来源仍停在旧值/空值——本迁移把既有确认一次性种进主档。
--
-- 口径 (与旧 /last-routes 记忆一致：最近一次确认胜出)：
--   1. 只认 confirmed_route IS NOT NULL 的物料行，且它所属的分析未删除、未取消
--      (is_deleted = FALSE AND status <> 'CANCELLED')——作废的分析不是有效决定；
--      **停用行 (active = FALSE) 仍然算数**：刷新掉过的节点上那次确认是人做的，
--      旧记忆查询当年就是这么定的，不能因为节点被 BOM 变更刷掉就丢掉。
--   2. 每个货品 DISTINCT ON 取**最新一条**：按
--      COALESCE(route_confirmed_at, created_at) DESC 排序，跨颜色 / 单位 / 分析
--      一律取最新；并列到同一确认时刻时再按 created_at DESC、id DESC 兜底，
--      排序稳定、结果可复算。
--   3. 映射 BUY -> '采购'、MAKE -> '自制'、SUBCONTRACT -> '委外'。
--      goods.source_type 的值域见 V128：VARCHAR(20)、**没有 CHECK 约束**，
--      约定取值就是这三个中文词 (与前端编辑下拉 kGoodsSourceTypeOptions、
--      MaterialAnalysisService.sourceTypeForRoute 同一张表)，映射值全部落在
--      合法值域内。confirmed_route 的取值由 V234 的
--      production_material_analysis_material_route_chk 限死在这三个里，
--      CASE 不会漏到 NULL。
--
-- 为什么是「最新确认胜出」而不是像 V591 那样只填空：旧前端本就是**记忆优先于
--   主档** (未确认节点先读 /last-routes，读不到才回退主档)，用户一直看到的默认
--   值就是最近一次确认的路线。只填空会让存量货品的默认值在本次改版后倒退回
--   主档旧值，等于当着用户的面改掉他们的默认；「最新确认胜出」才让用户看到的
--   默认保持不变。已软删货品跳过 (is_deleted = FALSE)。
--
-- 顺序：全部是 UPDATE、无 DDL——**本迁移不受 goods 审计 / 行触发器的 ALTER
--   顺序限制** (V259/V587/V590/V591 同款规矩，触发器排队事件不与任何 ALTER
--   冲突)。幂等：值相同即被 IS DISTINCT FROM 短路，重放零行。
--
-- 不动的东西：本迁移只写 source_type 一列，不抬 version、不改 updated_at
--   (与 V591 同规矩：存量种值是系统行为，不是某个人的一次编辑)；也不触碰
--   goods 上任何其它列。
-- =====================================================================

UPDATE goods g
SET source_type = latest_route.source_type
FROM (
    SELECT DISTINCT ON (material.goods_id)
           material.goods_id,
           CASE material.confirmed_route
               WHEN 'BUY' THEN '采购'
               WHEN 'MAKE' THEN '自制'
               WHEN 'SUBCONTRACT' THEN '委外'
           END AS source_type
    FROM production_material_analysis_materials material
    JOIN production_material_analyses analysis
      ON analysis.id = material.analysis_id
     AND analysis.is_deleted = FALSE
     AND analysis.status <> 'CANCELLED'
    WHERE material.confirmed_route IS NOT NULL
    ORDER BY material.goods_id,
             COALESCE(material.route_confirmed_at, material.created_at) DESC,
             material.created_at DESC,
             material.id DESC
) latest_route
WHERE g.id = latest_route.goods_id
  AND g.is_deleted = FALSE
  AND latest_route.source_type IS NOT NULL
  AND g.source_type IS DISTINCT FROM latest_route.source_type;
