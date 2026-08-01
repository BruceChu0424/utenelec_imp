-- =====================================================================
-- V182: live master-reference UUID hardening (additive, migration-safe).
--
-- V181 first isolates legacy auto-created goods from the operational BOM.
-- This migration then establishes UUID lanes for current master-data reads:
--   * goods -> unit/color/mould/client/default + secondary supplier;
--   * goods_bom_items -> color/default supplier;
--   * moulds -> department/keeper (constraints omitted by applied V180);
--   * stock_documents -> supplier/client and current employee UUIDs;
--     legacy maker/approver names remain Sys_Operator snapshots.
--
-- Safety contract:
--   * every new relationship column remains nullable;
--   * legacy/text columns remain untouched for traceability and rollback;
--   * backfill uses only a UNIQUE legacy_id equality, never a name match;
--   * all new foreign keys and data checks are NOT VALID in this release;
--   * V180 duplicate-name choices are cleared and recorded for manual mapping;
--   * migration-time issues are written to the V129/V134 audit structures;
--   * SUCCESS below means this SQL completed. PASSED is used only when the
--     current database contains source references and every recorded metric
--     passes. A fresh pre-import database remains NOT_RUN.
--
-- No approved document, production fulfilment row, cost expansion, stock
-- movement, or other historical snapshot is rewritten by this migration.
-- =====================================================================

-- ============================ additive UUID lanes ============================

ALTER TABLE goods
    ADD COLUMN unit_id               UUID,
    ADD COLUMN color_id              UUID,
    ADD COLUMN mould_id              UUID,
    ADD COLUMN client_id             UUID,
    ADD COLUMN default_supplier_id   UUID,
    ADD COLUMN secondary_supplier_id UUID;

ALTER TABLE goods_bom_items
    ADD COLUMN color_id            UUID,
    ADD COLUMN default_supplier_id UUID;

ALTER TABLE stock_documents
    ADD COLUMN maker_name_snapshot    TEXT,
    ADD COLUMN approver_name_snapshot TEXT;

CREATE INDEX idx_goods_unit_id
    ON goods(unit_id) WHERE unit_id IS NOT NULL;
CREATE INDEX idx_goods_color_id
    ON goods(color_id) WHERE color_id IS NOT NULL;
CREATE INDEX idx_goods_mould_id
    ON goods(mould_id) WHERE mould_id IS NOT NULL;
CREATE INDEX idx_goods_client_id
    ON goods(client_id) WHERE client_id IS NOT NULL;
CREATE INDEX idx_goods_default_supplier_id
    ON goods(default_supplier_id) WHERE default_supplier_id IS NOT NULL;
CREATE INDEX idx_goods_secondary_supplier_id
    ON goods(secondary_supplier_id) WHERE secondary_supplier_id IS NOT NULL;

CREATE INDEX idx_goods_bom_color_id
    ON goods_bom_items(color_id) WHERE color_id IS NOT NULL;
CREATE INDEX idx_goods_bom_default_supplier_id
    ON goods_bom_items(default_supplier_id)
    WHERE default_supplier_id IS NOT NULL;

CREATE INDEX idx_stock_documents_supplier_id
    ON stock_documents(supplier_id) WHERE supplier_id IS NOT NULL;
CREATE INDEX idx_stock_documents_client_id
    ON stock_documents(client_id) WHERE client_id IS NOT NULL;
CREATE INDEX idx_stock_documents_worker_id
    ON stock_documents(worker_id) WHERE worker_id IS NOT NULL;
CREATE INDEX idx_stock_documents_maker_id
    ON stock_documents(maker_id) WHERE maker_id IS NOT NULL;
CREATE INDEX idx_stock_documents_approver_id
    ON stock_documents(approver_id) WHERE approver_id IS NOT NULL;

