-- =====================================================================
-- 币种主档迁移：CSV → currencies（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --currency-data
-- 前提：currencies 表已存在（V42 由 server Flyway 创建）。
-- 来源：老库 B_Currency（3 条：人民币/美金/港币），扁平表。
--   字段映射：ID→legacy_id、Number→code、CurName→name、ExRate→exchange_rate、Status→status。
--   name 做 BTRIM（含全角空格）+ 空串→NULL。其余原样保留（ExRate=0 也照搬，实际汇率在单据上）。
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
-- CASCADE：采购单据表 FK 引用 currencies，重跑时连同清空（须配合 --purchase 重灌采购）
TRUNCATE currencies CASCADE;
SET session_replication_role = DEFAULT;

CREATE TEMP TABLE currency_stage (
    legacy_id     int,
    code          text,          -- Number
    name          text,          -- CurName
    exchange_rate numeric(18,6), -- ExRate
    status        text           -- Status
);
\copy currency_stage FROM '/tmp/currency.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO currencies (legacy_id, code, name, exchange_rate, status, auto_created)
SELECT
    legacy_id,
    code,
    NULLIF(BTRIM(name, ' ' || chr(12288)), ''),   -- 去首尾半角/全角空白，空串→NULL
    exchange_rate,
    status,
    FALSE
FROM currency_stage;

COMMIT;

SELECT '✔ 币种 总 ' || count(*) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') AS 结果
FROM currencies;
