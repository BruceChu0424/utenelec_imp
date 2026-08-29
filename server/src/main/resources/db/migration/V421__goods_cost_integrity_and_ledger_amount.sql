-- V421: make stock ledger value authoritative for inventory reporting and
-- prevent negative/out-of-range goods cost budgets at the database boundary.
--
-- Existing invalid rows are not silently overwritten.  The exact original
-- values and deterministic repair projection are inserted into audit_log
-- before goods is updated; audit_log is preserved by business-data resets.

CREATE TEMP TABLE goods_cost_v421_repair ON COMMIT DROP AS
WITH candidates AS (
    SELECT g.*,
           jsonb_build_object(
               'source_e', source_e,
               'work_e', work_e,
               'lacquer_e', lacquer_e,
               'incidental_e', incidental_e,
               'plating_e', plating_e,
               'casing_e', casing_e,
               'manage_e', manage_e,
               'polish_e', polish_e,
               'electric_e', electric_e,
               'machining_e', machining_e,
               'lost_e', lost_e,
               'rent_e', rent_e,
               'make_e', make_e,
               'work_rate', work_rate,
               'lost_rate', lost_rate,
               'make_rate', make_rate,
               'rent_rate', rent_rate,
               'total', total,
               'c_total', c_total,
               'g_total', g_total
           ) AS original_values
    FROM goods g
    WHERE (source_e IS NOT NULL AND NOT (source_e BETWEEN 0 AND 99999999999999.9999))
       OR (work_e IS NOT NULL AND NOT (work_e BETWEEN 0 AND 99999999999999.9999))
       OR (lacquer_e IS NOT NULL AND NOT (lacquer_e BETWEEN 0 AND 99999999999999.9999))
       OR (incidental_e IS NOT NULL AND NOT (incidental_e BETWEEN 0 AND 99999999999999.9999))
       OR (plating_e IS NOT NULL AND NOT (plating_e BETWEEN 0 AND 99999999999999.9999))
       OR (casing_e IS NOT NULL AND NOT (casing_e BETWEEN 0 AND 99999999999999.9999))
       OR (manage_e IS NOT NULL AND NOT (manage_e BETWEEN 0 AND 99999999999999.9999))
       OR (polish_e IS NOT NULL AND NOT (polish_e BETWEEN 0 AND 99999999999999.9999))
       OR (electric_e IS NOT NULL AND NOT (electric_e BETWEEN 0 AND 99999999999999.9999))
       OR (machining_e IS NOT NULL AND NOT (machining_e BETWEEN 0 AND 99999999999999.9999))
       OR (lost_e IS NOT NULL AND NOT (lost_e BETWEEN 0 AND 99999999999999.9999))
       OR (rent_e IS NOT NULL AND NOT (rent_e BETWEEN 0 AND 99999999999999.9999))
       OR (make_e IS NOT NULL AND NOT (make_e BETWEEN 0 AND 99999999999999.9999))
       OR (total IS NOT NULL AND NOT (total BETWEEN 0 AND 99999999999999.9999))
       OR (c_total IS NOT NULL AND NOT (c_total BETWEEN 0 AND 99999999999999.9999))
       OR (g_total IS NOT NULL AND NOT (g_total BETWEEN 0 AND 99999999999999.9999))
       OR (work_rate IS NOT NULL AND NOT (work_rate BETWEEN 0 AND 100))
       OR (lost_rate IS NOT NULL AND NOT (lost_rate BETWEEN 0 AND 100))
       OR (make_rate IS NOT NULL AND NOT (make_rate BETWEEN 0 AND 100))
       OR (rent_rate IS NOT NULL AND NOT (rent_rate BETWEEN 0 AND 100))
),
normalized AS (
    SELECT id,
           original_values,
           CASE WHEN source_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(source_e, 0), 99999999999999.9999) END AS source_e,
           CASE WHEN lacquer_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(lacquer_e, 0), 99999999999999.9999) END AS lacquer_e,
           CASE WHEN incidental_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(incidental_e, 0), 99999999999999.9999) END AS incidental_e,
           CASE WHEN plating_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(plating_e, 0), 99999999999999.9999) END AS plating_e,
           CASE WHEN casing_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(casing_e, 0), 99999999999999.9999) END AS casing_e,
           CASE WHEN manage_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(manage_e, 0), 99999999999999.9999) END AS manage_e,
           CASE WHEN polish_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(polish_e, 0), 99999999999999.9999) END AS polish_e,
           CASE WHEN electric_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(electric_e, 0), 99999999999999.9999) END AS electric_e,
           CASE WHEN machining_e IS NULL THEN NULL
                ELSE LEAST(GREATEST(machining_e, 0), 99999999999999.9999) END AS machining_e,
           CASE WHEN work_rate IS NULL THEN NULL
                ELSE LEAST(GREATEST(work_rate, 0), 100) END AS work_rate,
           CASE WHEN lost_rate IS NULL THEN NULL
                ELSE LEAST(GREATEST(lost_rate, 0), 100) END AS lost_rate,
           CASE WHEN rent_rate IS NULL THEN NULL
                ELSE LEAST(GREATEST(rent_rate, 0), 100) END AS rent_rate,
           CASE WHEN make_rate IS NULL THEN NULL
                ELSE LEAST(GREATEST(make_rate, 0), 100) END AS make_rate
    FROM candidates
),
base_cost AS (
    SELECT n.*,
           ROUND(LEAST(
               COALESCE(source_e, 0)
               + COALESCE(machining_e, 0)
               + COALESCE(incidental_e, 0)
               + COALESCE(lacquer_e, 0)
               + COALESCE(plating_e, 0)
               + COALESCE(casing_e, 0)
               + COALESCE(polish_e, 0),
               99999999999999.9999), 4) AS total
    FROM normalized n
),
burden_cost AS (
    SELECT b.*,
           ROUND(LEAST(total * COALESCE(work_rate, 0) / 100,
                       99999999999999.9999), 4) AS work_e,
           ROUND(LEAST(total * COALESCE(lost_rate, 0) / 100,
                       99999999999999.9999), 4) AS lost_e,
           ROUND(LEAST(total * COALESCE(rent_rate, 0) / 100,
                       99999999999999.9999), 4) AS rent_e
    FROM base_cost b
),
total_cost AS (
    SELECT b.*,
           ROUND(LEAST(total + work_e + lost_e + rent_e,
                       99999999999999.9999), 4) AS c_total
    FROM burden_cost b
),
profit_cost AS (
    SELECT t.*,
           ROUND(LEAST(c_total * COALESCE(make_rate, 0) / 100,
                       99999999999999.9999), 4) AS make_e
    FROM total_cost t
)
SELECT p.*,
       ROUND(LEAST(c_total + make_e, 99999999999999.9999), 4) AS g_total
