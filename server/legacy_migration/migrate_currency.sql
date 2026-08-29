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
SELECT set_config('app.business_identifier_legacy_import', 'on', true);

CREATE TEMP TABLE currency_stage (
    legacy_id     int,
    code          text,          -- Number
    name          text,          -- CurName
    exchange_rate numeric(18,6), -- ExRate
    status        text           -- Status
) ON COMMIT DROP;
\copy currency_stage FROM '/tmp/currency.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

DO $$
DECLARE
    v_rmb_count INTEGER;
    v_duplicate_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_duplicate_count
    FROM (
        SELECT legacy_id
        FROM currency_stage
        GROUP BY legacy_id
        HAVING legacy_id IS NULL OR COUNT(*) <> 1
    ) invalid;
    IF v_duplicate_count <> 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'currency import requires non-null unique legacy_id values';
    END IF;

    SELECT COUNT(*) INTO v_rmb_count
    FROM currency_stage
    WHERE legacy_id = 1 AND status = '使用';
    IF v_rmb_count <> 1 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                'currency import requires exactly one active legacy_id=1 functional currency row; found %s',
                v_rmb_count);
    END IF;
END;
$$;

-- Preserve the V403 functional-currency UUID and every historical FK.  The
-- source legacy_id is the stable import key; a reload updates labels/reference
-- data in place and inserts only previously unseen legacy rows.
INSERT INTO currencies (legacy_id, code, name, exchange_rate, status, auto_created)
SELECT
    legacy_id,
    code,
    NULLIF(BTRIM(name, ' ' || chr(12288)), ''),   -- 去首尾半角/全角空白，空串→NULL
    exchange_rate,
    status,
    FALSE
FROM currency_stage
ON CONFLICT (legacy_id) DO UPDATE
SET code = CASE
        -- V403 empty-install seed already owns its lifetime-reserved CNY code.
        -- Preserve that UUID/code identity; legacy_id remains the import key.
        WHEN currencies.is_base_currency THEN currencies.code
        ELSE EXCLUDED.code
    END,
    name = EXCLUDED.name,
    exchange_rate = EXCLUDED.exchange_rate,
    status = EXCLUDED.status,
    auto_created = FALSE,
    is_deleted = FALSE,
    deleted_at = NULL,
    updated_at = now();

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM currencies WHERE is_base_currency) <> 1
       OR NOT EXISTS (
           SELECT 1 FROM currencies
           WHERE is_base_currency AND legacy_id = 1
             AND status = '使用' AND COALESCE(is_deleted, FALSE) = FALSE
       ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'currency import changed or lost the V403 functional-currency UUID authority';
    END IF;
END;
$$;

COMMIT;

SELECT '✔ 币种 总 ' || count(*) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') AS 结果
FROM currencies;
