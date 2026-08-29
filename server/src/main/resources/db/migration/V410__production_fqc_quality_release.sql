-- V410: production final-quality inspection (FQC) and qualified-release ledger.
--
-- New approved production reports are registered explicitly by the runtime
-- integration port.  This migration deliberately does not backfill historical
-- approved reports: absence of an inspection before V410 is not evidence that
-- a quality decision happened.  Existing FINISHED_IN / iqty history therefore
-- remains legacy evidence and is never relabelled as FQC PASS.
--
-- FQC does not mutate stock.  PASS quantity becomes eligible for a later
-- FINISHED_IN draft only through production_fqc_release_commands and its exact
-- PASS-event allocations.  The caller creates the stock line and registers it
-- through the integration port in the same transaction; FAIL quantity has no
-- release lot and can never satisfy this ledger.

CREATE TABLE production_fqc_inspections (
    id                                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_report_id                        UUID NOT NULL
        REFERENCES production_daily_reports(id) ON DELETE RESTRICT,
    source_report_item_id                   UUID NOT NULL UNIQUE
        REFERENCES production_daily_report_items(id) ON DELETE RESTRICT,
    source_plan_item_id                     UUID NOT NULL
        REFERENCES production_plan_items(id) ON DELETE RESTRICT,
    execution_segment_id                    UUID NOT NULL
        REFERENCES production_execution_segments(id) ON DELETE RESTRICT,
    execution_segment_sales_allocation_id   UUID
        REFERENCES execution_segment_sales_allocations(id) ON DELETE RESTRICT,
    warehouse_id                            UUID NOT NULL
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    goods_id                                UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                                UUID
        REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                                 UUID NOT NULL
        REFERENCES units(id) ON DELETE RESTRICT,
    unit_rate                               NUMERIC(18,6) NOT NULL,
    reported_qty                            NUMERIC(18,4) NOT NULL,
    passed_qty                              NUMERIC(18,4) NOT NULL DEFAULT 0,
    failed_qty                              NUMERIC(18,4) NOT NULL DEFAULT 0,
    status                                  TEXT NOT NULL DEFAULT 'PENDING',
    report_maker_id                         UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    created_by                              UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_inspection_qty_chk CHECK (
        reported_qty > 0
        AND passed_qty >= 0
        AND failed_qty >= 0
        AND passed_qty + failed_qty <= reported_qty),
    CONSTRAINT production_fqc_inspection_rate_chk CHECK (unit_rate > 0),
    CONSTRAINT production_fqc_inspection_status_chk CHECK (
        status IN ('PENDING', 'PARTIAL', 'RESOLVED')),
    CONSTRAINT production_fqc_inspection_status_projection_chk CHECK (
        (status = 'PENDING' AND passed_qty + failed_qty = 0)
        OR (status = 'PARTIAL'
            AND passed_qty + failed_qty > 0
            AND passed_qty + failed_qty < reported_qty)
        OR (status = 'RESOLVED'
            AND passed_qty + failed_qty = reported_qty)),
    CONSTRAINT production_fqc_inspection_report_pair_uk
        UNIQUE (source_report_id, source_report_item_id),
    CONSTRAINT production_fqc_inspection_item_pair_uk
        UNIQUE (id, source_report_item_id)
);

CREATE INDEX idx_production_fqc_inspection_workbench
    ON production_fqc_inspections(status, created_at, id)
    WHERE status IN ('PENDING', 'PARTIAL');
CREATE INDEX idx_production_fqc_inspection_report
    ON production_fqc_inspections(source_report_id, source_report_item_id);
CREATE INDEX idx_production_fqc_inspection_segment
    ON production_fqc_inspections(execution_segment_id, status, id);
CREATE INDEX idx_production_fqc_inspection_owner
    ON production_fqc_inspections(report_maker_id, status, created_at, id);

