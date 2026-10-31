ALTER TABLE fixed_assets
    ADD COLUMN opening_as_of DATE,
    ADD COLUMN opening_accumulated_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN opening_remaining_months INTEGER,
    ADD COLUMN opening_voucher_id UUID REFERENCES gl_vouchers(id),
    ADD COLUMN recognition_voucher_id UUID REFERENCES gl_vouchers(id),
    ADD COLUMN recognition_reversed_on DATE,
    ADD CONSTRAINT fixed_asset_opening_shape CHECK (
        (opening_as_of IS NULL AND opening_accumulated_amount=0 AND opening_remaining_months IS NULL AND opening_voucher_id IS NULL)
        OR (opening_as_of IS NOT NULL AND opening_remaining_months BETWEEN 0 AND 1200
            AND opening_accumulated_amount BETWEEN 0 AND original_value-round(original_value*salvage_rate,4)));
CREATE UNIQUE INDEX ux_fixed_asset_opening_voucher ON fixed_assets(opening_voucher_id)
    WHERE opening_voucher_id IS NOT NULL AND lifecycle_status<>'REVERSED' AND NOT is_deleted;
ALTER TABLE finance_asset_books ADD COLUMN opening_accumulated_amount NUMERIC(18,4) NOT NULL DEFAULT 0
    CHECK(opening_accumulated_amount>=0 AND opening_accumulated_amount<=depreciable_amount);
ALTER TABLE deferred_expenses ADD COLUMN recognition_voucher_id UUID REFERENCES gl_vouchers(id),
    ADD COLUMN recognition_reversed_on DATE;
ALTER TABLE finance_deferral_schedule_versions DROP CONSTRAINT finance_deferral_versions_status_chk;
ALTER TABLE finance_deferral_schedule_versions ADD CONSTRAINT finance_deferral_versions_status_chk
    CHECK(status IN ('DRAFT','APPROVED','SUPERSEDED','TERMINATED','CANCELLED'));

ALTER TABLE fixed_assets DROP CONSTRAINT fixed_assets_lifecycle_status_chk;
ALTER TABLE fixed_assets ADD CONSTRAINT fixed_assets_lifecycle_status_chk CHECK(lifecycle_status IN
    ('DRAFT','PENDING_APPROVAL','APPROVED','ACTIVE','DISPOSAL_PENDING','DISPOSED',
     'RECOGNITION_REVERSAL_PENDING','RECOGNITION_REVERSAL_APPROVED','REVERSED'));
ALTER TABLE deferred_expenses DROP CONSTRAINT deferred_expenses_lifecycle_status_chk;
ALTER TABLE deferred_expenses ADD CONSTRAINT deferred_expenses_lifecycle_status_chk CHECK(lifecycle_status IN
    ('DRAFT','PENDING_APPROVAL','APPROVED','ACTIVE','COMPLETED','TERMINATION_PENDING','TERMINATED',
     'RECOGNITION_REVERSAL_PENDING','RECOGNITION_REVERSAL_APPROVED','REVERSED'));

CREATE TABLE finance_asset_recognition_reversals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type TEXT NOT NULL CHECK(object_type IN ('FIXED_ASSET','DEFERRED_EXPENSE')),
    object_id UUID NOT NULL,
    original_voucher_id UUID NOT NULL REFERENCES gl_vouchers(id),
    linked_opening BOOLEAN NOT NULL DEFAULT false,
    status TEXT NOT NULL CHECK(status IN ('SUBMITTED','APPROVED','REJECTED','POSTED')),
    reason TEXT NOT NULL CHECK(btrim(reason)<>''),
    requested_by UUID NOT NULL REFERENCES users(id), requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_by UUID REFERENCES users(id), approved_at TIMESTAMPTZ,
    posted_by UUID REFERENCES users(id), posted_at TIMESTAMPTZ,
    reversal_voucher_id UUID REFERENCES gl_vouchers(id),
    CHECK(approved_by IS NULL OR approved_by<>requested_by),
    CHECK(posted_by IS NULL OR posted_by<>requested_by)
);
CREATE UNIQUE INDEX ux_asset_pending_recognition_reversal
    ON finance_asset_recognition_reversals(object_type,object_id) WHERE status IN ('SUBMITTED','APPROVED');
