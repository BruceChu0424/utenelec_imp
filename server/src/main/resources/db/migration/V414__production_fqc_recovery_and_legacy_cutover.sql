-- V414: close FQC failed-quantity recovery and replace absence-based legacy
-- bypass with an explicit cutover ledger.

CREATE TABLE production_fqc_legacy_exemptions (
    source_report_item_id UUID PRIMARY KEY
        REFERENCES production_daily_report_items(id) ON DELETE RESTRICT,
    source_report_id UUID NOT NULL
        REFERENCES production_daily_reports(id) ON DELETE RESTRICT,
    reason_code TEXT NOT NULL DEFAULT 'PRE_V414_CUTOVER'
        CHECK (reason_code = 'PRE_V414_CUTOVER'),
    registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_legacy_exemption_pair_uk
        UNIQUE (source_report_id, source_report_item_id)
);

-- Freeze every pre-cutover report line explicitly. Runtime has no insertion
-- path into this table; post-cutover absence of an inspection is fail-closed.
INSERT INTO production_fqc_legacy_exemptions(
    source_report_item_id, source_report_id)
SELECT item.id, item.report_id
FROM production_daily_report_items item
WHERE NOT EXISTS (
    SELECT 1 FROM production_fqc_inspections inspection
    WHERE inspection.source_report_item_id = item.id);

ALTER TABLE production_daily_report_items
    ADD COLUMN fqc_recovery_authorization_id UUID;

CREATE TABLE production_fqc_recovery_authorizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_inspection_id UUID NOT NULL
        REFERENCES production_fqc_inspections(id) ON DELETE RESTRICT,
    source_decision_event_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_decision_events(id) ON DELETE RESTRICT,
    source_report_item_id UUID NOT NULL
        REFERENCES production_daily_report_items(id) ON DELETE RESTRICT,
    source_plan_item_id UUID NOT NULL
        REFERENCES production_plan_items(id) ON DELETE RESTRICT,
    execution_segment_id UUID NOT NULL
        REFERENCES production_execution_segments(id) ON DELETE RESTRICT,
    execution_segment_sales_allocation_id UUID
        REFERENCES execution_segment_sales_allocations(id) ON DELETE RESTRICT,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    goods_id UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id UUID NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    unit_rate NUMERIC(18,6) NOT NULL,
    authorized_qty NUMERIC(18,4) NOT NULL CHECK (authorized_qty > 0),
    disposition_code TEXT NOT NULL
        CHECK (disposition_code IN ('REWORK', 'SCRAP', 'REJECT')),
    idempotency_key TEXT NOT NULL UNIQUE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_recovery_decision_pair_fk
        FOREIGN KEY (source_inspection_id, source_decision_event_id)
        REFERENCES production_fqc_decision_events(inspection_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT production_fqc_recovery_report_pair_fk
        FOREIGN KEY (source_inspection_id, source_report_item_id)
        REFERENCES production_fqc_inspections(id, source_report_item_id)
        ON DELETE RESTRICT,
    CONSTRAINT production_fqc_recovery_rate_chk CHECK (unit_rate > 0),
    CONSTRAINT production_fqc_recovery_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 160)
);

ALTER TABLE production_daily_report_items
    ADD CONSTRAINT fk_pdri_fqc_recovery_authorization
    FOREIGN KEY (fqc_recovery_authorization_id)
    REFERENCES production_fqc_recovery_authorizations(id)
    ON DELETE RESTRICT;

CREATE INDEX idx_fqc_recovery_segment
    ON production_fqc_recovery_authorizations(
        execution_segment_id, created_at, id);

