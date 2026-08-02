-- V191: append-only pre-approval production planning drafts.
--
-- A draft is a review snapshot only. It never owns stock reservations,
-- material demands, execution segments, purchase/subcontract applications or
-- DRAW documents. Formal facts are created only when plan approval applies the
-- ACTIVE draft through the V155 confirmation command in the same transaction.

CREATE TABLE production_planning_drafts (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id               UUID NOT NULL REFERENCES production_plans(id),
    warehouse_id          UUID NOT NULL REFERENCES warehouses(id),
    status                TEXT NOT NULL DEFAULT 'ACTIVE',
    payload               JSONB NOT NULL,
    payload_version       SMALLINT NOT NULL DEFAULT 1,
    request_hash          TEXT NOT NULL,
    preview_fingerprint   TEXT NOT NULL,
    planned_by            UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    planned_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_by           UUID REFERENCES users(id) ON DELETE RESTRICT,
    resolved_at           TIMESTAMPTZ,
    resolution_reason     TEXT,
    applied_package_id    UUID REFERENCES production_planning_packages(id),
    CONSTRAINT production_planning_drafts_status_chk
        CHECK (status IN ('ACTIVE', 'APPLIED', 'SUPERSEDED')),
    CONSTRAINT production_planning_drafts_payload_chk
        CHECK (jsonb_typeof(payload) = 'object'),
    CONSTRAINT production_planning_drafts_payload_version_chk
        CHECK (payload_version = 1),
    CONSTRAINT production_planning_drafts_hash_chk
        CHECK (
            request_hash ~ '^[0-9a-f]{64}$'
            AND preview_fingerprint ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT production_planning_drafts_resolution_chk
        CHECK (
            (status = 'ACTIVE'
                AND resolved_by IS NULL
                AND resolved_at IS NULL
                AND applied_package_id IS NULL)
            OR
            (status = 'APPLIED'
                AND resolved_by IS NOT NULL
                AND resolved_at IS NOT NULL
                AND applied_package_id IS NOT NULL)
            OR
            (status = 'SUPERSEDED'
                AND resolved_by IS NOT NULL
                AND resolved_at IS NOT NULL
                AND applied_package_id IS NULL)
        )
);

CREATE UNIQUE INDEX uq_production_planning_draft_active_plan
    ON production_planning_drafts(plan_id)
    WHERE status = 'ACTIVE';

CREATE INDEX idx_production_planning_draft_plan_history
    ON production_planning_drafts(plan_id, planned_at DESC, id);

CREATE INDEX idx_production_planning_draft_package
    ON production_planning_drafts(applied_package_id)
    WHERE applied_package_id IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_guard_production_planning_draft_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'production planning drafts are append-only'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'production_planning_draft_append_only_guard';
    END IF;

    IF OLD.plan_id IS DISTINCT FROM NEW.plan_id
       OR OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id
       OR OLD.payload IS DISTINCT FROM NEW.payload
       OR OLD.payload_version IS DISTINCT FROM NEW.payload_version
       OR OLD.request_hash IS DISTINCT FROM NEW.request_hash
       OR OLD.preview_fingerprint IS DISTINCT FROM NEW.preview_fingerprint
       OR OLD.planned_by IS DISTINCT FROM NEW.planned_by
       OR OLD.planned_at IS DISTINCT FROM NEW.planned_at THEN
        RAISE EXCEPTION 'production planning draft payload is immutable'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'production_planning_draft_payload_guard';
    END IF;

    IF OLD.status <> 'ACTIVE'
       OR NEW.status NOT IN ('APPLIED', 'SUPERSEDED') THEN
        RAISE EXCEPTION 'production planning draft terminal state is immutable'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'production_planning_draft_status_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_planning_drafts_append_only
    BEFORE UPDATE OR DELETE ON production_planning_drafts
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_planning_draft_append_only();

CREATE TRIGGER trg_audit_production_planning_drafts
    AFTER INSERT OR UPDATE OR DELETE ON production_planning_drafts
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE production_planning_drafts IS
    'Immutable pre-approval planning proposals; only ACTIVE to APPLIED/SUPERSEDED is allowed.';
COMMENT ON COLUMN production_planning_drafts.payload IS
    'Non-authoritative GeneratePlanningPackageRequest snapshot; stock and supply are revalidated on approval.';
