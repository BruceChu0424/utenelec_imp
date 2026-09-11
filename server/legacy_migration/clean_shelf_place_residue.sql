-- =====================================================================
-- 货架库位残值治理：把 goods.stock_place 中不符合「库行-层-位」三段格式的值置空
-- =====================================================================
-- 背景（docs/数据迁移/17 §十二「老库残值治理」）：货品迁移会把老库 B_Goods.StockPlace
--   的历史残值（'18' / '19' / '20' / 'Y12' 等内部代码）原样带入 goods.stock_place。
--   这些值不是仓库现场的库位号；2026-09-10 起货架清单页把它们归入「未分层」桶
--   （不再冒充库行进下拉），但主档里仍应清掉，否则货品资料/报表「库位号」列继续误导。
--
-- 口径（与 ShelfPlaceParser / ShelfLabelSql 同一规则）：
--   合法 = BTRIM 后匹配 ^[A-Za-z]*[0-9]+-[0-9]+-[0-9]+$ 且层/位段不超过 6 位。
--   其余非空值 = 残值 → 置空（NULL）。已软删货品不动。
--
-- 用法（人工确认两步，不是 Flyway 迁移，不进 migrate.sh --bootstrap-all）：
--   1) 演练（只对账不改数，末尾自动 ROLLBACK）：
--        docker exec -i <pg容器> psql -U <user> -d <db> -v ON_ERROR_STOP=1 \
--            -f - < server/legacy_migration/clean_shelf_place_residue.sql
--   2) 仓库确认对账清单里没有真实非标库位（如 Y12 是否实物存在）后，带 confirm 变量执行：
--        docker exec -i <pg容器> psql -U <user> -d <db> -v ON_ERROR_STOP=1 -v confirm=1 \
--            -f - < server/legacy_migration/clean_shelf_place_residue.sql
--   执行前请先 pg_dump goods 表（或整库）留档；audit_log 触发器会记录每行 stock_place 变更
--  （AuditEventInterpreter 已把 stock_place 译为「库位号」），可追溯不可自动回滚。
--   若某个残值确为真实库位，先在货品资料改成三段格式（如 Y12 → A31-3-1）再跑本脚本。
-- =====================================================================

BEGIN;

CREATE TEMP TABLE shelf_place_residue ON COMMIT DROP AS
SELECT g.id,
       g.code,
       g.name,
       g.stock_place,
       g.status
  FROM goods g
 WHERE g.is_deleted = false
   AND NULLIF(BTRIM(g.stock_place), '') IS NOT NULL
   AND NOT (
         BTRIM(g.stock_place) ~ '^[A-Za-z]*[0-9]+-[0-9]+-[0-9]+$'
         AND length(split_part(BTRIM(g.stock_place), '-', 2)) <= 6
         AND length(split_part(BTRIM(g.stock_place), '-', 3)) <= 6
       );

-- 对账 1：残值明细（人工核对：是否有真实非标库位混在里面）
SELECT '残值明细' AS section, code, name, stock_place, status
  FROM shelf_place_residue
 ORDER BY stock_place, code;

-- 对账 2：按值汇总
SELECT '残值汇总' AS section, stock_place, COUNT(*) AS goods_count
  FROM shelf_place_residue
 GROUP BY stock_place
 ORDER BY goods_count DESC, stock_place;

-- 对账 3：治理前后主档库位号计数（安全网：合法行数不应变化）
SELECT '治理前' AS phase,
       COUNT(*) FILTER (WHERE NULLIF(BTRIM(stock_place), '') IS NOT NULL) AS with_place,
       (SELECT COUNT(*) FROM shelf_place_residue)                          AS residue,
       COUNT(*) FILTER (WHERE NULLIF(BTRIM(stock_place), '') IS NOT NULL)
         - (SELECT COUNT(*) FROM shelf_place_residue)                      AS valid_place
  FROM goods
 WHERE is_deleted = false;

\if :{?confirm}
    UPDATE goods g
       SET stock_place = NULL,
           updated_at  = now()
      FROM shelf_place_residue r
     WHERE g.id = r.id;

    SELECT '治理后' AS phase,
           COUNT(*) FILTER (WHERE NULLIF(BTRIM(stock_place), '') IS NOT NULL) AS with_place,
           0                                                                 AS residue,
           COUNT(*) FILTER (WHERE NULLIF(BTRIM(stock_place), '') IS NOT NULL) AS valid_place
      FROM goods
     WHERE is_deleted = false;

    COMMIT;
\else
    SELECT '演练模式：未改任何数据（带 -v confirm=1 才执行 UPDATE）' AS notice;
    ROLLBACK;
\endif