CREATE TABLE production_fqc_decision_events (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id            UUID NOT NULL
        REFERENCES production_fqc_inspections(id) ON DELETE RESTRICT,
    decision                 TEXT NOT NULL,
    pass_qty                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    fail_qty                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    disposition_code         TEXT,
    reason                   TEXT,
    idempotency_key          TEXT NOT NULL,
    request_hash             TEXT NOT NULL,
    decided_by_employee_id   UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    created_by               UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    decided_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_decision_value_chk CHECK (
        decision IN ('PASS', 'PARTIAL', 'FAIL')),
    CONSTRAINT production_fqc_decision_qty_chk CHECK (
        pass_qty >= 0 AND fail_qty >= 0 AND pass_qty + fail_qty > 0),
    CONSTRAINT production_fqc_decision_shape_chk CHECK (
        (decision = 'PASS'
            AND pass_qty > 0 AND fail_qty = 0
            AND disposition_code IS NULL)
        OR (decision = 'FAIL'
            AND pass_qty = 0 AND fail_qty > 0
            AND disposition_code IN ('REWORK', 'SCRAP', 'REJECT'))
        OR (decision = 'PARTIAL'
            AND pass_qty > 0 AND fail_qty > 0
            AND disposition_code IN ('REWORK', 'SCRAP', 'REJECT'))),
    CONSTRAINT production_fqc_decision_reason_chk CHECK (
        (decision = 'PASS'
            AND (reason IS NULL
                 OR length(btrim(reason)) BETWEEN 2 AND 1000))
        OR (decision IN ('PARTIAL', 'FAIL')
            AND reason IS NOT NULL
            AND length(btrim(reason)) BETWEEN 2 AND 1000)),
    CONSTRAINT production_fqc_decision_code_trim_chk CHECK (
        disposition_code IS NULL OR disposition_code = btrim(disposition_code)),
    CONSTRAINT production_fqc_decision_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128),
    CONSTRAINT production_fqc_decision_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT production_fqc_decision_idempotency_uk
        UNIQUE (inspection_id, idempotency_key),
    CONSTRAINT production_fqc_decision_inspection_id_uk
        UNIQUE (inspection_id, id)
);

CREATE INDEX idx_production_fqc_decision_timeline
    ON production_fqc_decision_events(inspection_id, decided_at, id);
CREATE INDEX idx_production_fqc_pass_release
    ON production_fqc_decision_events(inspection_id, decided_at, id)
    WHERE pass_qty > 0;

CREATE TABLE production_fqc_release_commands (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id               UUID NOT NULL,
    source_report_item_id       UUID NOT NULL,
    stock_document_item_id      UUID NOT NULL UNIQUE
        REFERENCES stock_document_items(id) ON DELETE RESTRICT,
    requested_qty               NUMERIC(18,4) NOT NULL,
    idempotency_key             TEXT NOT NULL,
    request_hash                TEXT NOT NULL,
    created_by                  UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_release_command_inspection_fk
        FOREIGN KEY (inspection_id, source_report_item_id)
        REFERENCES production_fqc_inspections(id, source_report_item_id)
        ON DELETE RESTRICT,
    CONSTRAINT production_fqc_release_command_qty_chk CHECK (requested_qty > 0),
    CONSTRAINT production_fqc_release_command_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 160),
    CONSTRAINT production_fqc_release_command_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT production_fqc_release_command_idempotency_uk
        UNIQUE (inspection_id, idempotency_key)
);

CREATE TABLE production_fqc_release_allocations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    release_command_id  UUID NOT NULL
        REFERENCES production_fqc_release_commands(id) ON DELETE RESTRICT,
    inspection_id       UUID NOT NULL,
    decision_event_id   UUID NOT NULL,
    qty                 NUMERIC(18,4) NOT NULL,
    created_by          UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_release_allocation_decision_fk
        FOREIGN KEY (inspection_id, decision_event_id)
        REFERENCES production_fqc_decision_events(inspection_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT production_fqc_release_allocation_qty_chk CHECK (qty > 0),
    CONSTRAINT production_fqc_release_allocation_pair_uk
        UNIQUE (release_command_id, decision_event_id)
);