CREATE TABLE production_fqc_replenishment_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    authorization_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_recovery_authorizations(id)
        ON DELETE RESTRICT,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE production_fqc_replenishment_analysis_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    replenishment_task_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_replenishment_tasks(id)
        ON DELETE RESTRICT,
    authorization_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_recovery_authorizations(id)
        ON DELETE RESTRICT,
    material_analysis_id UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    material_analysis_item_id UUID NOT NULL
        REFERENCES production_material_analysis_items(id) ON DELETE RESTRICT,
    idempotency_key TEXT NOT NULL UNIQUE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE production_fqc_recovery_cancellation_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    authorization_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_recovery_authorizations(id)
        ON DELETE RESTRICT,
    source_report_id UUID NOT NULL
        REFERENCES production_daily_reports(id) ON DELETE RESTRICT,
    reason_code TEXT NOT NULL
        CHECK (reason_code = 'SOURCE_REPORT_REVERSED'),
    idempotency_key TEXT NOT NULL UNIQUE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE production_fqc_recovery_allocation_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    authorization_id UUID NOT NULL
        REFERENCES production_fqc_recovery_authorizations(id)
        ON DELETE RESTRICT,
    recovery_report_item_id UUID NOT NULL
        REFERENCES production_daily_report_items(id) ON DELETE RESTRICT,
    event_type TEXT NOT NULL CHECK (event_type IN ('ALLOCATE', 'RELEASE')),
    qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
    source_allocation_event_id UUID
        REFERENCES production_fqc_recovery_allocation_events(id)
        ON DELETE RESTRICT,
    idempotency_key TEXT NOT NULL UNIQUE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_recovery_event_shape_chk CHECK (
        (event_type = 'ALLOCATE' AND source_allocation_event_id IS NULL)
        OR (event_type = 'RELEASE' AND source_allocation_event_id IS NOT NULL))
);

CREATE UNIQUE INDEX uq_fqc_recovery_report_allocation
    ON production_fqc_recovery_allocation_events(recovery_report_item_id)
    WHERE event_type = 'ALLOCATE';
CREATE UNIQUE INDEX uq_fqc_recovery_release_source
    ON production_fqc_recovery_allocation_events(source_allocation_event_id)
    WHERE event_type = 'RELEASE';

CREATE TABLE production_fqc_contribution_adjustments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id UUID NOT NULL
        REFERENCES production_fqc_inspections(id) ON DELETE RESTRICT,
    decision_event_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_decision_events(id) ON DELETE RESTRICT,
    source_report_item_id UUID NOT NULL
        REFERENCES production_daily_report_items(id) ON DELETE RESTRICT,
    source_plan_item_id UUID NOT NULL
        REFERENCES production_plan_items(id) ON DELETE RESTRICT,
    execution_segment_sales_allocation_id UUID
        REFERENCES execution_segment_sales_allocations(id) ON DELETE RESTRICT,
    adjusted_qty NUMERIC(18,4) NOT NULL CHECK (adjusted_qty > 0),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_adjustment_decision_pair_fk
        FOREIGN KEY (inspection_id, decision_event_id)
        REFERENCES production_fqc_decision_events(inspection_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT production_fqc_adjustment_report_pair_fk
        FOREIGN KEY (inspection_id, source_report_item_id)
        REFERENCES production_fqc_inspections(id, source_report_item_id)
        ON DELETE RESTRICT
);

CREATE OR REPLACE VIEW v_production_fqc_recovery_balance AS
SELECT recovery_auth.id AS authorization_id,
       recovery_auth.execution_segment_id,
       recovery_auth.source_plan_item_id,
       recovery_auth.authorized_qty,
       COALESCE(SUM(CASE allocation_event.event_type
           WHEN 'ALLOCATE' THEN allocation_event.qty
           WHEN 'RELEASE' THEN -allocation_event.qty
           ELSE 0 END), 0) AS allocated_qty,
       recovery_auth.authorized_qty
           - COALESCE(SUM(CASE allocation_event.event_type
               WHEN 'ALLOCATE' THEN allocation_event.qty
               WHEN 'RELEASE' THEN -allocation_event.qty
               ELSE 0 END), 0) AS available_qty,
       cancellation.id IS NOT NULL AS cancelled