FROM profit_cost p;

-- Evidence is written before the repair.  Recovery is a controlled forward
-- migration that restores the values under before.values for the target id.
INSERT INTO audit_log (
    actor_account,
    action,
    target_type,
    target_id,
    before,
    "after",
    result,
    event_source,
    device_capture_status
)
SELECT 'flyway:V421',
       'update',
       'goods_cost_integrity',
       r.id::TEXT,
       jsonb_build_object(
           'reason', 'NEGATIVE_OR_OUT_OF_RANGE_GOODS_COST_OR_RATE',
           'severity', 'high',
           'values', r.original_values
       ),
       jsonb_build_object(
           'strategy', 'CLAMP_INPUTS_AND_RECOMPUTE_DERIVED_COSTS_V1',
           'recovery_source', 'audit_log.before.values',
           'values', jsonb_build_object(
               'source_e', r.source_e,
               'work_e', r.work_e,
               'lacquer_e', r.lacquer_e,
               'incidental_e', r.incidental_e,
               'plating_e', r.plating_e,
               'casing_e', r.casing_e,
               'manage_e', r.manage_e,
               'polish_e', r.polish_e,
               'electric_e', r.electric_e,
               'machining_e', r.machining_e,
               'lost_e', r.lost_e,
               'rent_e', r.rent_e,
               'make_e', r.make_e,
               'work_rate', r.work_rate,
               'lost_rate', r.lost_rate,
               'make_rate', r.make_rate,
               'rent_rate', r.rent_rate,
               'total', r.total,
               'c_total', r.c_total,
               'g_total', r.g_total
           )
       ),
       'success',
       'migration',
       'legacy'
