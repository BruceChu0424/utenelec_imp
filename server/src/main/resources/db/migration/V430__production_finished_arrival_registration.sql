-- V430: warehouse pre-registers the finished-goods destination and placement
-- before production FQC.  Registration is a human business fact, not stock:
-- only the existing V338 final-count command may increase inventory or iqty.

CREATE TABLE production_finished_arrival_registrations (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_report_id         UUID NOT NULL UNIQUE
        REFERENCES production_daily_reports(id) ON DELETE RESTRICT,
    warehouse_id             UUID NOT NULL
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    warehouse_code_snapshot  TEXT,
    warehouse_name_snapshot  TEXT NOT NULL,
    receiver_employee_id     UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    receiver_name_snapshot   TEXT NOT NULL,
    idempotency_key          VARCHAR(128) NOT NULL,
    request_hash             CHAR(64) NOT NULL,
    created_by               UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_finished_arrival_warehouse_name_chk CHECK (
        NULLIF(btrim(warehouse_name_snapshot), '') IS NOT NULL),
    CONSTRAINT production_finished_arrival_receiver_name_chk CHECK (
        NULLIF(btrim(receiver_name_snapshot), '') IS NOT NULL),
    CONSTRAINT production_finished_arrival_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'),
    CONSTRAINT production_finished_arrival_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT production_finished_arrival_actor_key_uk UNIQUE (
        created_by, idempotency_key)
);

CREATE TABLE production_finished_arrival_registration_items (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id          UUID NOT NULL
        REFERENCES production_finished_arrival_registrations(id)
        ON DELETE RESTRICT,
    source_report_item_id    UUID NOT NULL UNIQUE
        REFERENCES production_daily_report_items(id) ON DELETE RESTRICT,
    place_snapshot           TEXT NOT NULL,
    created_by               UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_finished_arrival_item_place_chk CHECK (
        place_snapshot = btrim(place_snapshot)
        AND length(place_snapshot) BETWEEN 1 AND 100),
    CONSTRAINT production_finished_arrival_registration_item_uk UNIQUE (
        registration_id, source_report_item_id)
);

CREATE INDEX idx_production_finished_arrival_registration_warehouse
    ON production_finished_arrival_registrations(
        warehouse_id, created_at, id);
CREATE INDEX idx_production_finished_arrival_registration_items_registration
    ON production_finished_arrival_registration_items(
        registration_id, source_report_item_id);

CREATE OR REPLACE FUNCTION fn_guard_production_finished_arrival_registration()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'production finished arrival registration is append-only'
            USING ERRCODE = '55000';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM production_daily_reports report
        WHERE report.id = NEW.source_report_id
          AND report.status = 1
          AND report.is_deleted = FALSE
    ) THEN
        RAISE EXCEPTION 'finished arrival registration requires an approved report'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_report_guard';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM warehouses warehouse
        WHERE warehouse.id = NEW.warehouse_id
          AND warehouse.is_deleted = FALSE
          AND warehouse.is_accountable = TRUE
          AND COALESCE(warehouse.status, '') <> '禁用'
    ) THEN
        RAISE EXCEPTION 'finished arrival registration requires an active accountable warehouse'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_warehouse_guard';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_finished_arrival_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    registration_report_id UUID;
    item_report_id UUID;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'production finished arrival registration item is append-only'
            USING ERRCODE = '55000';
    END IF;

    SELECT source_report_id INTO registration_report_id
    FROM production_finished_arrival_registrations
    WHERE id = NEW.registration_id;

    SELECT report_id INTO item_report_id
    FROM production_daily_report_items
    WHERE id = NEW.source_report_item_id
      AND is_deleted = FALSE
      AND execution_segment_id IS NOT NULL;

    IF registration_report_id IS NULL
       OR item_report_id IS NULL
       OR item_report_id <> registration_report_id
       OR EXISTS (
           SELECT 1 FROM production_fqc_inspections inspection
           WHERE inspection.source_report_item_id = NEW.source_report_item_id)
       OR EXISTS (
           SELECT 1 FROM production_fqc_legacy_exemptions exemption
           WHERE exemption.source_report_item_id = NEW.source_report_item_id) THEN
        RAISE EXCEPTION 'finished arrival item does not belong to an eligible report line'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_item_source_guard';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_require_complete_production_finished_arrival()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_report_id UUID;