FROM production_fqc_recovery_authorizations recovery_auth
LEFT JOIN production_fqc_recovery_allocation_events allocation_event
  ON allocation_event.authorization_id = recovery_auth.id
LEFT JOIN production_fqc_recovery_cancellation_events cancellation
  ON cancellation.authorization_id = recovery_auth.id
GROUP BY recovery_auth.id, cancellation.id;

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_legacy_exemption()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'production FQC legacy exemptions are migration-only and append-only'
        USING ERRCODE = '55000';
END;
$$;
CREATE TRIGGER trg_guard_production_fqc_legacy_exemption
    BEFORE INSERT OR UPDATE OR DELETE ON production_fqc_legacy_exemptions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_legacy_exemption();
ALTER TABLE production_fqc_legacy_exemptions
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_legacy_exemption;

CREATE OR REPLACE FUNCTION fn_guard_fqc_recovery_report_item()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    recovery_auth production_fqc_recovery_authorizations%ROWTYPE;
BEGIN
    IF TG_OP = 'UPDATE'
       AND EXISTS (
           SELECT 1
           FROM production_fqc_recovery_allocation_events event
           WHERE event.recovery_report_item_id = OLD.id
             AND event.event_type = 'ALLOCATE')
       AND (
           OLD.fqc_recovery_authorization_id IS DISTINCT FROM
               NEW.fqc_recovery_authorization_id
            OR OLD.report_id IS DISTINCT FROM NEW.report_id
            OR OLD.plan_item_id IS DISTINCT FROM NEW.plan_item_id
           OR OLD.execution_segment_id IS DISTINCT FROM NEW.execution_segment_id
           OR OLD.execution_segment_sales_allocation_id IS DISTINCT FROM
               NEW.execution_segment_sales_allocation_id
           OR OLD.goods_id IS DISTINCT FROM NEW.goods_id
           OR OLD.color_id IS DISTINCT FROM NEW.color_id
           OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
           OR COALESCE(OLD.unit_rate, 1) IS DISTINCT FROM
               COALESCE(NEW.unit_rate, 1)
            OR OLD.qty IS DISTINCT FROM NEW.qty
            OR OLD.is_final IS DISTINCT FROM NEW.is_final
            OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted) THEN
        RAISE EXCEPTION 'allocated FQC recovery report identity is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.fqc_recovery_authorization_id IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO recovery_auth
    FROM production_fqc_recovery_authorizations
    WHERE id = NEW.fqc_recovery_authorization_id;
    IF recovery_auth.id IS NULL
       OR NEW.plan_item_id IS DISTINCT FROM recovery_auth.source_plan_item_id
       OR NEW.execution_segment_id IS DISTINCT FROM recovery_auth.execution_segment_id
       OR NEW.execution_segment_sales_allocation_id
            IS DISTINCT FROM recovery_auth.execution_segment_sales_allocation_id
       OR NEW.goods_id IS DISTINCT FROM recovery_auth.goods_id
       OR NEW.color_id IS DISTINCT FROM recovery_auth.color_id
       OR NEW.unit_id IS DISTINCT FROM recovery_auth.unit_id
       OR COALESCE(NEW.unit_rate, 1) IS DISTINCT FROM recovery_auth.unit_rate
       OR NEW.qty <= 0
       OR NEW.qty > recovery_auth.authorized_qty
       OR NEW.is_final THEN
        RAISE EXCEPTION 'FQC recovery report line identity or quantity is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_recovery_report_item_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_recovery_report_item
    BEFORE INSERT OR UPDATE OF
        fqc_recovery_authorization_id, report_id, plan_item_id,
        execution_segment_id, execution_segment_sales_allocation_id,
        goods_id, color_id, unit_id, unit_rate, qty, is_final, is_deleted
    ON production_daily_report_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_recovery_report_item();

