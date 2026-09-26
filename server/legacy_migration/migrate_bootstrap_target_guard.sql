-- First bootstrap only. Read the current reset classification as an inventory;
-- NEVER call business_data_reset(), truncate, delete or disable any constraint.
DO $$
DECLARE
    policy_row text[];
    policy_count integer := 0;
    occupied boolean;
BEGIN
    -- V182 itself records a zero-source schema audit on a fresh database.
    -- Preserve that exact successful audit; it is not a previous business import.
    IF EXISTS (SELECT 1 FROM legacy_migration_runs run WHERE
        run.run_id IS DISTINCT FROM NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid
        AND (run.status = 'FAILED' AND run.target='--bootstrap-all' AND run.migration_mode='BOOTSTRAP'
            AND run.finished_at IS NOT NULL AND run.exit_code IS NOT NULL
            AND run.mapping_version=current_setting('uten.bootstrap_mapping_version',true)
            AND run.migration_repository_commit=current_setting('uten.bootstrap_repository_commit',true)
            AND run.export_manifest_sha256=current_setting('uten.bootstrap_manifest_sha',true)
            AND run.reconciliation_summary->>'targetDatabase'=current_database()
            AND run.reconciliation_summary->>'targetSystemIdentifier'=(SELECT system_identifier::text FROM pg_control_system())
            AND run.reconciliation_summary->>'targetApprovalReference' IS NOT NULL
            AND run.reconciliation_summary->>'importAtomicity' = 'single-transaction-v1') IS NOT TRUE
        AND (run.target = 'schema:V182-live-master-relationships'
            AND run.migration_mode = 'INCREMENTAL' AND run.mapping_version = 'v182-live-master-uuid-v1'
            AND run.status = 'SUCCESS' AND run.reconciliation_status = 'NOT_RUN' AND run.rejected_count=0
            AND run.reconciliation_summary->>'sourceReferenceCount' = '0'
            AND run.reconciliation_summary->>'issueCount' = '0'
            AND run.reconciliation_summary->>'failedMetricCount' = '0') IS NOT TRUE)
       OR EXISTS (SELECT 1 FROM goods)
       OR EXISTS (SELECT 1 FROM moulds)
       OR EXISTS (SELECT 1 FROM clients)
       OR EXISTS (SELECT 1 FROM suppliers)
       OR EXISTS (SELECT 1 FROM accounts)
       OR EXISTS (SELECT 1 FROM colors)
       OR EXISTS (SELECT 1 FROM units)
       OR EXISTS (SELECT 1 FROM warehouses)
       OR EXISTS (SELECT 1 FROM currencies WHERE NOT is_base_currency)
       OR EXISTS (SELECT 1 FROM employees WHERE code <> 'ADMIN' OR legacy_id IS NOT NULL)
       -- V718 脱钩后注册表不再钉货品根；按本体身份放行未分类根，其余视为脏数据。
       OR EXISTS (SELECT 1 FROM material_categories
                  WHERE NOT (legacy_id = -1 AND legacy_code_snapshot = 'LEGACY_ORPHAN'))
       OR EXISTS (SELECT 1 FROM client_categories WHERE id NOT IN (SELECT client_category_id FROM system_master_category_registry))
       OR EXISTS (SELECT 1 FROM supplier_categories WHERE id NOT IN (SELECT supplier_category_id FROM system_master_category_registry))
       OR EXISTS (SELECT 1 FROM mould_categories WHERE id NOT IN (SELECT mould_category_id FROM system_master_category_registry))
       OR (SELECT count(*) FROM users) > 1 THEN
        RAISE EXCEPTION 'bootstrap requires a fresh schema-only target; restore/recreate the disposable target after a failed or different import (runs %, goods %, clients %, suppliers %, accounts %, colors %, units %, warehouses %, extra currencies %, employees %, categories %/%/%/%)',
            (SELECT count(*) FROM legacy_migration_runs), (SELECT count(*) FROM goods),
            (SELECT count(*) FROM clients), (SELECT count(*) FROM suppliers), (SELECT count(*) FROM accounts),
            (SELECT count(*) FROM colors), (SELECT count(*) FROM units), (SELECT count(*) FROM warehouses),
            (SELECT count(*) FROM currencies WHERE NOT is_base_currency),
            (SELECT count(*) FROM employees WHERE code <> 'ADMIN' OR legacy_id IS NOT NULL),
            (SELECT count(*) FROM material_categories), (SELECT count(*) FROM client_categories),
            (SELECT count(*) FROM supplier_categories), (SELECT count(*) FROM mould_categories);
    END IF;
    FOR policy_row IN
        SELECT regexp_matches(
            pg_get_functiondef('public.business_data_reset()'::regprocedure),
            '\(''([a-z_0-9]+)'',\s*''CLEAR''\)', 'g')
    LOOP
        policy_count := policy_count + 1;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I)', policy_row[1]) INTO occupied;
        IF occupied THEN
            RAISE EXCEPTION 'bootstrap target already contains business facts in %', policy_row[1];
        END IF;
    END LOOP;
    IF policy_count = 0 THEN
        RAISE EXCEPTION 'current business table inventory could not be verified';
    END IF;
END;
$$;