BEGIN
    SELECT source_report_id INTO v_report_id
    FROM production_finished_arrival_registrations
    WHERE id = NEW.id;

    IF EXISTS (
        SELECT 1
        FROM production_daily_report_items report_item
        WHERE report_item.report_id = v_report_id
          AND report_item.is_deleted = FALSE
          AND NOT EXISTS (
              SELECT 1
              FROM production_finished_arrival_registration_items arrival_item
              WHERE arrival_item.registration_id = NEW.id
                AND arrival_item.source_report_item_id = report_item.id)
    ) OR EXISTS (
        SELECT 1
        FROM production_finished_arrival_registration_items arrival_item
        JOIN production_daily_report_items report_item
          ON report_item.id = arrival_item.source_report_item_id
        WHERE arrival_item.registration_id = NEW.id
          AND report_item.report_id <> v_report_id
    ) THEN
        RAISE EXCEPTION 'finished arrival registration must cover every report line exactly once'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_complete_guard';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_finished_arrival_registrations
    BEFORE INSERT OR UPDATE OR DELETE
    ON production_finished_arrival_registrations
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_finished_arrival_registration();
ALTER TABLE production_finished_arrival_registrations
    ENABLE ALWAYS TRIGGER trg_guard_production_finished_arrival_registrations;

CREATE TRIGGER trg_guard_production_finished_arrival_registration_items
    BEFORE INSERT OR UPDATE OR DELETE
    ON production_finished_arrival_registration_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_finished_arrival_item();
ALTER TABLE production_finished_arrival_registration_items
    ENABLE ALWAYS TRIGGER trg_guard_production_finished_arrival_registration_items;

CREATE CONSTRAINT TRIGGER trg_require_complete_production_finished_arrival
    AFTER INSERT ON production_finished_arrival_registrations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_require_complete_production_finished_arrival();

CREATE TRIGGER trg_audit_production_finished_arrival_registrations
    AFTER INSERT OR UPDATE OR DELETE
    ON production_finished_arrival_registrations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_finished_arrival_registration_items
    AFTER INSERT OR UPDATE OR DELETE
    ON production_finished_arrival_registration_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Forward-replace the V410 source guard. Existing inspection projection updates
-- keep their historical path; every new inspection must use an exact warehouse
-- registration row and item instead of production_daily_reports.warehouse_id.
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
           registration.warehouse_id AS registered_warehouse_id,
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
    JOIN production_finished_arrival_registrations registration
      ON registration.source_report_id = report.id
    JOIN production_finished_arrival_registration_items registration_item
      ON registration_item.registration_id = registration.id
     AND registration_item.source_report_item_id = item.id
    JOIN production_execution_segments segment
      ON segment.id = item.execution_segment_id
    JOIN production_planning_packages package ON package.id = segment.package_id
    WHERE item.id = NEW.source_report_item_id;

    IF source_row IS NULL
       OR source_row.report_status <> 1
       OR source_row.report_deleted
       OR source_row.item_deleted
       OR source_row.registered_warehouse_id IS NULL
       OR source_row.report_maker_id IS NULL
       OR source_row.item_report_id <> NEW.source_report_id
       OR source_row.plan_item_id IS DISTINCT FROM NEW.source_plan_item_id
       OR source_row.execution_segment_id IS DISTINCT FROM NEW.execution_segment_id
       OR source_row.execution_segment_sales_allocation_id
            IS DISTINCT FROM NEW.execution_segment_sales_allocation_id
       OR source_row.registered_warehouse_id <> NEW.warehouse_id
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
        RAISE EXCEPTION 'production FQC source report identity or arrival registration is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_source_report_guard';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON TABLE production_finished_arrival_registrations IS
    '生产报工审核后、FQC前的仓库送检登记头；逐报工唯一、幂等、只追加';
COMMENT ON TABLE production_finished_arrival_registration_items IS
    '送检登记逐行库位快照；不是库存、FQC PASS或最终实收事实';
COMMENT ON COLUMN production_finished_arrival_registrations.warehouse_id IS
    '仓库岗位登记的成品目标仓；不从计划包物料仓推测';
COMMENT ON COLUMN production_finished_arrival_registration_items.place_snapshot IS
    '仓库送检登记时冻结的库位文本；PASS后复制到初始 FINISHED_IN 明细';