CREATE INDEX idx_production_fqc_release_allocation_decision
    ON production_fqc_release_allocations(decision_event_id, release_command_id);

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_inspection()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    source_row RECORD;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'production FQC inspections cannot be deleted'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF current_setting('app.production_fqc_projection_id', TRUE)
               IS DISTINCT FROM OLD.id::text
           OR (to_jsonb(NEW) - ARRAY[
                    'passed_qty', 'failed_qty', 'status', 'updated_at'])
              IS DISTINCT FROM
              (to_jsonb(OLD) - ARRAY[
                    'passed_qty', 'failed_qty', 'status', 'updated_at']) THEN
            RAISE EXCEPTION 'production FQC inspection identity is immutable'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    SELECT report.status AS report_status,
           report.is_deleted AS report_deleted,
           report.warehouse_id AS report_warehouse_id,
           report.maker_id AS report_maker_id,
           item.report_id AS item_report_id,
           item.plan_item_id,
           item.execution_segment_id,
           item.execution_segment_sales_allocation_id,
           item.goods_id,
           item.color_id,
           item.unit_id,
           COALESCE(item.unit_rate, 1) AS unit_rate,
           item.qty,
           item.is_deleted AS item_deleted,
           segment.plan_id,
           segment.status AS segment_status,
           segment.is_deleted AS segment_deleted,
           package.status AS package_status,
           package.is_deleted AS package_deleted
    INTO source_row
    FROM production_daily_report_items item
    JOIN production_daily_reports report ON report.id = item.report_id
    JOIN production_execution_segments segment
      ON segment.id = item.execution_segment_id
    JOIN production_planning_packages package ON package.id = segment.package_id
    WHERE item.id = NEW.source_report_item_id;

    IF source_row IS NULL
       OR source_row.report_status <> 1
       OR source_row.report_deleted
       OR source_row.item_deleted
       OR source_row.report_warehouse_id IS NULL
       OR source_row.report_maker_id IS NULL
       OR source_row.item_report_id <> NEW.source_report_id
       OR source_row.plan_item_id IS DISTINCT FROM NEW.source_plan_item_id
       OR source_row.execution_segment_id IS DISTINCT FROM NEW.execution_segment_id
       OR source_row.execution_segment_sales_allocation_id
            IS DISTINCT FROM NEW.execution_segment_sales_allocation_id
       OR source_row.report_warehouse_id <> NEW.warehouse_id
       OR source_row.goods_id <> NEW.goods_id
       OR source_row.color_id IS DISTINCT FROM NEW.color_id
       OR source_row.unit_id <> NEW.unit_id
       OR source_row.unit_rate IS DISTINCT FROM NEW.unit_rate
       OR source_row.qty IS DISTINCT FROM NEW.reported_qty
       OR source_row.report_maker_id <> NEW.report_maker_id
       OR source_row.segment_status <> 'IN_PROGRESS'
       OR source_row.segment_deleted
       OR source_row.package_status <> 'CONFIRMED'
       OR source_row.package_deleted THEN
        RAISE EXCEPTION 'production FQC source report identity or state is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_source_report_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_fqc_inspection
    BEFORE INSERT OR UPDATE OR DELETE ON production_fqc_inspections
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_inspection();
ALTER TABLE production_fqc_inspections
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_inspection;

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_decision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    inspection production_fqc_inspections%ROWTYPE;
BEGIN
    SELECT * INTO inspection
    FROM production_fqc_inspections
    WHERE id = NEW.inspection_id
    FOR UPDATE;
    IF NOT FOUND OR inspection.status NOT IN ('PENDING', 'PARTIAL') THEN
        RAISE EXCEPTION 'production FQC inspection is no longer pending'
            USING ERRCODE = '23514';
    END IF;
    IF inspection.passed_qty + inspection.failed_qty
            + NEW.pass_qty + NEW.fail_qty > inspection.reported_qty THEN
        RAISE EXCEPTION 'production FQC decisions exceed reported quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_decision_capacity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_fqc_decision
    BEFORE INSERT ON production_fqc_decision_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_decision();

CREATE OR REPLACE FUNCTION fn_apply_production_fqc_decision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    next_resolved NUMERIC(18,4);
    reported NUMERIC(18,4);