CREATE OR REPLACE FUNCTION fn_guard_fqc_recovery_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    inspection production_fqc_inspections%ROWTYPE;
    decision production_fqc_decision_events%ROWTYPE;
BEGIN
    SELECT * INTO inspection FROM production_fqc_inspections
    WHERE id = NEW.source_inspection_id;
    SELECT * INTO decision FROM production_fqc_decision_events
    WHERE id = NEW.source_decision_event_id;
    IF inspection.id IS NULL OR decision.id IS NULL
       OR decision.inspection_id <> inspection.id
       OR inspection.source_report_item_id <> NEW.source_report_item_id
       OR inspection.source_plan_item_id <> NEW.source_plan_item_id
       OR inspection.execution_segment_id <> NEW.execution_segment_id
       OR inspection.execution_segment_sales_allocation_id
            IS DISTINCT FROM NEW.execution_segment_sales_allocation_id
       OR inspection.warehouse_id <> NEW.warehouse_id
       OR inspection.goods_id <> NEW.goods_id
       OR inspection.color_id IS DISTINCT FROM NEW.color_id
       OR inspection.unit_id <> NEW.unit_id
       OR inspection.unit_rate <> NEW.unit_rate
       OR decision.fail_qty <> NEW.authorized_qty
       OR decision.disposition_code <> NEW.disposition_code THEN
        RAISE EXCEPTION 'FQC recovery authorization identity is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_recovery_identity_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_recovery_identity
    BEFORE INSERT ON production_fqc_recovery_authorizations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_recovery_identity();

CREATE OR REPLACE FUNCTION fn_guard_fqc_contribution_adjustment()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    inspection production_fqc_inspections%ROWTYPE;
    decision production_fqc_decision_events%ROWTYPE;
BEGIN
    SELECT * INTO inspection FROM production_fqc_inspections
    WHERE id = NEW.inspection_id;
    SELECT * INTO decision FROM production_fqc_decision_events
    WHERE id = NEW.decision_event_id;
    IF inspection.id IS NULL OR decision.id IS NULL
       OR decision.inspection_id <> inspection.id
       OR decision.fail_qty <> NEW.adjusted_qty
       OR inspection.source_report_item_id <> NEW.source_report_item_id
       OR inspection.source_plan_item_id <> NEW.source_plan_item_id
       OR inspection.execution_segment_sales_allocation_id
            IS DISTINCT FROM NEW.execution_segment_sales_allocation_id THEN
        RAISE EXCEPTION 'FQC contribution adjustment identity or quantity is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_contribution_adjustment_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_contribution_adjustment
    BEFORE INSERT ON production_fqc_contribution_adjustments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_contribution_adjustment();

CREATE OR REPLACE FUNCTION fn_guard_fqc_recovery_allocation_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    recovery_auth production_fqc_recovery_authorizations%ROWTYPE;
    report_item production_daily_report_items%ROWTYPE;
    report_status SMALLINT;
    source_event production_fqc_recovery_allocation_events%ROWTYPE;
    current_allocated NUMERIC(18,4);
