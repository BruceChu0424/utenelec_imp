-- =====================================================================
-- 仓库主档迁移：CSV → warehouses（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --warehouse-data
-- 前提：V274 已应用（仓库车间 UUID 真源 + 明确旧仓库 ID 桥接表）。
-- 来源：老库 B_Storage（6 条），扁平表。
--   字段映射：ID→legacy_id、Number→code、Storage_Name→name、Location→location、
--   Remark→remark、IsCal→is_accountable（⚠ 取反：老库 IsCal=0=参与核算，bit 直迁语义反转）、
--   WorkID→legacy_operator_id（Sys_Operator.ID；旧误命名影子同步保留）、Status→status。
--   文本字段做 BTRIM + 空串→NULL。
-- =====================================================================

BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);
-- Never erase stock/documents as a side effect of a warehouse master reload.
-- Existing references make DELETE fail before any replacement row is read.
DELETE FROM warehouses;

CREATE TEMP TABLE warehouse_stage (
    legacy_id          int,
    code               text,        -- Number
    name               text,        -- Storage_Name
    location           text,        -- Location
    remark             text,        -- Remark
    is_accountable     boolean,     -- IsCal
    workshop_legacy_id int,         -- WorkID -> Sys_Operator.ID (compatibility snapshot)
    status             text         -- Status
) ON COMMIT DROP;
\copy warehouse_stage FROM '/tmp/warehouse.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO warehouses (
    legacy_id, code, name, location, remark, is_accountable, is_defective,
    workshop_legacy_id, legacy_operator_id, workshop_department_id,
    status, auto_created)
SELECT
    stage.legacy_id,
    stage.code,
    NULLIF(BTRIM(stage.name, ' ' || chr(12288)), ''),
    NULLIF(BTRIM(stage.location, ' ' || chr(12288)), ''),
    NULLIF(BTRIM(stage.remark, ' ' || chr(12288)), ''),
    -- ⚠ IsCal 语义反转：老库 IsCal=0 表示「参与库存核算」（View_StockGoods WHERE IsCal=0），
    --   bit 直迁会把 6 个真实仓全标成 false 导致即时库存「全部」查不到数据。
    --   故取反：IsCal=0 → TRUE（参与核算），IsCal=1 → FALSE。
    NOT COALESCE(stage.is_accountable, FALSE),
    -- V81：不良品仓标记（老库无字段，按名称识别，与存量回填同规则）
    COALESCE(stage.name, '') LIKE '%不良%',
    NULLIF(stage.workshop_legacy_id, 0),
    NULLIF(stage.workshop_legacy_id, 0),
    link.workshop_department_id,
    stage.status,
    FALSE
FROM warehouse_stage stage
-- Only a reviewed B_Storage.ID crosswalk may restore the UUID relationship.
-- B_Storage.WorkID is Sys_Operator.ID and must never be joined to workshops.
LEFT JOIN legacy_warehouse_workshop_links link
  ON link.warehouse_legacy_id = stage.legacy_id;

COMMIT;

SELECT '✔ 仓库 总 ' || count(*) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') ||
       '，核算 ' || count(*) FILTER (WHERE is_accountable) AS 结果
FROM warehouses;