BEGIN
    PERFORM set_config('app.production_fqc_projection_id', NEW.inspection_id::text, TRUE);
    SELECT reported_qty,
           passed_qty + failed_qty + NEW.pass_qty + NEW.fail_qty
    INTO reported, next_resolved
    FROM production_fqc_inspections
    WHERE id = NEW.inspection_id;
    UPDATE production_fqc_inspections
    SET passed_qty = passed_qty + NEW.pass_qty,
        failed_qty = failed_qty + NEW.fail_qty,
        status = CASE WHEN next_resolved = reported
                      THEN 'RESOLVED' ELSE 'PARTIAL' END,
        updated_at = now()
    WHERE id = NEW.inspection_id;
    PERFORM set_config('app.production_fqc_projection_id', '', TRUE);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_apply_production_fqc_decision
    AFTER INSERT ON production_fqc_decision_events
    FOR EACH ROW EXECUTE FUNCTION fn_apply_production_fqc_decision();

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'production FQC decision and release ledgers are append-only'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_guard_production_fqc_decision_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_decision_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_decision_events
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_decision_append_only;

CREATE TRIGGER trg_guard_production_fqc_release_command_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_release_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_release_commands
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_release_command_append_only;

CREATE TRIGGER trg_guard_production_fqc_release_allocation_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_release_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_release_allocations
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_release_allocation_append_only;

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_release_command()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    inspection production_fqc_inspections%ROWTYPE;
    stock_row RECORD;
BEGIN
    SELECT * INTO inspection
    FROM production_fqc_inspections
    WHERE id = NEW.inspection_id
    FOR UPDATE;
    SELECT item.bill_type, item.qty, item.reported_qty,
           item.source_daily_report_item_id, item.upstream_item_id,
           item.execution_segment_id,
           item.execution_segment_sales_allocation_id,
           item.goods_id, item.color_id, item.unit_id,
           COALESCE(item.unit_rate, 1) AS unit_rate,
           item.is_deleted AS item_deleted,
           document.doc_type, document.status AS document_status,
           document.source_daily_report_id,
           document.is_deleted AS document_deleted
    INTO stock_row
    FROM stock_document_items item
    JOIN stock_documents document ON document.id = item.doc_id
    WHERE item.id = NEW.stock_document_item_id;
    IF inspection.id IS NULL
       OR stock_row IS NULL
       OR stock_row.bill_type <> 'FINISHED_IN'
       OR stock_row.doc_type <> 'FINISHED_IN'
       OR stock_row.document_status <> 0
       OR stock_row.item_deleted
       OR stock_row.document_deleted
       OR stock_row.source_daily_report_id <> inspection.source_report_id
       OR stock_row.source_daily_report_item_id <> inspection.source_report_item_id
       OR stock_row.upstream_item_id <> inspection.source_plan_item_id
       OR stock_row.execution_segment_id <> inspection.execution_segment_id
       OR stock_row.execution_segment_sales_allocation_id
            IS DISTINCT FROM inspection.execution_segment_sales_allocation_id
       OR stock_row.goods_id <> inspection.goods_id
       OR stock_row.color_id IS DISTINCT FROM inspection.color_id
       OR stock_row.unit_id <> inspection.unit_id
       OR stock_row.unit_rate IS DISTINCT FROM inspection.unit_rate
       OR stock_row.qty IS DISTINCT FROM NEW.requested_qty
       OR COALESCE(stock_row.reported_qty, stock_row.qty)
            IS DISTINCT FROM NEW.requested_qty THEN
        RAISE EXCEPTION 'FINISHED_IN line does not match the FQC release source'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_finished_in_source_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_fqc_release_command
    BEFORE INSERT ON production_fqc_release_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_release_command();

CREATE OR REPLACE FUNCTION fn_validate_production_fqc_release_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    command_id UUID;
    decision_id UUID;
    command_qty NUMERIC(18,4);
    allocated_command_qty NUMERIC(18,4);
    pass_qty NUMERIC(18,4);
    allocated_pass_qty NUMERIC(18,4);
    command_inspection UUID;
    decision_inspection UUID;