FROM goods_cost_v421_repair r;

UPDATE goods g
SET source_e = r.source_e,
    work_e = r.work_e,
    lacquer_e = r.lacquer_e,
    incidental_e = r.incidental_e,
    plating_e = r.plating_e,
    casing_e = r.casing_e,
    manage_e = r.manage_e,
    polish_e = r.polish_e,
    electric_e = r.electric_e,
    machining_e = r.machining_e,
    lost_e = r.lost_e,
    rent_e = r.rent_e,
    make_e = r.make_e,
    work_rate = r.work_rate,
    lost_rate = r.lost_rate,
    make_rate = r.make_rate,
    rent_rate = r.rent_rate,
    total = r.total,
    c_total = r.c_total,
    g_total = r.g_total,
    updated_at = now()
FROM goods_cost_v421_repair r
WHERE g.id = r.id;

ALTER TABLE goods
    ADD CONSTRAINT goods_cost_amount_range_chk CHECK (
        (source_e IS NULL OR source_e BETWEEN 0 AND 99999999999999.9999)
        AND (work_e IS NULL OR work_e BETWEEN 0 AND 99999999999999.9999)
        AND (lacquer_e IS NULL OR lacquer_e BETWEEN 0 AND 99999999999999.9999)
        AND (incidental_e IS NULL OR incidental_e BETWEEN 0 AND 99999999999999.9999)
        AND (plating_e IS NULL OR plating_e BETWEEN 0 AND 99999999999999.9999)
        AND (casing_e IS NULL OR casing_e BETWEEN 0 AND 99999999999999.9999)
        AND (manage_e IS NULL OR manage_e BETWEEN 0 AND 99999999999999.9999)
        AND (polish_e IS NULL OR polish_e BETWEEN 0 AND 99999999999999.9999)
        AND (electric_e IS NULL OR electric_e BETWEEN 0 AND 99999999999999.9999)
        AND (machining_e IS NULL OR machining_e BETWEEN 0 AND 99999999999999.9999)
        AND (lost_e IS NULL OR lost_e BETWEEN 0 AND 99999999999999.9999)
        AND (rent_e IS NULL OR rent_e BETWEEN 0 AND 99999999999999.9999)
        AND (make_e IS NULL OR make_e BETWEEN 0 AND 99999999999999.9999)
        AND (total IS NULL OR total BETWEEN 0 AND 99999999999999.9999)
        AND (c_total IS NULL OR c_total BETWEEN 0 AND 99999999999999.9999)
        AND (g_total IS NULL OR g_total BETWEEN 0 AND 99999999999999.9999)
    ) NOT VALID,
    ADD CONSTRAINT goods_cost_rate_range_chk CHECK (
        (work_rate IS NULL OR work_rate BETWEEN 0 AND 100)
        AND (lost_rate IS NULL OR lost_rate BETWEEN 0 AND 100)
        AND (make_rate IS NULL OR make_rate BETWEEN 0 AND 100)
        AND (rent_rate IS NULL OR rent_rate BETWEEN 0 AND 100)
    ) NOT VALID;

ALTER TABLE goods VALIDATE CONSTRAINT goods_cost_amount_range_chk;
ALTER TABLE goods VALIDATE CONSTRAINT goods_cost_rate_range_chk;

COMMENT ON CONSTRAINT goods_cost_amount_range_chk ON goods IS
    'V421: all goods cost amounts are finite NUMERIC(18,4) values in the nonnegative storage range';
COMMENT ON CONSTRAINT goods_cost_rate_range_chk ON goods IS
    'V421: goods cost percentages are limited to the business range 0..100';