BEGIN
    SELECT * INTO recovery_auth
    FROM production_fqc_recovery_authorizations
    WHERE id = NEW.authorization_id FOR UPDATE;
    SELECT * INTO report_item
    FROM production_daily_report_items
    WHERE id = NEW.recovery_report_item_id;
    SELECT status INTO report_status
    FROM production_daily_reports
    WHERE id = report_item.report_id AND is_deleted = FALSE;
    IF recovery_auth.id IS NULL OR report_item.id IS NULL
       OR report_item.fqc_recovery_authorization_id
            IS DISTINCT FROM recovery_auth.id
       OR NEW.qty <> report_item.qty THEN
        RAISE EXCEPTION 'FQC recovery allocation source is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.event_type = 'ALLOCATE' THEN
        IF recovery_auth.disposition_code <> 'REWORK' THEN
            RAISE EXCEPTION
                'SCRAP/REJECT recovery requires a new kitted production segment before reporting'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_fqc_recovery_material_gate';
        END IF;
        IF report_status IS DISTINCT FROM 1 OR EXISTS (
            SELECT 1 FROM production_fqc_recovery_cancellation_events c
            WHERE c.authorization_id = recovery_auth.id) THEN
            RAISE EXCEPTION 'FQC recovery authorization is not open for allocation'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        SELECT * INTO source_event
        FROM production_fqc_recovery_allocation_events
        WHERE id = NEW.source_allocation_event_id FOR UPDATE;
        IF report_status IS DISTINCT FROM -1
           OR source_event.id IS NULL
           OR source_event.event_type <> 'ALLOCATE'
           OR source_event.authorization_id <> NEW.authorization_id
           OR source_event.recovery_report_item_id <> NEW.recovery_report_item_id
           OR source_event.qty <> NEW.qty THEN
            RAISE EXCEPTION 'FQC recovery release source is invalid'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    SELECT COALESCE(SUM(CASE event.event_type
        WHEN 'ALLOCATE' THEN event.qty
        WHEN 'RELEASE' THEN -event.qty ELSE 0 END), 0)
    INTO current_allocated
    FROM production_fqc_recovery_allocation_events event
    WHERE event.authorization_id = NEW.authorization_id;
    current_allocated := current_allocated
        + CASE WHEN NEW.event_type = 'ALLOCATE' THEN NEW.qty ELSE -NEW.qty END;
    IF current_allocated < 0 OR current_allocated > recovery_auth.authorized_qty THEN
        RAISE EXCEPTION 'FQC recovery allocation exceeds authorized quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_recovery_capacity_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_recovery_allocation_event
    BEFORE INSERT ON production_fqc_recovery_allocation_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_recovery_allocation_event();

CREATE OR REPLACE FUNCTION fn_guard_fqc_recovery_cancellation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    recovery_auth production_fqc_recovery_authorizations%ROWTYPE;
    report_status SMALLINT;
    net_allocated NUMERIC(18,4);
BEGIN
    SELECT * INTO recovery_auth
    FROM production_fqc_recovery_authorizations
    WHERE id = NEW.authorization_id FOR UPDATE;
    SELECT report.status INTO report_status
    FROM production_daily_report_items item
    JOIN production_daily_reports report ON report.id = item.report_id
    WHERE item.id = recovery_auth.source_report_item_id;
    SELECT COALESCE(SUM(CASE event.event_type
        WHEN 'ALLOCATE' THEN event.qty
        WHEN 'RELEASE' THEN -event.qty ELSE 0 END), 0)
    INTO net_allocated
    FROM production_fqc_recovery_allocation_events event
    WHERE event.authorization_id = NEW.authorization_id;
    IF recovery_auth.id IS NULL
       OR NEW.source_report_id IS DISTINCT FROM (
            SELECT item.report_id FROM production_daily_report_items item
            WHERE item.id = recovery_auth.source_report_item_id)
       OR report_status IS DISTINCT FROM -1
       OR net_allocated <> 0 THEN
        RAISE EXCEPTION
            'FQC recovery cancellation requires reversed source and zero active replacement allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_recovery_cancellation_guard';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM production_fqc_recovery_allocation_events allocation_event
        JOIN production_daily_report_items replacement_item
          ON replacement_item.id = allocation_event.recovery_report_item_id
        LEFT JOIN production_daily_reports replacement_report
          ON replacement_report.id = replacement_item.report_id
        WHERE allocation_event.authorization_id = NEW.authorization_id
          AND allocation_event.event_type = 'ALLOCATE'
          AND (
              replacement_report.id IS NULL
              OR replacement_report.status IS DISTINCT FROM -1
              OR replacement_report.is_deleted
              OR replacement_item.is_deleted
              OR NOT EXISTS (
                  SELECT 1
                  FROM production_fqc_inspections replacement_inspection
                  WHERE replacement_inspection.source_report_item_id =
                        replacement_item.id
                    AND replacement_inspection.status = 'CANCELLED')
              OR EXISTS (
                  SELECT 1
                  FROM production_fqc_inspections replacement_inspection
                  JOIN production_fqc_release_allocations release_allocation
                    ON release_allocation.inspection_id =
                       replacement_inspection.id
                  JOIN production_fqc_release_commands release_command
                    ON release_command.id =
                       release_allocation.release_command_id
                  JOIN stock_document_items stock_item
                    ON stock_item.id =
                       release_command.stock_document_item_id
                  JOIN stock_documents stock_document
                    ON stock_document.id = stock_item.doc_id
                  WHERE replacement_inspection.source_report_item_id =
                        replacement_item.id
                    AND stock_item.is_deleted = FALSE
                    AND stock_document.is_deleted = FALSE
                    AND stock_document.status IN (0, 1)))) THEN
        RAISE EXCEPTION
            'FQC recovery cancellation requires every replacement FQC and inbound to be reversed first'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_recovery_child_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_recovery_cancellation
    BEFORE INSERT ON production_fqc_recovery_cancellation_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_recovery_cancellation();

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_link()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    task production_fqc_replenishment_tasks%ROWTYPE;
    recovery_auth production_fqc_recovery_authorizations%ROWTYPE;
    analysis_item production_material_analysis_items%ROWTYPE;