BEGIN
    IF TG_TABLE_NAME = 'production_fqc_release_commands' THEN
        command_id := NEW.id;
        decision_id := NULL;
    ELSE
        command_id := NEW.release_command_id;
        decision_id := NEW.decision_event_id;
    END IF;

    SELECT requested_qty, inspection_id
    INTO command_qty, command_inspection
    FROM production_fqc_release_commands
    WHERE id = command_id;
    SELECT COALESCE(SUM(qty), 0)
    INTO allocated_command_qty
    FROM production_fqc_release_allocations
    WHERE release_command_id = command_id;
    IF command_qty IS NOT NULL
       AND allocated_command_qty IS DISTINCT FROM command_qty THEN
        RAISE EXCEPTION 'FQC release allocations must equal requested quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_release_command_total_guard';
    END IF;

    IF decision_id IS NOT NULL THEN
        SELECT pass_qty, inspection_id
        INTO pass_qty, decision_inspection
        FROM production_fqc_decision_events
        WHERE id = decision_id;
        SELECT COALESCE(SUM(qty), 0)
        INTO allocated_pass_qty
        FROM production_fqc_release_allocations
        WHERE decision_event_id = decision_id;
        IF pass_qty IS NULL
           OR pass_qty <= 0
           OR decision_inspection <> command_inspection
           OR allocated_pass_qty > pass_qty THEN
            RAISE EXCEPTION 'FQC FINISHED_IN allocation exceeds PASS quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_fqc_pass_capacity_guard';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_production_fqc_release_command
    AFTER INSERT ON production_fqc_release_commands
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_production_fqc_release_totals();
CREATE CONSTRAINT TRIGGER trg_validate_production_fqc_release_allocation
    AFTER INSERT ON production_fqc_release_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_production_fqc_release_totals();

CREATE TRIGGER trg_audit_production_fqc_inspections
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_inspections
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_decision_events
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_decision_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_release_commands
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_release_commands
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_release_allocations
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_release_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

INSERT INTO permissions(
    code, name, module, category, sort_order, action_type, description,
    active, assignable)
VALUES
    ('production_quality_inspection:view', '查看生产成品待检',
     '品质检测', '生产成品质检', 218, 'VIEW',
     '查看与本人生产单据或品质任务池相关的生产 FQC 待检和决定历史',
     TRUE, TRUE),
    ('production_quality_inspection:approve', '决定生产成品质检',
     '品质检测', '生产成品质检', 219, 'APPROVE',
     '按报工明细 UUID 对生产成品作 PASS、PARTIAL 或 FAIL 决定',
     TRUE, TRUE)
ON CONFLICT(code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = TRUE,
    assignable = TRUE;

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN (
    'production_quality_inspection:view',
    'production_quality_inspection:approve')
WHERE surface.surface_key = 'quality.inspection'
ON CONFLICT(surface_id, permission_id) DO NOTHING;

-- Production staff can read their owner-scoped quality result.  Only the QA
-- organization receives the pooled decision permission by default.
INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission
  ON permission.code = 'production_quality_inspection:view'
WHERE department.code IN ('DEPT_PROD', 'DEPT_QA')
  AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission
  ON permission.code = 'production_quality_inspection:approve'
WHERE department.code = 'DEPT_QA'
  AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

COMMENT ON TABLE production_fqc_inspections IS
    'One explicit FQC projection per post-V410 approved production report item; no historical backfill or inferred PASS';
COMMENT ON TABLE production_fqc_decision_events IS
    'Append-only PASS/PARTIAL/FAIL evidence; failed quantity never creates stock or iqty';
COMMENT ON TABLE production_fqc_release_commands IS
    'Exact integration gate from qualified PASS quantity to one initial FINISHED_IN draft line';
COMMENT ON TABLE production_fqc_release_allocations IS
    'Append-only allocation of one FINISHED_IN line to exact PASS decision lots; total cannot exceed PASS';