-- stock_documents has audit/business triggers. PostgreSQL cannot ALTER this
-- table later in the same transaction after its backfill has queued trigger
-- events, so install its NOT VALID FKs before touching any stock row.
ALTER TABLE stock_documents
    ADD CONSTRAINT fk_stock_documents_supplier
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_stock_documents_client
        FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_stock_documents_worker
        FOREIGN KEY (worker_id) REFERENCES employees(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_stock_documents_maker
        FOREIGN KEY (maker_id) REFERENCES employees(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_stock_documents_approver
        FOREIGN KEY (approver_id) REFERENCES employees(id) ON DELETE RESTRICT NOT VALID;

-- ======================= deterministic legacy_id backfill ====================
-- Master legacy_id columns are unique. Zero is a documented empty sentinel and
-- is never converted into a fabricated UUID target.

UPDATE goods g
SET unit_id = u.id
FROM units u
WHERE g.unit_id IS NULL
  AND g.unit_legacy_id IS NOT NULL
  AND g.unit_legacy_id <> 0
  AND u.legacy_id = g.unit_legacy_id;

UPDATE goods g
SET color_id = c.id
FROM colors c
WHERE g.color_id IS NULL
  AND g.color_legacy_id IS NOT NULL
  AND g.color_legacy_id <> 0
  AND c.legacy_id = g.color_legacy_id;

UPDATE goods g
SET mould_id = m.id
FROM moulds m
WHERE g.mould_id IS NULL
  AND g.mould_legacy_id IS NOT NULL
  AND g.mould_legacy_id <> 0
  AND m.legacy_id = g.mould_legacy_id;

UPDATE goods g
SET client_id = c.id
FROM clients c
WHERE g.client_id IS NULL
  AND g.client_legacy_id IS NOT NULL
  AND g.client_legacy_id <> 0
  AND c.legacy_id = g.client_legacy_id;

UPDATE goods g
SET default_supplier_id = s.id
FROM suppliers s
WHERE g.default_supplier_id IS NULL
  AND g.vend_legacy_id IS NOT NULL
  AND g.vend_legacy_id <> 0
  AND s.legacy_id = g.vend_legacy_id;

UPDATE goods g
SET secondary_supplier_id = s.id
FROM suppliers s
WHERE g.secondary_supplier_id IS NULL
  AND g.vend2_legacy_id IS NOT NULL
  AND g.vend2_legacy_id <> 0
  AND s.legacy_id = g.vend2_legacy_id;

UPDATE goods_bom_items bi
SET color_id = c.id
FROM colors c
WHERE bi.color_id IS NULL
  AND bi.color_legacy_id IS NOT NULL
  AND bi.color_legacy_id <> 0
  AND c.legacy_id = bi.color_legacy_id;

UPDATE goods_bom_items bi
SET default_supplier_id = s.id
FROM suppliers s
WHERE bi.default_supplier_id IS NULL
  AND bi.vend_legacy_id IS NOT NULL
  AND bi.vend_legacy_id <> 0
  AND s.legacy_id = bi.vend_legacy_id;

-- worker_legacy_id is a B_Worker.ID and employees.legacy_id is its unique
-- fusion key. maker_legacy_id/approver_legacy_id are Sys_Operator.ID values:
-- those integer namespaces overlap and therefore MUST NOT be mapped here.
UPDATE stock_documents d
SET worker_id = e.id
FROM employees e
WHERE d.worker_id IS NULL
  AND d.worker_legacy_id IS NOT NULL
  AND d.worker_legacy_id <> 0
  AND e.legacy_id = d.worker_legacy_id;

-- ==================== audited ambiguity/orphan handling ======================
-- The applied V180 used DISTINCT ON(name), which can silently select one of
-- several departments/employees. V182 does not attempt another name mapping.
-- It records affected mould IDs without storing names/PII, clears only those
-- ambiguous or physically orphaned UUIDs, and retains place/keeper text.

DO $$
DECLARE
    v_run_id              UUID := gen_random_uuid();
    v_issue_count         BIGINT := 0;
    v_source_ref_count    BIGINT := 0;
    v_failed_metric_count BIGINT := 0;
BEGIN
    INSERT INTO legacy_migration_runs (
        run_id,
        target,
        status,
        migration_mode,
        mapping_version,
        reconciliation_status,
        reconciliation_summary
    ) VALUES (
        v_run_id,
        'schema:V182-live-master-relationships',
        'RUNNING',
        'INCREMENTAL',
        'v182-live-master-uuid-v1',
        'RUNNING',
        jsonb_build_object(
            'scope', 'current database relationship rows at Flyway execution time',
            'postImportReconciliationRequired', true
        )
    );

    -- V180 department names that currently identify more than one active row.
    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT
        v_run_id,
        'moulds',
        m.id::TEXT || ':department_id',
        'MOULD_DEPARTMENT_NAME_AMBIGUOUS',
        'V180 selected from a non-unique active department name; UUID cleared. candidate_count='
            || duplicate_name.candidate_count
    FROM moulds m
    JOIN (
        SELECT name, COUNT(*) AS candidate_count
        FROM departments
        WHERE is_deleted = FALSE
          AND name IS NOT NULL
          AND btrim(name) <> ''
        GROUP BY name
        HAVING COUNT(*) > 1
    ) duplicate_name ON duplicate_name.name = m.place
    WHERE m.department_id IS NOT NULL;

    UPDATE moulds m
    SET department_id = NULL
    FROM (
        SELECT name
        FROM departments
        WHERE is_deleted = FALSE
          AND name IS NOT NULL
          AND btrim(name) <> ''
        GROUP BY name
        HAVING COUNT(*) > 1
    ) duplicate_name
    WHERE duplicate_name.name = m.place
      AND m.department_id IS NOT NULL;

    -- V180 keeper names that currently identify more than one active employee.
    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT
        v_run_id,
        'moulds',
        m.id::TEXT || ':keeper_id',
        'MOULD_KEEPER_NAME_AMBIGUOUS',
        'V180 selected from a non-unique active employee name; UUID cleared. candidate_count='
            || duplicate_name.candidate_count
    FROM moulds m
    JOIN (
        SELECT full_name, COUNT(*) AS candidate_count
        FROM employees
        WHERE is_deleted = FALSE
          AND full_name IS NOT NULL
          AND btrim(full_name) <> ''
        GROUP BY full_name
        HAVING COUNT(*) > 1
    ) duplicate_name ON duplicate_name.full_name = m.keeper
    WHERE m.keeper_id IS NOT NULL;

    UPDATE moulds m
    SET keeper_id = NULL
    FROM (
        SELECT full_name
        FROM employees
        WHERE is_deleted = FALSE
          AND full_name IS NOT NULL
          AND btrim(full_name) <> ''
        GROUP BY full_name
        HAVING COUNT(*) > 1
    ) duplicate_name
    WHERE duplicate_name.full_name = m.keeper
      AND m.keeper_id IS NOT NULL;

    -- A UUID with no target cannot be retained as a usable live relationship.
    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT
        v_run_id,
        'moulds',
        m.id::TEXT || ':department_id',
        'MOULD_DEPARTMENT_UUID_ORPHAN',
        'department_id has no departments target; UUID cleared and place text retained'
    FROM moulds m
    WHERE m.department_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM departments d WHERE d.id = m.department_id
      );

    UPDATE moulds m
    SET department_id = NULL
    WHERE m.department_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM departments d WHERE d.id = m.department_id
      );

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT
        v_run_id,
        'moulds',
        m.id::TEXT || ':keeper_id',
        'MOULD_KEEPER_UUID_ORPHAN',
        'keeper_id has no employees target; UUID cleared and keeper text retained'
    FROM moulds m
    WHERE m.keeper_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM employees e WHERE e.id = m.keeper_id
      );

    UPDATE moulds m
    SET keeper_id = NULL
    WHERE m.keeper_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM employees e WHERE e.id = m.keeper_id
      );

    -- Deterministic legacy references that still have no UUID target.
    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods',
           g.id::TEXT || ':unit_legacy_id=' || g.unit_legacy_id,
           'GOODS_UNIT_LEGACY_UNMAPPED',
           'non-zero unit_legacy_id has no units.legacy_id target'
    FROM goods g
    WHERE g.unit_id IS NULL
      AND g.unit_legacy_id IS NOT NULL
      AND g.unit_legacy_id <> 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods',
           g.id::TEXT || ':color_legacy_id=' || g.color_legacy_id,
           'GOODS_COLOR_LEGACY_UNMAPPED',
           'non-zero color_legacy_id has no colors.legacy_id target'
    FROM goods g
    WHERE g.color_id IS NULL
      AND g.color_legacy_id IS NOT NULL
      AND g.color_legacy_id <> 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods',
           g.id::TEXT || ':mould_legacy_id=' || g.mould_legacy_id,
           'GOODS_MOULD_LEGACY_UNMAPPED',
           'non-zero mould_legacy_id has no moulds.legacy_id target'
    FROM goods g
    WHERE g.mould_id IS NULL
      AND g.mould_legacy_id IS NOT NULL
      AND g.mould_legacy_id <> 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods',
           g.id::TEXT || ':client_legacy_id=' || g.client_legacy_id,
           'GOODS_CLIENT_LEGACY_UNMAPPED',
           'non-zero client_legacy_id has no clients.legacy_id target'
    FROM goods g
    WHERE g.client_id IS NULL
      AND g.client_legacy_id IS NOT NULL
      AND g.client_legacy_id <> 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods',
           g.id::TEXT || ':vend_legacy_id=' || g.vend_legacy_id,
           'GOODS_DEFAULT_SUPPLIER_LEGACY_UNMAPPED',
           'non-zero vend_legacy_id has no suppliers.legacy_id target'
    FROM goods g
    WHERE g.default_supplier_id IS NULL
      AND g.vend_legacy_id IS NOT NULL
      AND g.vend_legacy_id <> 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods',
           g.id::TEXT || ':vend2_legacy_id=' || g.vend2_legacy_id,
           'GOODS_SECONDARY_SUPPLIER_LEGACY_UNMAPPED',
           'non-zero vend2_legacy_id has no suppliers.legacy_id target'
    FROM goods g
    WHERE g.secondary_supplier_id IS NULL
      AND g.vend2_legacy_id IS NOT NULL
      AND g.vend2_legacy_id <> 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods_bom_items',
           bi.id::TEXT || ':color_legacy_id=' || bi.color_legacy_id,
           'GOODS_BOM_COLOR_LEGACY_UNMAPPED',
           'non-zero color_legacy_id has no colors.legacy_id target'
    FROM goods_bom_items bi
    WHERE bi.color_id IS NULL
      AND bi.color_legacy_id IS NOT NULL
      AND bi.color_legacy_id <> 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods_bom_items',
           bi.id::TEXT || ':vend_legacy_id=' || bi.vend_legacy_id,
           'GOODS_BOM_SUPPLIER_LEGACY_UNMAPPED',
           'non-zero vend_legacy_id has no suppliers.legacy_id target'
    FROM goods_bom_items bi
    WHERE bi.default_supplier_id IS NULL
      AND bi.vend_legacy_id IS NOT NULL
      AND bi.vend_legacy_id <> 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'stock_documents',
           d.id::TEXT || ':worker_legacy_id=' || d.worker_legacy_id,
           'STOCK_WORKER_LEGACY_UNMAPPED',
           'non-zero worker_legacy_id has no employees.legacy_id target'
    FROM stock_documents d
    WHERE d.worker_id IS NULL
      AND d.worker_legacy_id IS NOT NULL
      AND d.worker_legacy_id <> 0;

    -- Existing UUID orphans are retained for explicit repair; NOT VALID keeps
    -- them visible while immediately protecting future inserts/UUID changes.
    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'stock_documents', d.id::TEXT || ':supplier_id',
           'STOCK_SUPPLIER_UUID_ORPHAN',
           'supplier_id has no suppliers target; retained pending repair'
    FROM stock_documents d
    WHERE d.supplier_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.id = d.supplier_id);

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'stock_documents', d.id::TEXT || ':client_id',
           'STOCK_CLIENT_UUID_ORPHAN',
           'client_id has no clients target; retained pending repair'
    FROM stock_documents d
    WHERE d.client_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM clients c WHERE c.id = d.client_id);

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'stock_documents', d.id::TEXT || ':worker_id',
           'STOCK_WORKER_UUID_ORPHAN',
           'worker_id has no employees target; retained pending repair'
    FROM stock_documents d
    WHERE d.worker_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = d.worker_id);

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'stock_documents', d.id::TEXT || ':maker_id',
           'STOCK_MAKER_UUID_ORPHAN',
           'maker_id has no employees target; retained pending repair'
    FROM stock_documents d
    WHERE d.maker_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = d.maker_id);

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'stock_documents', d.id::TEXT || ':approver_id',
           'STOCK_APPROVER_UUID_ORPHAN',
           'approver_id has no employees target; retained pending repair'
    FROM stock_documents d
    WHERE d.approver_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = d.approver_id);

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods_bom_items', bi.id::TEXT || ':qty',
           'GOODS_BOM_NON_POSITIVE_QTY',
           'qty must be greater than zero before the V182 check can be validated'
    FROM goods_bom_items bi
    WHERE bi.qty <= 0;

    INSERT INTO legacy_migration_rejects (
        run_id, source_entity, source_identifier, reason_code, reason_detail
    )
    SELECT v_run_id, 'goods_bom_items', bi.id::TEXT || ':component_goods_id',
           'GOODS_BOM_SELF_REFERENCE',
           'goods_id equals component_goods_id; relationship retained pending repair'
    FROM goods_bom_items bi
    WHERE bi.goods_id = bi.component_goods_id;

    -- Coverage metrics are scoped to relationships present now. They do not
    -- certify source-file completeness or the later destructive re-import.
    INSERT INTO legacy_migration_reconciliation_items (
        run_id, source_entity, target_entity, metric,
        expected_value, actual_value, passed, detail
    )
    SELECT
        v_run_id,
        'goods.*_legacy_id',
        'goods.*_id',
        'deterministic_nonzero_reference_coverage',
        counts.expected_count,
        counts.actual_count,
        counts.expected_count = counts.actual_count,
        'UUID must resolve to a master row whose legacy_id equals the retained source value'
    FROM (
        SELECT
            COUNT(*) FILTER (WHERE g.unit_legacy_id IS NOT NULL AND g.unit_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.color_legacy_id IS NOT NULL AND g.color_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.mould_legacy_id IS NOT NULL AND g.mould_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.client_legacy_id IS NOT NULL AND g.client_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.vend_legacy_id IS NOT NULL AND g.vend_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.vend2_legacy_id IS NOT NULL AND g.vend2_legacy_id <> 0)
                AS expected_count,
            COUNT(*) FILTER (WHERE g.unit_legacy_id IS NOT NULL AND g.unit_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM units u WHERE u.id = g.unit_id AND u.legacy_id = g.unit_legacy_id))
          + COUNT(*) FILTER (WHERE g.color_legacy_id IS NOT NULL AND g.color_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM colors c WHERE c.id = g.color_id AND c.legacy_id = g.color_legacy_id))
          + COUNT(*) FILTER (WHERE g.mould_legacy_id IS NOT NULL AND g.mould_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM moulds m WHERE m.id = g.mould_id AND m.legacy_id = g.mould_legacy_id))
          + COUNT(*) FILTER (WHERE g.client_legacy_id IS NOT NULL AND g.client_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM clients c WHERE c.id = g.client_id AND c.legacy_id = g.client_legacy_id))
          + COUNT(*) FILTER (WHERE g.vend_legacy_id IS NOT NULL AND g.vend_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM suppliers s WHERE s.id = g.default_supplier_id AND s.legacy_id = g.vend_legacy_id))
          + COUNT(*) FILTER (WHERE g.vend2_legacy_id IS NOT NULL AND g.vend2_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM suppliers s WHERE s.id = g.secondary_supplier_id AND s.legacy_id = g.vend2_legacy_id))
                AS actual_count
        FROM goods g
    ) counts;

    INSERT INTO legacy_migration_reconciliation_items (
        run_id, source_entity, target_entity, metric,
        expected_value, actual_value, passed, detail
    )
    SELECT
        v_run_id,
        'goods_bom_items.*_legacy_id',
        'goods_bom_items.*_id',
        'deterministic_nonzero_reference_coverage',
        counts.expected_count,
        counts.actual_count,
        counts.expected_count = counts.actual_count,
        'Includes active and V181-isolated historical BOM rows; no row is reactivated'
    FROM (
        SELECT
            COUNT(*) FILTER (WHERE bi.color_legacy_id IS NOT NULL AND bi.color_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE bi.vend_legacy_id IS NOT NULL AND bi.vend_legacy_id <> 0)
                AS expected_count,
            COUNT(*) FILTER (WHERE bi.color_legacy_id IS NOT NULL AND bi.color_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM colors c WHERE c.id = bi.color_id AND c.legacy_id = bi.color_legacy_id))
          + COUNT(*) FILTER (WHERE bi.vend_legacy_id IS NOT NULL AND bi.vend_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM suppliers s WHERE s.id = bi.default_supplier_id AND s.legacy_id = bi.vend_legacy_id))
                AS actual_count
        FROM goods_bom_items bi
    ) counts;

    INSERT INTO legacy_migration_reconciliation_items (
        run_id, source_entity, target_entity, metric,
        expected_value, actual_value, passed, detail
    )
    SELECT
        v_run_id,
        'stock_documents.worker_legacy_id',
        'stock_documents.worker_id',
        'deterministic_b_worker_reference_coverage',
        counts.expected_count,
        counts.actual_count,
        counts.expected_count = counts.actual_count,
        'worker_legacy_id is B_Worker.ID; maker/approver legacy IDs are Sys_Operator snapshots and are excluded'
    FROM (
        SELECT
            COUNT(*) FILTER (WHERE d.worker_legacy_id IS NOT NULL AND d.worker_legacy_id <> 0)
                AS expected_count,
            COUNT(*) FILTER (WHERE d.worker_legacy_id IS NOT NULL AND d.worker_legacy_id <> 0
                AND EXISTS (SELECT 1 FROM employees e WHERE e.id = d.worker_id AND e.legacy_id = d.worker_legacy_id))
                AS actual_count
        FROM stock_documents d
    ) counts;

    SELECT COUNT(*)
    INTO v_issue_count
    FROM legacy_migration_rejects r
    WHERE r.run_id = v_run_id;

    INSERT INTO legacy_migration_reconciliation_items (
        run_id, source_entity, target_entity, metric,
        expected_value, actual_value, passed, detail
    ) VALUES (
        v_run_id,
        'V182 current database',
        'live UUID relationships',
        'recorded_relationship_issue_count',
        0,
        v_issue_count,
        v_issue_count = 0,
        'Every issue remains reviewable in legacy_migration_rejects; no waiver is created'
    );

    SELECT
        (SELECT
            COUNT(*) FILTER (WHERE g.unit_legacy_id IS NOT NULL AND g.unit_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.color_legacy_id IS NOT NULL AND g.color_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.mould_legacy_id IS NOT NULL AND g.mould_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.client_legacy_id IS NOT NULL AND g.client_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.vend_legacy_id IS NOT NULL AND g.vend_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE g.vend2_legacy_id IS NOT NULL AND g.vend2_legacy_id <> 0)
         FROM goods g)
      + (SELECT
            COUNT(*) FILTER (WHERE bi.color_legacy_id IS NOT NULL AND bi.color_legacy_id <> 0)
          + COUNT(*) FILTER (WHERE bi.vend_legacy_id IS NOT NULL AND bi.vend_legacy_id <> 0)
         FROM goods_bom_items bi)
      + (SELECT
            COUNT(*) FILTER (WHERE d.worker_legacy_id IS NOT NULL AND d.worker_legacy_id <> 0)
         FROM stock_documents d)
      + (SELECT COUNT(*) FROM goods_bom_items)
      + (SELECT COUNT(*) FROM moulds m
         WHERE m.department_id IS NOT NULL OR m.keeper_id IS NOT NULL)
      + (SELECT COUNT(*) FROM stock_documents d
         WHERE d.supplier_id IS NOT NULL
            OR d.client_id IS NOT NULL
            OR d.worker_id IS NOT NULL
            OR d.maker_id IS NOT NULL
            OR d.approver_id IS NOT NULL)
    INTO v_source_ref_count;

    SELECT COUNT(*)
    INTO v_failed_metric_count
    FROM legacy_migration_reconciliation_items i
    WHERE i.run_id = v_run_id
      AND i.passed = FALSE;

    UPDATE legacy_migration_runs
    SET status = 'SUCCESS',
        finished_at = CURRENT_TIMESTAMP,
        exit_code = 0,
        reconciliation_status = CASE
            WHEN v_issue_count > 0 OR v_failed_metric_count > 0 THEN 'FAILED'
            WHEN v_source_ref_count = 0 THEN 'NOT_RUN'
            ELSE 'PASSED'
        END,
        reconciliation_summary = jsonb_build_object(
            'scope', 'current database relationship rows at Flyway execution time',
            'sourceReferenceCount', v_source_ref_count,
            'issueCount', v_issue_count,
            'failedMetricCount', v_failed_metric_count,
            'postImportReconciliationRequired', true,
            'productionAcceptance', false
        ),
        rejected_count = v_issue_count
    WHERE run_id = v_run_id;