BEGIN
    SELECT * INTO task FROM production_fqc_replenishment_tasks
    WHERE id = NEW.replenishment_task_id;
    SELECT * INTO recovery_auth FROM production_fqc_recovery_authorizations
    WHERE id = NEW.authorization_id;
    SELECT * INTO analysis_item FROM production_material_analysis_items
    WHERE id = NEW.material_analysis_item_id;
    IF task.id IS NULL OR recovery_auth.id IS NULL OR analysis_item.id IS NULL
       OR task.authorization_id <> recovery_auth.id
       OR recovery_auth.disposition_code NOT IN ('SCRAP', 'REJECT')
       OR analysis_item.analysis_id <> NEW.material_analysis_id
       OR analysis_item.source_type <> 'REWORK'
       OR analysis_item.goods_id <> recovery_auth.goods_id
       OR analysis_item.color_id IS DISTINCT FROM recovery_auth.color_id
       OR analysis_item.unit_id <> recovery_auth.unit_id
       OR analysis_item.requested_qty <> recovery_auth.authorized_qty
       OR analysis_item.source_ref <> 'FQC-RECOVERY-' || recovery_auth.id::text THEN
        RAISE EXCEPTION 'FQC replenishment analysis link identity is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_replenishment_link_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_replenishment_link
    BEFORE INSERT ON production_fqc_replenishment_analysis_links
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_link();

CREATE TRIGGER trg_guard_fqc_recovery_authorization_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_recovery_authorizations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_recovery_authorizations
    ENABLE ALWAYS TRIGGER trg_guard_fqc_recovery_authorization_append_only;
CREATE TRIGGER trg_guard_fqc_recovery_allocation_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_recovery_allocation_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_recovery_allocation_events
    ENABLE ALWAYS TRIGGER trg_guard_fqc_recovery_allocation_append_only;
CREATE TRIGGER trg_guard_fqc_recovery_cancellation_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_recovery_cancellation_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_recovery_cancellation_events
    ENABLE ALWAYS TRIGGER trg_guard_fqc_recovery_cancellation_append_only;
CREATE TRIGGER trg_guard_fqc_contribution_adjustment_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_contribution_adjustments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_contribution_adjustments
    ENABLE ALWAYS TRIGGER trg_guard_fqc_contribution_adjustment_append_only;
