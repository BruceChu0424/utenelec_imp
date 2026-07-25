-- =====================================================================
-- 仓库主档迁移：CSV → warehouses（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --warehouse-data
-- 前提：warehouses 表已存在（V43 由 server Flyway 创建）。
-- 来源：老库 B_Storage（6 条），扁平表。
--   字段映射：ID→legacy_id、Number→code、Storage_Name→name、Location→location、
--   Remark→remark、IsCal→is_accountable（bit，CSV 为 True/False，pg COPY 直接解析）、
--   WorkID→workshop_legacy_id、Status→status。
--   文本字段做 BTRIM + 空串→NULL。
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
-- CASCADE：采购单据表 FK 引用 warehouses，重跑时连同清空（须配合 --purchase 重灌采购）
TRUNCATE warehouses CASCADE;
SET session_replication_role = DEFAULT;

CREATE TEMP TABLE warehouse_stage (
    legacy_id          int,
    code               text,        -- Number
    name               text,        -- Storage_Name
    location           text,        -- Location
    remark             text,        -- Remark
    is_accountable     boolean,     -- IsCal
    workshop_legacy_id int,         -- WorkID
    status             text         -- Status
);
\copy warehouse_stage FROM '/tmp/warehouse.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO warehouses (legacy_id, code, name, location, remark, is_accountable, workshop_legacy_id, status, auto_created)
SELECT
    legacy_id,
    code,
    NULLIF(BTRIM(name, ' ' || chr(12288)), ''),
    NULLIF(BTRIM(location, ' ' || chr(12288)), ''),
    NULLIF(BTRIM(remark, ' ' || chr(12288)), ''),
    COALESCE(is_accountable, FALSE),
    NULLIF(workshop_legacy_id, 0),           -- 0 表示无车间 → NULL
    status,
    FALSE
FROM warehouse_stage;

COMMIT;

SELECT '✔ 仓库 总 ' || count(*) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') ||
       '，核算 ' || count(*) FILTER (WHERE is_accountable) AS 结果
FROM warehouses;