CREATE TRIGGER trg_audit_finance_asset_recognition_reversals AFTER INSERT OR UPDATE OR DELETE ON finance_asset_recognition_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_asset_recognition_reversals ENABLE ALWAYS TRIGGER trg_audit_finance_asset_recognition_reversals;
ALTER TABLE finance_asset_events DROP CONSTRAINT finance_asset_events_type_chk;
ALTER TABLE finance_asset_events ADD CONSTRAINT finance_asset_events_type_chk CHECK(event_type IN (
    'CREATED','UPDATED','SUBMITTED','APPROVED','REJECTED','ACTIVATED','TRANSFERRED','OPERATING_STATUS_CHANGED',
    'DISPOSAL_REQUESTED','DISPOSED','TERMINATION_REQUESTED','TERMINATED','POSTING_PREVIEWED','POSTING_SUBMITTED',
    'POSTING_APPROVED','POSTED','REVERSED','PERIOD_CLOSED','PERIOD_REOPENED',
    'RECOGNITION_REVERSAL_PENDING','RECOGNITION_REVERSAL_APPROVED','RECOGNITION_REVERSAL_REJECTED'));

CREATE FUNCTION fn_guard_asset_recognition_reversal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='UPDATE'
       AND ((OLD.status='SUBMITTED' AND NEW.status IN ('APPROVED','REJECTED')) OR (OLD.status='APPROVED' AND NEW.status='POSTED'))
       AND (to_jsonb(NEW)-ARRAY['status','approved_by','approved_at','posted_by','posted_at','reversal_voucher_id'])
          =(to_jsonb(OLD)-ARRAY['status','approved_by','approved_at','posted_by','posted_at','reversal_voucher_id'])
    THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'Recognition reversal evidence is immutable outside its approved transitions' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_guard_asset_recognition_reversal BEFORE UPDATE OR DELETE ON finance_asset_recognition_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_asset_recognition_reversal();

CREATE OR REPLACE FUNCTION fn_guard_approved_deferral_schedule_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE version_id UUID; version_status TEXT;
BEGIN
    version_id:=CASE WHEN TG_OP='INSERT' THEN NEW.schedule_version_id ELSE OLD.schedule_version_id END;
    SELECT status INTO version_status FROM finance_deferral_schedule_versions WHERE id=version_id;
    IF version_status IN ('APPROVED','SUPERSEDED','TERMINATED','CANCELLED') THEN
        RAISE EXCEPTION 'Approved deferred schedule lines are immutable; create a later version or reversal' USING ERRCODE='55000';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

-- A reversed registration remains auditable; its source can be registered again under a new UUID.
DO $$ DECLARE r RECORD; BEGIN
    FOR r IN SELECT tablename,indexname,indexdef FROM pg_indexes
             WHERE schemaname='public' AND tablename IN ('fixed_assets','deferred_expenses')
               AND indexname LIKE '%active%source_line%'
    LOOP
        EXECUTE format('DROP INDEX %I',r.indexname);
        EXECUTE r.indexdef || ' AND lifecycle_status <> ''REVERSED''';
    END LOOP;
END $$;

-- Once a manual opening voucher is claimed, changing it would detach the asset from its proven
-- opening balance. Release the registration through its audited reversal before editing it.
CREATE FUNCTION fn_guard_linked_asset_opening_voucher() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE targets UUID[];
BEGIN
    IF TG_TABLE_NAME='gl_vouchers' THEN targets := ARRAY[OLD.id];
    ELSIF TG_OP='INSERT' THEN targets := ARRAY[NEW.voucher_id];
    ELSIF TG_OP='DELETE' THEN targets := ARRAY[OLD.voucher_id];
    ELSE targets := ARRAY[OLD.voucher_id,NEW.voucher_id]; END IF;
    -- Lock both sides of a moved entry in a stable order. Ordinary AUTO posting is unaffected.
    PERFORM id FROM gl_vouchers WHERE id=ANY(targets) AND source='MANUAL' ORDER BY id FOR UPDATE;
    IF FOUND AND EXISTS(SELECT 1 FROM fixed_assets WHERE opening_voucher_id=ANY(targets) AND NOT is_deleted
              AND lifecycle_status IN ('PENDING_APPROVAL','APPROVED','ACTIVE','RECOGNITION_REVERSAL_PENDING','RECOGNITION_REVERSAL_APPROVED')) THEN
        RAISE EXCEPTION 'Opening voucher is linked to an active asset registration; reverse registration first' USING ERRCODE='55000';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_linked_asset_opening_voucher BEFORE UPDATE OR DELETE ON gl_vouchers
    FOR EACH ROW EXECUTE FUNCTION fn_guard_linked_asset_opening_voucher();
CREATE TRIGGER trg_linked_asset_opening_entry BEFORE INSERT OR UPDATE OR DELETE ON gl_entries
    FOR EACH ROW EXECUTE FUNCTION fn_guard_linked_asset_opening_voucher();