CREATE TRIGGER trg_guard_fqc_replenishment_task_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_replenishment_tasks
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_task_append_only;
CREATE TRIGGER trg_guard_fqc_replenishment_link_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_analysis_links
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_replenishment_analysis_links
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_link_append_only;

CREATE TRIGGER trg_audit_production_fqc_legacy_exemptions
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_legacy_exemptions
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_recovery_authorizations
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_recovery_authorizations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_recovery_allocation_events
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_recovery_allocation_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_recovery_cancellation_events
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_recovery_cancellation_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_contribution_adjustments
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_contribution_adjustments
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_replenishment_tasks
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_replenishment_analysis_links
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_analysis_links
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Recovery-attempt reports are additional processing evidence. They restore an
-- FQC failure-adjusted effective contribution, but do not consume the original
-- immutable segment/sales allocation capacity a second time.
CREATE OR REPLACE FUNCTION fn_assert_execution_segment_sales_fact_capacity(
    p_allocation_id UUID
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_allocated NUMERIC(18,4);
    v_reported NUMERIC(18,4);
    v_inbound NUMERIC(18,4);
BEGIN
    IF p_allocation_id IS NULL THEN RETURN; END IF;
    SELECT allocation.allocated_qty INTO v_allocated
    FROM execution_segment_sales_allocations allocation
    WHERE allocation.id = p_allocation_id;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT COALESCE(SUM(item.qty), 0)
    INTO v_reported
    FROM production_daily_report_items item
    JOIN production_daily_reports report ON report.id = item.report_id
    WHERE item.execution_segment_sales_allocation_id = p_allocation_id
      AND item.fqc_recovery_authorization_id IS NULL
      AND item.is_deleted = FALSE
      AND report.is_deleted = FALSE
      AND report.status IN (0, 1);
    IF v_reported > v_allocated THEN
        RAISE EXCEPTION 'daily report quantity exceeds its segment sales allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'daily_report_segment_sales_capacity_guard';
    END IF;

    SELECT COALESCE(SUM(item.qty), 0)
    INTO v_inbound
    FROM stock_document_items item
    JOIN stock_documents document ON document.id = item.doc_id
    WHERE item.execution_segment_sales_allocation_id = p_allocation_id
      AND item.is_deleted = FALSE
      AND document.is_deleted = FALSE
      AND document.doc_type = 'FINISHED_IN'
      AND document.status = 1;
    IF v_inbound > (
        SELECT COALESCE(SUM(item.qty), 0)
        FROM production_daily_report_items item
        JOIN production_daily_reports report ON report.id = item.report_id
        WHERE item.execution_segment_sales_allocation_id = p_allocation_id
          AND item.is_deleted = FALSE
          AND report.is_deleted = FALSE
          AND report.status = 1
    ) THEN
        RAISE EXCEPTION
            'finished-in quantity exceeds approved report quantity for its sales allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'finished_in_segment_sales_report_guard';
    END IF;
END;
$$;

COMMENT ON TABLE production_fqc_legacy_exemptions IS
    'Migration-only explicit pre-V414 bypass; absence of both inspection and this row is fail-closed';
COMMENT ON TABLE production_fqc_recovery_authorizations IS
    'One append-only remediation lot per FQC decision fail quantity, exact to the original plan/segment/allocation';
COMMENT ON TABLE production_fqc_recovery_allocation_events IS
    'Append-only allocation/release of remediation capacity to replacement report attempts';
COMMENT ON TABLE production_fqc_contribution_adjustments IS
    'Immutable evidence that FQC fail quantity was removed from current fqty/produced projections';
COMMENT ON TABLE production_fqc_replenishment_tasks IS
    'SCRAP/REJECT planning task; planner must confirm material analysis before real package/reservation/DRAW';
COMMENT ON TABLE production_fqc_replenishment_analysis_links IS
    'Exact authorization -> material analysis/item bridge; later plan links provide plan/segment UUID lineage';
