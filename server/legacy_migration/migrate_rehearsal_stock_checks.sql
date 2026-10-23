-- Local rehearsal balance validation. Append to migrate_stock_docs.sql BEFORE
-- compose_bootstrap removes that loader's temporary staging tables.
-- Business tables are read-only here. Only the current RUNNING bootstrap run's
-- reconciliation_summary is updated after every validation has passed.
-- No quantity checksum across different units is reported as inventory volume.

DO $rehearsal_stock_preconditions$
BEGIN
    IF to_regclass('pg_temp.latest_stock_balance_stage') IS NULL
       OR to_regclass('pg_temp.legacy_latest_balance_stage') IS NULL
       OR to_regclass('pg_temp.warehouse_target_stage') IS NULL
       OR to_regclass('pg_temp.goods_split_warehouse_stage') IS NULL
       OR to_regclass('pg_temp.bootstrap_warehouse_exclusions') IS NULL THEN
        RAISE EXCEPTION 'stock rehearsal checks must run before stock staging cleanup';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM legacy_migration_runs
        WHERE run_id = NULLIF(current_setting('uten.bootstrap_run_id', true), '')::uuid
          AND status = 'RUNNING' AND migration_mode = 'BOOTSTRAP'
    ) THEN
        RAISE EXCEPTION 'stock rehearsal checks require the current running bootstrap claim';
    END IF;
    IF EXISTS (SELECT 1 FROM warehouse_target_stage GROUP BY legacy_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM goods_split_warehouse_stage GROUP BY goods_legacy_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM legacy_latest_balance_stage
                   GROUP BY stock_legacy, goods_legacy, color_legacy HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'stock source resolution contains duplicate source keys';
    END IF;
    IF EXISTS (SELECT 1 FROM latest_stock_balance_stage
               WHERE warehouse_id IS NULL OR goods_id IS NULL OR fact_qty IS NULL OR total IS NULL)
       OR EXISTS (SELECT 1 FROM latest_stock_balance_stage
                   GROUP BY warehouse_id, goods_id, color_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM stock_balances
                   GROUP BY warehouse_id, goods_id, color_id HAVING count(*) > 1) THEN
        -- GROUP BY treats NULL colors as one dimension, unlike a nullable
        -- equality join that could overlook duplicate no-color balances.
        RAISE EXCEPTION 'stock balances contain invalid or duplicate dimensions, including no-color keys';
    END IF;
END;
$rehearsal_stock_preconditions$;

CREATE TEMP TABLE rehearsal_stock_source_resolution ON COMMIT DROP AS
SELECT latest.stock_legacy, latest.goods_legacy, latest.color_legacy, latest.year,
       latest.fact_qty, latest.total,
       target.action,
       CASE WHEN target.action = 'SPLIT' THEN split.warehouse_id ELSE target.warehouse_id END AS warehouse_id,
       material.id AS goods_id,
       color.id AS color_id,
       CASE WHEN target.action = 'DROP' THEN 'DROPPED_WAREHOUSE_BALANCE'
            WHEN target.action = 'SPLIT' AND split.warehouse_id IS NULL THEN 'UNASSIGNED_OWNING_WAREHOUSE'
            ELSE NULL END AS expected_exclusion
FROM legacy_latest_balance_stage latest
LEFT JOIN warehouse_target_stage target ON target.legacy_id = latest.stock_legacy
LEFT JOIN goods material ON material.legacy_id = latest.goods_legacy
LEFT JOIN colors color ON color.legacy_id = NULLIF(latest.color_legacy, 0)
LEFT JOIN goods_split_warehouse_stage split ON split.goods_legacy_id = latest.goods_legacy;

DO $rehearsal_stock_source_guard$
BEGIN
    IF EXISTS (
        SELECT 1 FROM rehearsal_stock_source_resolution
        WHERE (fact_qty <> 0 OR total <> 0)
          AND (action IS NULL OR action NOT IN ('SPLIT', 'KEEP', 'MERGE', 'DROP')
               OR (expected_exclusion IS NULL AND
                   (warehouse_id IS NULL OR goods_id IS NULL
                    OR (NULLIF(color_legacy, 0) IS NOT NULL AND color_id IS NULL))))
    ) THEN
        RAISE EXCEPTION 'nonzero stock facts have an unresolved source or target dimension';
    END IF;
END;
$rehearsal_stock_source_guard$;

-- Independently reconstruct the loader's final grouping. This catches missing
-- staging keys as well as incorrect amounts/quantities that a check against the
-- loader's own expected table alone would repeat without detecting.
CREATE TEMP TABLE rehearsal_stock_expected ON COMMIT DROP AS
SELECT warehouse_id, goods_id, color_id,
       sum(fact_qty) AS fact_qty, sum(total) AS amount_local
FROM rehearsal_stock_source_resolution
WHERE expected_exclusion IS NULL AND action <> 'DROP'
  AND warehouse_id IS NOT NULL AND goods_id IS NOT NULL
GROUP BY warehouse_id, goods_id, color_id;

CREATE TEMP TABLE rehearsal_stock_expected_exclusions ON COMMIT DROP AS
SELECT jsonb_build_object('stock_legacy', stock_legacy, 'goods_legacy', goods_legacy,
                          'color_legacy', color_legacy, 'year', year) AS source_key,
       stock_legacy AS legacy_warehouse_id, goods_legacy AS goods_legacy_id,
       expected_exclusion AS reason, fact_qty AS qty, total AS amount
FROM rehearsal_stock_source_resolution
WHERE expected_exclusion IS NOT NULL AND (fact_qty <> 0 OR total <> 0);

CREATE TEMP TABLE rehearsal_stock_actual_exclusions ON COMMIT DROP AS
SELECT source_row_id::jsonb AS source_key, legacy_warehouse_id, goods_legacy_id, reason, qty, amount
FROM bootstrap_warehouse_exclusions
WHERE source_file = 'stock_goods.csv';

DO $rehearsal_stock_key_checks$
BEGIN
    -- EXCEPT ALL compares nullable colors exactly and retains multiplicity.
    -- It also avoids a FULL JOIN on IS NOT DISTINCT FROM, which PostgreSQL
    -- cannot implement as a normal full hash/merge join on all versions.
    IF EXISTS (
        (SELECT warehouse_id, goods_id, color_id, fact_qty, amount_local FROM rehearsal_stock_expected
         EXCEPT ALL
         SELECT warehouse_id, goods_id, color_id, fact_qty, total FROM latest_stock_balance_stage)
        UNION ALL
        (SELECT warehouse_id, goods_id, color_id, fact_qty, total FROM latest_stock_balance_stage
         EXCEPT ALL
         SELECT warehouse_id, goods_id, color_id, fact_qty, amount_local FROM rehearsal_stock_expected)
    ) THEN
        RAISE EXCEPTION 'stock loader grouping differs from independently resolved source facts';
    END IF;
    IF EXISTS (
        (SELECT warehouse_id, goods_id, color_id, fact_qty, amount_local
           FROM rehearsal_stock_expected WHERE fact_qty <> 0
         EXCEPT ALL
         SELECT warehouse_id, goods_id, color_id, qty, amount_local FROM stock_balances)
        UNION ALL
        (SELECT warehouse_id, goods_id, color_id, qty, amount_local FROM stock_balances
         EXCEPT ALL
         SELECT warehouse_id, goods_id, color_id, fact_qty, amount_local
           FROM rehearsal_stock_expected WHERE fact_qty <> 0)
    ) THEN
        RAISE EXCEPTION 'stock balance dimensions, signed quantities or amounts do not match source facts';
    END IF;
    IF EXISTS (
        (SELECT * FROM rehearsal_stock_expected_exclusions
         EXCEPT ALL SELECT * FROM rehearsal_stock_actual_exclusions)
        UNION ALL
        (SELECT * FROM rehearsal_stock_actual_exclusions
         EXCEPT ALL SELECT * FROM rehearsal_stock_expected_exclusions)
    ) THEN
        RAISE EXCEPTION 'stock warehouse exclusions omit, duplicate or change original source facts';
    END IF;
    IF (SELECT COALESCE(sum(total), 0) FROM rehearsal_stock_source_resolution)
       IS DISTINCT FROM
       ((SELECT COALESCE(sum(amount_local), 0) FROM rehearsal_stock_expected)
        + (SELECT COALESCE(sum(amount), 0) FROM rehearsal_stock_expected_exclusions)) THEN
        RAISE EXCEPTION 'stock amount checksum is not conserved across routed and excluded facts';
    END IF;
END;
$rehearsal_stock_key_checks$;

CREATE TEMP TABLE rehearsal_stock_weight_evidence ON COMMIT DROP AS
SELECT balance.warehouse_id, balance.goods_id, balance.color_id,
       balance.qty, balance.weight, balance.weight_estimated,
       CASE WHEN profile.measurement_dimension = 'MASS' AND profile.mass_unit_code IS NOT NULL
            THEN fn_weight_unit_kg_factor(profile.mass_unit_code) ELSE NULL END AS kg_factor,
       CASE WHEN balance.qty > 0 AND profile.measurement_dimension = 'MASS'
                      AND fn_weight_unit_kg_factor(profile.mass_unit_code) IS NOT NULL
            THEN NULLIF(round(balance.qty * fn_weight_unit_kg_factor(profile.mass_unit_code), 4), 0)
            ELSE NULL END AS expected_weight
FROM stock_balances balance
JOIN goods material ON material.id = balance.goods_id
LEFT JOIN unit_measurement_profiles profile ON profile.unit_id = material.unit_id;

DO $rehearsal_stock_weight_checks$
BEGIN
    IF (SELECT count(*) FROM rehearsal_stock_weight_evidence) <> (SELECT count(*) FROM stock_balances)
       OR EXISTS (
           SELECT 1 FROM rehearsal_stock_weight_evidence
           WHERE weight IS DISTINCT FROM expected_weight OR weight_estimated IS DISTINCT FROM FALSE
       ) THEN
        -- The only calculable weight is a governed MASS unit's exact factor.
        -- Unknown legacy Weight/FactWeight is not assigned a kg interpretation;
        -- without such evidence we check only that weight remains unknown.
        RAISE EXCEPTION 'stock weight differs from governed mass-unit evidence or invents unknown weight';
    END IF;
END;
$rehearsal_stock_weight_checks$;

DO $rehearsal_stock_record_results$
DECLARE
    result JSONB;
    updated_rows INTEGER;
BEGIN
    SELECT jsonb_build_object(
        'passed', TRUE,
        'validationVersion', 'stock-dimension-facts-v1',
        'sourceLatestDimensionRows', (SELECT count(*) FROM legacy_latest_balance_stage),
        'routedGroupedKeys', (SELECT count(*) FROM rehearsal_stock_expected),
        'matchedNonzeroKeys', (SELECT count(*) FROM stock_balances),
        'matchedNoColorKeys', (SELECT count(*) FROM stock_balances WHERE color_id IS NULL),
        'duplicateNoColorGroups', 0,
        'negativeBalanceKeys', (SELECT count(*) FROM stock_balances WHERE qty < 0),
        'sourceAmountChecksum', (SELECT COALESCE(sum(total), 0) FROM legacy_latest_balance_stage),
        'retainedAmountChecksum', (SELECT COALESCE(sum(amount_local), 0) FROM stock_balances),
        'excludedAmountChecksum', (SELECT COALESCE(sum(amount), 0) FROM rehearsal_stock_expected_exclusions),
        'zeroQuantityGroupedKeys', (SELECT count(*) FROM rehearsal_stock_expected WHERE fact_qty = 0),
        'zeroQuantityNonzeroAmountKeys', (SELECT count(*) FROM rehearsal_stock_expected
                                         WHERE fact_qty = 0 AND amount_local <> 0),
        'zeroQuantityAmountChecksum', (SELECT COALESCE(sum(amount_local), 0)
                                       FROM rehearsal_stock_expected WHERE fact_qty = 0),
        'zeroQuantityPolicy', 'existing loader omits zero-quantity keys; any residual amount is reported separately',
        'massUnitWeightKeys', (SELECT count(*) FROM rehearsal_stock_weight_evidence WHERE kg_factor IS NOT NULL AND qty > 0),
        'unknownWeightKeys', (SELECT count(*) FROM rehearsal_stock_weight_evidence WHERE expected_weight IS NULL),
        'weightEvidencePolicy', 'governed MASS profile only; no inference from legacy Weight or FactWeight',
        'quantityComparisonPolicy', 'signed quantities compared for each warehouse/goods/color key; no mixed-unit volume total',
        'exclusionsByReason', (
            SELECT COALESCE(jsonb_agg(to_jsonb(grouped) ORDER BY reason), '[]'::jsonb)
            FROM (SELECT reason, count(*) AS rows, count(*) FILTER (WHERE qty < 0) AS negative_rows,
                         COALESCE(sum(amount), 0) AS amount_checksum
                    FROM rehearsal_stock_expected_exclusions GROUP BY reason) grouped)
    ) INTO result;
    UPDATE legacy_migration_runs
       SET reconciliation_summary = COALESCE(reconciliation_summary, '{}'::jsonb)
                                    || jsonb_build_object('stockBalanceChecks', result)
     WHERE run_id = NULLIF(current_setting('uten.bootstrap_run_id', true), '')::uuid
       AND status = 'RUNNING' AND migration_mode = 'BOOTSTRAP';
    GET DIAGNOSTICS updated_rows = ROW_COUNT;
    IF updated_rows <> 1 THEN
        RAISE EXCEPTION 'stock rehearsal check result does not belong to one running bootstrap claim';
    END IF;
END;
$rehearsal_stock_record_results$;