END
$$;

-- ======================== future-write constraints ===========================
-- NOT VALID protects every new insert/reference change immediately while
-- preserving visibility of existing issues until a later validation migration.

ALTER TABLE goods
    ADD CONSTRAINT fk_goods_unit_live
        FOREIGN KEY (unit_id) REFERENCES units(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_goods_color_live
        FOREIGN KEY (color_id) REFERENCES colors(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_goods_mould_live
        FOREIGN KEY (mould_id) REFERENCES moulds(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_goods_client_live
        FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_goods_default_supplier_live
        FOREIGN KEY (default_supplier_id) REFERENCES suppliers(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_goods_secondary_supplier_live
        FOREIGN KEY (secondary_supplier_id) REFERENCES suppliers(id) ON DELETE RESTRICT NOT VALID;

ALTER TABLE goods_bom_items
    ADD CONSTRAINT fk_goods_bom_color_live
        FOREIGN KEY (color_id) REFERENCES colors(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_goods_bom_default_supplier_live
        FOREIGN KEY (default_supplier_id) REFERENCES suppliers(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT goods_bom_qty_positive_chk
        CHECK (qty > 0) NOT VALID,
    ADD CONSTRAINT goods_bom_no_self_component_chk
        CHECK (goods_id <> component_goods_id) NOT VALID;

ALTER TABLE moulds
    ADD CONSTRAINT fk_mould_department_live
        FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT fk_mould_keeper_live
        FOREIGN KEY (keeper_id) REFERENCES employees(id) ON DELETE RESTRICT NOT VALID;

COMMENT ON COLUMN goods.unit_id IS
    '当前基本单位（units.id）；unit_legacy_id 保留为迁移溯源，不再作为最终运行时真源';
COMMENT ON COLUMN goods.color_id IS
    '当前主颜色（colors.id）；color_legacy_id 保留为迁移溯源';
COMMENT ON COLUMN goods.mould_id IS
    '当前默认模具（moulds.id）；mould_legacy_id 保留为迁移溯源';
COMMENT ON COLUMN goods.client_id IS
    '当前关联客户（clients.id）；client_legacy_id 保留为迁移溯源';
COMMENT ON COLUMN goods.default_supplier_id IS
    '当前默认供应商（suppliers.id）；vend_legacy_id 保留为迁移溯源';
COMMENT ON COLUMN goods.secondary_supplier_id IS
    '当前第二供应商（suppliers.id）；vend2_legacy_id 保留为迁移溯源';
COMMENT ON COLUMN goods_bom_items.color_id IS
    '当前组件颜色（colors.id）；color_legacy_id 保留为迁移溯源';
COMMENT ON COLUMN goods_bom_items.default_supplier_id IS
    '当前组件默认供应商（suppliers.id）；vend_legacy_id 保留为迁移溯源';

COMMENT ON COLUMN stock_documents.worker_id IS
    '当前经办/领料/退料/跟单员工（employees.id）；可由 B_Worker worker_legacy_id 精确回填';
COMMENT ON COLUMN stock_documents.worker_legacy_id IS
    '老库经办/领料/退料/跟单 B_Worker.ID；与 employees.legacy_id 同一命名空间';
COMMENT ON COLUMN stock_documents.maker_id IS
    '新系统当前制单员工（employees.id）；不得由旧 Sys_Operator maker_legacy_id 回填';
COMMENT ON COLUMN stock_documents.approver_id IS
    '新系统当前审核员工（employees.id）；不得由旧 Sys_Operator approver_legacy_id 回填';
COMMENT ON COLUMN stock_documents.maker_legacy_id IS
    '老库制单 Sys_Operator.ID；仅用于溯源，不得匹配 employees.legacy_id';
COMMENT ON COLUMN stock_documents.approver_legacy_id IS
    '老库审核 Sys_Operator.ID；仅用于溯源，不得匹配 employees.legacy_id';
COMMENT ON COLUMN stock_documents.maker_name_snapshot IS
    '历史制单员姓名快照（迁移时按 maker_legacy_id 精确读取 Sys_Operator.fname）';
COMMENT ON COLUMN stock_documents.approver_name_snapshot IS
    '历史审核员姓名快照（迁移时按 approver_legacy_id 精确读取 Sys_Operator.fname）';

COMMENT ON CONSTRAINT goods_bom_qty_positive_chk ON goods_bom_items IS
    'V182 NOT VALID 门禁；现存异常先进入迁移 reject，修复后由后续迁移 VALIDATE';
COMMENT ON CONSTRAINT goods_bom_no_self_component_chk ON goods_bom_items IS
    '禁止 BOM 直接自引用；多层环仍由无深度上限的写入侧递归校验治理';
