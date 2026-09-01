-- V440: purchase/subcontract IQC rejection physical-return and finance closure.
--
-- Quality disposition remains authoritative in procurement_inspection_items/events.
-- A FAIL transaction only appends a durable DETECTED outbox event.  The async
-- projection freezes receipt/AP facts here; physical return, supplier credit,
-- replacement capacity and any reversal remain separate auditable facts.

DO $$
DECLARE
    v_historical_failed BIGINT;
BEGIN
    SELECT count(*) INTO v_historical_failed
    FROM procurement_inspection_items inspection
    WHERE inspection.status IN('PARTIAL','RESOLVED')
      AND inspection.failed_base_qty>0;
    IF v_historical_failed<>0 THEN
        RAISE EXCEPTION USING
            ERRCODE='23514',
            MESSAGE='V440 requires reconciliation of historical partial/resolved IQC failures',
            DETAIL=format(
                '%s partial/resolved IQC rows have failed quantity but no authoritative rejection case',
                v_historical_failed),
            HINT='Classify physical return, supplier credit and still-pending rows before retrying V440.',
            CONSTRAINT='v440_historical_iqc_failure_reconciliation_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_failure_detection()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_failed_events NUMERIC(18,4);
    v_missing_detection BIGINT;
BEGIN
    IF NEW.status='REVERSED'
       OR NEW.failed_base_qty<=COALESCE(OLD.failed_base_qty,0) THEN
        RETURN NULL;
    END IF;
    SELECT COALESCE(SUM(event.base_qty),0),
           COUNT(*) FILTER(WHERE detection.id IS NULL)
      INTO v_failed_events,v_missing_detection
    FROM procurement_inspection_events event
    LEFT JOIN business_outbox detection
      ON detection.event_type='PROCUREMENT_IQC_REJECTION_DETECTED'
     AND detection.aggregate_id=NEW.id
     AND detection.payload->>'inspectionEventId'=event.id::TEXT
    WHERE event.inspection_item_id=NEW.id
      AND event.action='FAIL';
    IF v_failed_events<>NEW.failed_base_qty OR v_missing_detection<>0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='IQC failed quantity requires one durable detection event per FAIL fact',
            CONSTRAINT='procurement_iqc_failure_detection_guard';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_procurement_iqc_failure_detection
    AFTER INSERT OR UPDATE OF failed_base_qty
    ON procurement_inspection_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_failure_detection();

-- ======================== case / event / command authority ========================

CREATE TABLE procurement_iqc_rejection_cases (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_type                TEXT NOT NULL,
    receipt_id                  UUID NOT NULL,
    receipt_item_id             UUID NOT NULL,
    inspection_item_id          UUID NOT NULL,
    order_item_id               UUID NOT NULL,
    source_ap_ledger_id         UUID REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    receipt_bill_no             TEXT NOT NULL,
    order_bill_no               TEXT,
    supplier_id                 UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    currency_id                 UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    exchange_rate               NUMERIC(18,6) NOT NULL,
    tax_rate                    NUMERIC(9,4) NOT NULL,
    settlement_method_id        UUID NOT NULL REFERENCES settlement_methods(id) ON DELETE RESTRICT,
    goods_id                    UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                    UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                     UUID REFERENCES units(id) ON DELETE RESTRICT,
    unit_rate                   NUMERIC(18,6) NOT NULL,
    received_base_qty           NUMERIC(18,4) NOT NULL,
    received_qty                NUMERIC(18,4) NOT NULL,
    received_amount_original    NUMERIC(18,4) NOT NULL,
    received_amount_local       NUMERIC(18,4) NOT NULL,
    failed_base_qty             NUMERIC(18,4) NOT NULL,
    failed_qty                  NUMERIC(18,4) NOT NULL,
    failed_amount_original      NUMERIC(18,4) NOT NULL,
    failed_amount_local         NUMERIC(18,4) NOT NULL,
    owner_user_id               UUID REFERENCES users(id) ON DELETE SET NULL,
    status                      TEXT NOT NULL,
    row_version                 BIGINT NOT NULL DEFAULT 1,

    return_reference            TEXT,
    return_date                 DATE,
    return_note                 TEXT,
    return_recorded_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    return_recorded_at          TIMESTAMPTZ,

    credit_source_id            UUID,
    credit_ledger_id            UUID REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    offset_id                   UUID REFERENCES supplier_open_item_offsets(id) ON DELETE RESTRICT,
    credit_reference            TEXT,
    credit_date                 DATE,
    credit_reason               TEXT,
    credit_confirmed_by         UUID REFERENCES users(id) ON DELETE SET NULL,
    credit_confirmed_at         TIMESTAMPTZ,

    closed_no_credit_reason     TEXT,
    closed_no_credit_by         UUID REFERENCES users(id) ON DELETE SET NULL,
    closed_no_credit_at         TIMESTAMPTZ,

    finance_exception_code      TEXT,
    finance_exception_message   TEXT,
    finance_exception_at        TIMESTAMPTZ,

    previous_status             TEXT,
    reverse_reason              TEXT,
    reversed_by                 UUID REFERENCES users(id) ON DELETE SET NULL,
    reversed_at                 TIMESTAMPTZ,

    created_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted                  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                  TIMESTAMPTZ,

    CONSTRAINT procurement_iqc_rejection_cases_inspection_uk
        UNIQUE (inspection_item_id),
    CONSTRAINT procurement_iqc_rejection_cases_receipt_type_chk
        CHECK (receipt_type IN ('PURCHASE','SUBCONTRACT')),
    CONSTRAINT procurement_iqc_rejection_cases_status_chk
        CHECK (status IN (
            'PENDING_RETURN','RETURN_RECORDED','CREDIT_CONFIRMED',
            'CLOSED_NO_CREDIT','FINANCE_EXCEPTION','REVERSED')),
    CONSTRAINT procurement_iqc_rejection_cases_version_chk
        CHECK (row_version >= 1),
    CONSTRAINT procurement_iqc_rejection_cases_rate_chk
        CHECK (exchange_rate > 0 AND unit_rate > 0),
    CONSTRAINT procurement_iqc_rejection_cases_tax_chk
        CHECK (tax_rate BETWEEN 0 AND 100),
    CONSTRAINT procurement_iqc_rejection_cases_qty_chk
        CHECK (received_base_qty > 0 AND received_qty>0
            AND failed_base_qty > 0
            AND failed_base_qty <= received_base_qty
            AND failed_qty > 0 AND failed_qty<=received_qty),
    CONSTRAINT procurement_iqc_rejection_cases_amount_chk
        CHECK (received_amount_original>=0 AND received_amount_local>=0
            AND failed_amount_original >= 0
            AND failed_amount_local >= 0
            AND failed_amount_original<=received_amount_original
            AND failed_amount_local<=received_amount_local
            AND (failed_base_qty<>received_base_qty
                 OR (failed_amount_original=received_amount_original
                     AND failed_amount_local=received_amount_local))),
    CONSTRAINT procurement_iqc_rejection_cases_return_shape_chk CHECK (
        (status='PENDING_RETURN'
            AND return_reference IS NULL AND return_date IS NULL
            AND return_recorded_by IS NULL AND return_recorded_at IS NULL)
        OR
        (status IN ('RETURN_RECORDED','CREDIT_CONFIRMED','CLOSED_NO_CREDIT')
            AND NULLIF(btrim(return_reference),'') IS NOT NULL
            AND return_date IS NOT NULL
            AND NULLIF(btrim(return_note),'') IS NOT NULL
            AND return_recorded_by IS NOT NULL AND return_recorded_at IS NOT NULL)
        OR (status='FINANCE_EXCEPTION' AND (
            (return_reference IS NULL AND return_date IS NULL
                AND return_recorded_by IS NULL AND return_recorded_at IS NULL)
            OR
            (NULLIF(btrim(return_reference),'') IS NOT NULL
                AND return_date IS NOT NULL
                AND NULLIF(btrim(return_note),'') IS NOT NULL
                AND return_recorded_by IS NOT NULL
                AND return_recorded_at IS NOT NULL)))
        OR status='REVERSED'),
    CONSTRAINT procurement_iqc_rejection_cases_credit_shape_chk CHECK (
        (status='CREDIT_CONFIRMED'
            AND failed_amount_original > 0 AND failed_amount_local > 0
            AND credit_source_id IS NOT NULL AND credit_ledger_id IS NOT NULL
            AND NULLIF(btrim(credit_reference),'') IS NOT NULL
            AND credit_date IS NOT NULL
            AND NULLIF(btrim(credit_reason),'') IS NOT NULL
            AND credit_confirmed_by IS NOT NULL AND credit_confirmed_at IS NOT NULL)
        OR status<>'CREDIT_CONFIRMED'),
    CONSTRAINT procurement_iqc_rejection_cases_no_credit_shape_chk CHECK (
        (status='CLOSED_NO_CREDIT'
            AND failed_amount_original=0 AND failed_amount_local=0
            AND NULLIF(btrim(closed_no_credit_reason),'') IS NOT NULL
            AND closed_no_credit_by IS NOT NULL AND closed_no_credit_at IS NOT NULL
            AND credit_ledger_id IS NULL)
        OR status<>'CLOSED_NO_CREDIT'),
    CONSTRAINT procurement_iqc_rejection_cases_exception_shape_chk CHECK (
        (status='FINANCE_EXCEPTION'
            AND NULLIF(btrim(finance_exception_code),'') IS NOT NULL
            AND NULLIF(btrim(finance_exception_message),'') IS NOT NULL
            AND finance_exception_at IS NOT NULL)
        OR status<>'FINANCE_EXCEPTION'),
    CONSTRAINT procurement_iqc_rejection_cases_reversed_shape_chk CHECK (
        (status='REVERSED'
            AND previous_status IS NOT NULL
            AND NULLIF(btrim(reverse_reason),'') IS NOT NULL
            AND reversed_at IS NOT NULL)
        OR status<>'REVERSED')
);

CREATE INDEX idx_procurement_iqc_rejection_queue
    ON procurement_iqc_rejection_cases(status, receipt_type, created_at, id)
    WHERE is_deleted=FALSE;
CREATE INDEX idx_procurement_iqc_rejection_receipt
    ON procurement_iqc_rejection_cases(receipt_type, receipt_id, id)
    WHERE is_deleted=FALSE;
CREATE INDEX idx_procurement_iqc_rejection_order_item
    ON procurement_iqc_rejection_cases(order_item_id, status, id)
    WHERE is_deleted=FALSE;
CREATE INDEX idx_procurement_iqc_rejection_source_ap
    ON procurement_iqc_rejection_cases(source_ap_ledger_id, status, id)
    WHERE is_deleted=FALSE;

CREATE TABLE procurement_iqc_rejection_events (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                     UUID NOT NULL
        REFERENCES procurement_iqc_rejection_cases(id) ON DELETE RESTRICT,
    event_type                  TEXT NOT NULL,
    source_inspection_event_id  UUID,
    command_id                  UUID,
    actor_user_id               UUID REFERENCES users(id) ON DELETE SET NULL,
    reference                   TEXT,
    event_date                  DATE,
    reason                      TEXT,
    payload                     JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT procurement_iqc_rejection_events_type_chk CHECK (
        event_type IN (
            'FAIL_DETECTED','FAIL_PROJECTED','FINANCE_EXCEPTION',
            'FINANCE_PROJECTION_RETRIED','RETURN_RECORDED',
            'CREDIT_CONFIRMED','CLOSED_NO_CREDIT',
            'CREDIT_REVERSED','RETURN_REVERSED','NO_CREDIT_REVERSED',
            'SOURCE_RECEIPT_REVERSED','REPLACEMENT_ALLOCATED',
            'REPLACEMENT_ALLOCATION_REVERSED')),
    CONSTRAINT procurement_iqc_rejection_events_reason_chk CHECK (
        event_type IN ('FAIL_DETECTED','FAIL_PROJECTED','REPLACEMENT_ALLOCATED',
                       'REPLACEMENT_ALLOCATION_REVERSED')
        OR NULLIF(btrim(reason),'') IS NOT NULL)
);

CREATE UNIQUE INDEX uq_procurement_iqc_rejection_source_event
    ON procurement_iqc_rejection_events(source_inspection_event_id)
    WHERE source_inspection_event_id IS NOT NULL;
CREATE INDEX idx_procurement_iqc_rejection_event_timeline
    ON procurement_iqc_rejection_events(case_id, created_at, id);

CREATE TABLE procurement_iqc_rejection_commands (
    id                  UUID PRIMARY KEY,
    case_id             UUID NOT NULL
        REFERENCES procurement_iqc_rejection_cases(id) ON DELETE RESTRICT,
    command_type        TEXT NOT NULL,
    expected_version    BIGINT NOT NULL,
    actor_user_id       UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    request_hash        TEXT NOT NULL,
    result_status       TEXT NOT NULL,
    result_version      BIGINT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT procurement_iqc_rejection_commands_type_chk CHECK (
        command_type IN (
            'RECORD_RETURN','CONFIRM_CREDIT','CLOSE_NO_CREDIT',
            'REVERSE','RETRY_FINANCE_PROJECTION')),
    CONSTRAINT procurement_iqc_rejection_commands_version_chk CHECK (
        expected_version >= 1 AND result_version >= 1),
    CONSTRAINT procurement_iqc_rejection_commands_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX idx_procurement_iqc_rejection_commands_case
    ON procurement_iqc_rejection_commands(case_id, created_at, id);

CREATE TABLE procurement_iqc_replacement_allocations (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                     UUID NOT NULL
        REFERENCES procurement_iqc_rejection_cases(id) ON DELETE RESTRICT,
    replacement_receipt_type    TEXT NOT NULL,
    replacement_receipt_id      UUID NOT NULL,
    replacement_receipt_item_id UUID NOT NULL,
    allocated_base_qty          NUMERIC(18,4) NOT NULL,
    allocated_qty               NUMERIC(18,4) NOT NULL,
    allocated_amount_original   NUMERIC(18,4) NOT NULL,
    allocated_amount_local      NUMERIC(18,4) NOT NULL,
    status                      TEXT NOT NULL DEFAULT 'ACTIVE',
    row_version                 BIGINT NOT NULL DEFAULT 1,
    created_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    reversed_by                 UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    reversed_at                 TIMESTAMPTZ,
    reverse_reason              TEXT,
    CONSTRAINT procurement_iqc_replacement_allocations_uk
        UNIQUE(case_id,replacement_receipt_item_id),
    CONSTRAINT procurement_iqc_replacement_allocations_type_chk
        CHECK (replacement_receipt_type IN ('PURCHASE','SUBCONTRACT')),
    CONSTRAINT procurement_iqc_replacement_allocations_status_chk
        CHECK (status IN ('ACTIVE','REVERSED')),
    CONSTRAINT procurement_iqc_replacement_allocations_qty_chk
        CHECK (allocated_base_qty>0 AND allocated_qty>0),
    CONSTRAINT procurement_iqc_replacement_allocations_amount_chk
        CHECK (allocated_amount_original>=0 AND allocated_amount_local>=0),
    CONSTRAINT procurement_iqc_replacement_allocations_version_chk
        CHECK (row_version>=1),
    CONSTRAINT procurement_iqc_replacement_allocations_reverse_shape_chk CHECK (
        (status='ACTIVE' AND reversed_at IS NULL AND reversed_by IS NULL)
        OR
        (status='REVERSED' AND reversed_at IS NOT NULL
            AND reversed_by IS NOT NULL
            AND NULLIF(btrim(reverse_reason),'') IS NOT NULL))
);

CREATE INDEX idx_procurement_iqc_replacement_receipt
    ON procurement_iqc_replacement_allocations(
        replacement_receipt_type,replacement_receipt_id,status,id);
CREATE INDEX idx_procurement_iqc_replacement_case
    ON procurement_iqc_replacement_allocations(case_id,status,id);

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_replacement_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_case RECORD;
    v_receipt_id UUID;
    v_order_item_id UUID;
    v_goods_id UUID;
    v_color_id UUID;
    v_unit_id UUID;
    v_unit_rate NUMERIC(18,6);
    v_receipt_qty NUMERIC(18,4);
    v_receipt_original NUMERIC(18,4);
    v_receipt_local NUMERIC(18,4);
    v_case_qty NUMERIC(18,4);
    v_case_base NUMERIC(18,4);
    v_case_original NUMERIC(18,4);
    v_case_local NUMERIC(18,4);
    v_item_qty NUMERIC(18,4);
    v_item_base NUMERIC(18,4);
    v_item_original NUMERIC(18,4);
    v_item_local NUMERIC(18,4);
BEGIN
    SELECT receipt_type,order_item_id,goods_id,color_id,unit_id,unit_rate,
           failed_qty,failed_base_qty,failed_amount_original,
           failed_amount_local,return_recorded_at,status
      INTO v_case
    FROM procurement_iqc_rejection_cases
    WHERE id=NEW.case_id AND is_deleted=FALSE
    FOR UPDATE;
    IF NOT FOUND OR v_case.return_recorded_at IS NULL
       OR v_case.status NOT IN(
           'RETURN_RECORDED','CREDIT_CONFIRMED',
           'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
       OR v_case.receipt_type<>NEW.replacement_receipt_type THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='replacement allocation requires an active physically returned IQC case',
            CONSTRAINT='procurement_iqc_replacement_case_guard';
    END IF;

    IF NEW.replacement_receipt_type='PURCHASE' THEN
        SELECT item.receipt_id,item.order_item_id,item.goods_id,item.color_id,
               item.unit_id,item.unit_rate,item.qty,item.amount_original,
               item.amount_local
          INTO v_receipt_id,v_order_item_id,v_goods_id,v_color_id,
               v_unit_id,v_unit_rate,v_receipt_qty,v_receipt_original,
               v_receipt_local
        FROM purchase_receipt_items item
        JOIN purchase_receipts receipt ON receipt.id=item.receipt_id
        WHERE item.id=NEW.replacement_receipt_item_id
          AND receipt.id=NEW.replacement_receipt_id
          AND receipt.status IN(0,1)
          AND item.is_deleted=FALSE AND receipt.is_deleted=FALSE;
    ELSE
        SELECT item.receipt_id,item.order_item_id,item.goods_id,item.color_id,
               item.unit_id,item.unit_rate,item.qty,item.amount_original,
               item.amount_local
          INTO v_receipt_id,v_order_item_id,v_goods_id,v_color_id,
               v_unit_id,v_unit_rate,v_receipt_qty,v_receipt_original,
               v_receipt_local
        FROM subcontract_receipt_items item
        JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id
        WHERE item.id=NEW.replacement_receipt_item_id
          AND receipt.id=NEW.replacement_receipt_id
          AND receipt.status IN(0,1)
          AND item.is_deleted=FALSE AND receipt.is_deleted=FALSE;
    END IF;
    IF v_receipt_id IS NULL
       OR v_order_item_id<>v_case.order_item_id
       OR v_goods_id<>v_case.goods_id
       OR v_color_id IS DISTINCT FROM v_case.color_id
       OR v_unit_id IS DISTINCT FROM v_case.unit_id
       OR v_unit_rate IS DISTINCT FROM v_case.unit_rate THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='replacement receipt item differs from the returned IQC source identity',
            CONSTRAINT='procurement_iqc_replacement_receipt_identity_guard';
    END IF;

    IF NEW.status='ACTIVE' THEN
        SELECT COALESCE(SUM(allocated_qty),0),
               COALESCE(SUM(allocated_base_qty),0),
               COALESCE(SUM(allocated_amount_original),0),
               COALESCE(SUM(allocated_amount_local),0)
          INTO v_case_qty,v_case_base,v_case_original,v_case_local
        FROM procurement_iqc_replacement_allocations
        WHERE case_id=NEW.case_id AND status='ACTIVE'
          AND id<>NEW.id;
        v_case_qty:=v_case_qty+NEW.allocated_qty;
        v_case_base:=v_case_base+NEW.allocated_base_qty;
        v_case_original:=v_case_original+NEW.allocated_amount_original;
        v_case_local:=v_case_local+NEW.allocated_amount_local;
        IF v_case_qty>v_case.failed_qty
           OR v_case_base>v_case.failed_base_qty
           OR v_case_original>v_case.failed_amount_original
           OR v_case_local>v_case.failed_amount_local THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='replacement allocation exceeds the returned IQC failure slice',
                CONSTRAINT='procurement_iqc_replacement_case_capacity_guard';
        END IF;

        SELECT COALESCE(SUM(allocated_qty),0),
               COALESCE(SUM(allocated_base_qty),0),
               COALESCE(SUM(allocated_amount_original),0),
               COALESCE(SUM(allocated_amount_local),0)
          INTO v_item_qty,v_item_base,v_item_original,v_item_local
        FROM procurement_iqc_replacement_allocations
        WHERE replacement_receipt_item_id=NEW.replacement_receipt_item_id
          AND status='ACTIVE' AND id<>NEW.id;
        v_item_qty:=v_item_qty+NEW.allocated_qty;
        v_item_base:=v_item_base+NEW.allocated_base_qty;
        v_item_original:=v_item_original+NEW.allocated_amount_original;
        v_item_local:=v_item_local+NEW.allocated_amount_local;
        IF v_item_qty>v_receipt_qty
           OR v_item_base>round(v_receipt_qty*v_unit_rate,4)
           OR v_item_original>v_receipt_original
           OR v_item_local>v_receipt_local THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='replacement allocations exceed the authoritative receipt item',
                CONSTRAINT='procurement_iqc_replacement_item_capacity_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_01_guard_procurement_iqc_replacement_identity
    BEFORE INSERT OR UPDATE ON procurement_iqc_replacement_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_replacement_identity();
ALTER TABLE procurement_iqc_replacement_allocations
    ENABLE ALWAYS TRIGGER trg_01_guard_procurement_iqc_replacement_identity;

CREATE OR REPLACE FUNCTION fn_reject_procurement_iqc_append_only_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE='55000',
        MESSAGE=TG_TABLE_NAME || ' is append-only',
        CONSTRAINT='procurement_iqc_rejection_append_only_guard';
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_00_reject_procurement_iqc_event_mutation
    BEFORE UPDATE OR DELETE ON procurement_iqc_rejection_events
    FOR EACH ROW EXECUTE FUNCTION fn_reject_procurement_iqc_append_only_mutation();
ALTER TABLE procurement_iqc_rejection_events
    ENABLE ALWAYS TRIGGER trg_00_reject_procurement_iqc_event_mutation;

CREATE TRIGGER trg_00_reject_procurement_iqc_command_mutation
    BEFORE UPDATE OR DELETE ON procurement_iqc_rejection_commands
    FOR EACH ROW EXECUTE FUNCTION fn_reject_procurement_iqc_append_only_mutation();
ALTER TABLE procurement_iqc_rejection_commands
    ENABLE ALWAYS TRIGGER trg_00_reject_procurement_iqc_command_mutation;

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_rejection_case_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.row_version <> OLD.row_version + 1 THEN
        RAISE EXCEPTION USING ERRCODE='40001',
            MESSAGE='IQC rejection case version must advance exactly once',
            CONSTRAINT='procurement_iqc_rejection_case_cas_guard';
    END IF;
    IF (NEW.receipt_type,NEW.receipt_id,NEW.receipt_item_id,
        NEW.inspection_item_id,NEW.order_item_id,NEW.receipt_bill_no,
        NEW.order_bill_no,NEW.owner_user_id,
        NEW.supplier_id,NEW.currency_id,NEW.exchange_rate,NEW.tax_rate,
        NEW.settlement_method_id,NEW.goods_id,NEW.color_id,NEW.unit_id,
        NEW.unit_rate,NEW.received_base_qty,NEW.received_qty,
        NEW.received_amount_original,NEW.received_amount_local)
       IS DISTINCT FROM
       (OLD.receipt_type,OLD.receipt_id,OLD.receipt_item_id,
        OLD.inspection_item_id,OLD.order_item_id,OLD.receipt_bill_no,
        OLD.order_bill_no,OLD.owner_user_id,
        OLD.supplier_id,OLD.currency_id,OLD.exchange_rate,OLD.tax_rate,
        OLD.settlement_method_id,OLD.goods_id,OLD.color_id,OLD.unit_id,
        OLD.unit_rate,OLD.received_base_qty,OLD.received_qty,
        OLD.received_amount_original,OLD.received_amount_local) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='IQC rejection commercial/source snapshot is immutable',
            CONSTRAINT='procurement_iqc_rejection_snapshot_guard';
    END IF;
    IF (NEW.failed_base_qty,NEW.failed_qty,
        NEW.failed_amount_original,NEW.failed_amount_local)
       IS DISTINCT FROM
       (OLD.failed_base_qty,OLD.failed_qty,
        OLD.failed_amount_original,OLD.failed_amount_local)
       AND NOT (
           OLD.status IN('PENDING_RETURN','FINANCE_EXCEPTION')
           AND NEW.status IN('PENDING_RETURN','FINANCE_EXCEPTION')
           AND OLD.return_recorded_at IS NULL
           AND NEW.return_recorded_at IS NULL
       ) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='IQC rejection amount/AP snapshot is frozen after physical return',
            CONSTRAINT='procurement_iqc_rejection_amount_stage_guard';
    END IF;
    IF NEW.source_ap_ledger_id IS DISTINCT FROM OLD.source_ap_ledger_id
       AND NOT (
           OLD.status='FINANCE_EXCEPTION'
           AND NEW.status IN(
               'FINANCE_EXCEPTION','PENDING_RETURN','RETURN_RECORDED')
       ) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='IQC rejection source AP can change only during finance exception repair',
            CONSTRAINT='procurement_iqc_rejection_source_ap_stage_guard';
    END IF;
    IF EXISTS(
        SELECT 1 FROM procurement_iqc_replacement_allocations allocation
        WHERE allocation.case_id=OLD.id AND allocation.status='ACTIVE')
       AND (
           (OLD.return_recorded_at IS NOT NULL
            AND NEW.return_recorded_at IS NULL)
           OR NEW.status='REVERSED'
           OR (OLD.status IN('CREDIT_CONFIRMED','CLOSED_NO_CREDIT')
               AND NEW.status IS DISTINCT FROM OLD.status)
       ) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='active replacement receipt must be reversed before IQC case reversal',
            CONSTRAINT='procurement_iqc_rejection_active_replacement_guard';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_00_guard_procurement_iqc_rejection_case_update
    BEFORE UPDATE ON procurement_iqc_rejection_cases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_rejection_case_update();
ALTER TABLE procurement_iqc_rejection_cases
    ENABLE ALWAYS TRIGGER trg_00_guard_procurement_iqc_rejection_case_update;

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_replacement_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.row_version <> OLD.row_version + 1
       OR NEW.status<>'REVERSED' OR OLD.status<>'ACTIVE'
       OR (NEW.case_id,NEW.replacement_receipt_type,NEW.replacement_receipt_id,
           NEW.replacement_receipt_item_id,NEW.allocated_base_qty,
           NEW.allocated_qty,NEW.allocated_amount_original,
           NEW.allocated_amount_local)
          IS DISTINCT FROM
          (OLD.case_id,OLD.replacement_receipt_type,OLD.replacement_receipt_id,
           OLD.replacement_receipt_item_id,OLD.allocated_base_qty,
           OLD.allocated_qty,OLD.allocated_amount_original,
           OLD.allocated_amount_local) THEN
        RAISE EXCEPTION USING ERRCODE='40001',
            MESSAGE='IQC replacement allocation only supports controlled reversal',
            CONSTRAINT='procurement_iqc_replacement_cas_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_00_guard_procurement_iqc_replacement_update
    BEFORE UPDATE ON procurement_iqc_replacement_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_replacement_update();
ALTER TABLE procurement_iqc_replacement_allocations
    ENABLE ALWAYS TRIGGER trg_00_guard_procurement_iqc_replacement_update;

CREATE TRIGGER trg_audit_procurement_iqc_rejection_cases
    AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_rejection_cases
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_procurement_iqc_rejection_events
    AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_rejection_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_procurement_iqc_rejection_commands
    AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_rejection_commands
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_procurement_iqc_replacement_allocations
    AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_replacement_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_guard_procurement_received_with_arrival_allowance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_received NUMERIC;
    v_new_received NUMERIC := COALESCE(NEW.received_qty,0);
    v_iqc_replacement NUMERIC;
    v_capacity NUMERIC;
    v_current_receipt TEXT :=
        current_setting('app.procurement_arrival_receipt_id',TRUE);
    v_current_type TEXT :=
        current_setting('app.procurement_arrival_order_type',TRUE);
    v_receipt_extra NUMERIC := 0;
BEGIN
    v_old_received := CASE WHEN TG_OP='INSERT' THEN 0
        ELSE COALESCE(OLD.received_qty,0) END;
    IF v_new_received<0 THEN
        RAISE EXCEPTION 'received_qty cannot be negative'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    SELECT COALESCE(SUM(rejection.failed_qty),0)
      INTO v_iqc_replacement
    FROM procurement_iqc_rejection_cases rejection
    WHERE rejection.receipt_type=TG_ARGV[0]
      AND rejection.order_item_id=NEW.id
      AND rejection.is_deleted=FALSE
      AND rejection.return_recorded_at IS NOT NULL
      AND rejection.status IN(
          'RETURN_RECORDED','CREDIT_CONFIRMED',
          'CLOSED_NO_CREDIT','FINANCE_EXCEPTION');
    v_capacity := COALESCE(NEW.qty,0)
        + COALESCE(NEW.returned_qty,0)
        + COALESCE(NEW.arrival_overage_posted_qty,0)
        + v_iqc_replacement;
    IF v_current_receipt IS NOT NULL AND v_current_receipt<>''
       AND v_current_type=TG_ARGV[0] THEN
        SELECT COALESCE(SUM(exception.approved_excess_qty),0)
          INTO v_receipt_extra
        FROM procurement_arrival_exceptions exception
        WHERE exception.order_type=TG_ARGV[0]
          AND exception.receipt_id=v_current_receipt::UUID
          AND exception.order_item_id=NEW.id
          AND exception.status='RECEIPT_ADJUSTED';
    END IF;
    IF v_new_received>v_old_received
       AND v_new_received>v_capacity+v_receipt_extra THEN
        RAISE EXCEPTION 'received_qty exceeds finance-approved arrival capacity'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    RETURN NEW;
END;
$$;

-- ======================== AP hold authority ========================

CREATE OR REPLACE FUNCTION fn_procurement_iqc_ap_hold_reason(
    p_ledger_id UUID,
    p_allowed_case_id UUID DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    WITH source AS (
        SELECT ledger.id,ledger.source_doc_type,ledger.source_doc_id
        FROM ar_ap_ledger ledger
        WHERE ledger.id=p_ledger_id
          AND ledger.direction='AP'
          AND ledger.status=1
          AND COALESCE(ledger.is_deleted,FALSE)=FALSE
          AND ledger.source_doc_type IN(
              'PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT')
    ),
    linked AS (
        SELECT inspection.id,inspection.status,
               inspection.received_base_qty,
               inspection.passed_base_qty,
               inspection.failed_base_qty,
               rejection.id case_id,rejection.status case_status,
               rejection.source_ap_ledger_id,rejection.credit_ledger_id
        FROM source
        JOIN procurement_inspection_items inspection
          ON inspection.receipt_type=CASE source.source_doc_type
              WHEN 'PURCHASE_RECEIPT' THEN 'PURCHASE' ELSE 'SUBCONTRACT' END
         AND inspection.receipt_id=source.source_doc_id
         AND inspection.status<>'REVERSED'
        LEFT JOIN procurement_iqc_rejection_cases rejection
          ON rejection.inspection_item_id=inspection.id
         AND rejection.is_deleted=FALSE
    )
    SELECT CASE
        WHEN NOT EXISTS(SELECT 1 FROM linked) THEN NULL
        WHEN p_allowed_case_id IS NOT NULL AND EXISTS(
            SELECT 1
            FROM procurement_iqc_rejection_cases allowed_case
            JOIN ar_ap_ledger allowed_credit
              ON allowed_credit.source_doc_id=allowed_case.id
             AND allowed_credit.source_doc_type=CASE
                 WHEN allowed_case.receipt_type='PURCHASE'
                 THEN 'PURCHASE_IQC_CREDIT'
                 ELSE 'SUBCONTRACT_IQC_CREDIT' END
             AND allowed_credit.direction='AP' AND allowed_credit.status=1
             AND allowed_credit.is_deleted=FALSE
            WHERE allowed_case.id=p_allowed_case_id
              AND allowed_case.status='RETURN_RECORDED'
              AND allowed_case.source_ap_ledger_id=p_ledger_id)
          THEN NULL
        WHEN EXISTS(
            SELECT 1 FROM linked
            WHERE status IN('PENDING','PARTIAL'))
          THEN 'IQC待检或部分处置尚未结案'
        WHEN EXISTS(
            SELECT 1 FROM linked
            WHERE status='RESOLVED' AND failed_base_qty>0
              AND NOT (
                  COALESCE(case_status,'') IN(
                      'CREDIT_CONFIRMED','CLOSED_NO_CREDIT')
                  OR (p_allowed_case_id IS NOT NULL
                      AND case_id=p_allowed_case_id
                      AND case_status='RETURN_RECORDED'
                      AND source_ap_ledger_id=p_ledger_id
                      AND EXISTS(
                          SELECT 1 FROM ar_ap_ledger credit
                          WHERE credit.source_doc_id=case_id
                            AND credit.source_doc_type=CASE
                                WHEN (SELECT receipt_type
                                      FROM procurement_iqc_rejection_cases
                                      WHERE id=case_id)='PURCHASE'
                                THEN 'PURCHASE_IQC_CREDIT'
                                ELSE 'SUBCONTRACT_IQC_CREDIT' END
                            AND credit.direction='AP' AND credit.status=1
                            AND credit.is_deleted=FALSE))
              ))
          THEN 'IQC不合格退回或供应商贷项尚未闭环'
        ELSE NULL
    END
$$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_ap_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_allowed_case UUID;
    v_reason TEXT;
BEGIN
    IF (NEW.amount_received_original,NEW.amount_received_local,
        NEW.amount_settled,NEW.amount_write_off_original,
        NEW.amount_write_off_local,
        NEW.amount_offset_original,NEW.amount_offset_local,
        NEW.amount_balance_original,NEW.amount_balance,NEW.is_settled)
       IS NOT DISTINCT FROM
       (OLD.amount_received_original,OLD.amount_received_local,
        OLD.amount_settled,OLD.amount_write_off_original,
        OLD.amount_write_off_local,
        OLD.amount_offset_original,OLD.amount_offset_local,
        OLD.amount_balance_original,OLD.amount_balance,OLD.is_settled) THEN
        RETURN NEW;
    END IF;
    BEGIN
        v_allowed_case := NULLIF(
            current_setting('app.iqc_offset_case_id',TRUE),'')::UUID;
    EXCEPTION WHEN invalid_text_representation THEN
        v_allowed_case := NULL;
    END;
    v_reason := fn_procurement_iqc_ap_hold_reason(OLD.id,v_allowed_case);
    IF v_reason IS NOT NULL AND (
        COALESCE(NEW.amount_received_original,0)>
            COALESCE(OLD.amount_received_original,0)
        OR COALESCE(NEW.amount_received_local,0)>
            COALESCE(OLD.amount_received_local,0)
        OR COALESCE(NEW.amount_settled,0)>COALESCE(OLD.amount_settled,0)
        OR COALESCE(NEW.amount_offset_original,0)>
            COALESCE(OLD.amount_offset_original,0)
        OR COALESCE(NEW.amount_offset_local,0)>
            COALESCE(OLD.amount_offset_local,0)
        OR COALESCE(NEW.amount_write_off_original,0)>
            COALESCE(OLD.amount_write_off_original,0)
        OR COALESCE(NEW.amount_write_off_local,0)>
            COALESCE(OLD.amount_write_off_local,0)
        OR COALESCE(NEW.amount_balance_original,0)<
            COALESCE(OLD.amount_balance_original,0)
        OR COALESCE(NEW.amount_balance,0)<COALESCE(OLD.amount_balance,0)
    ) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='supplier payable is held: ' || v_reason,
            CONSTRAINT='procurement_iqc_ap_hold_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_00_guard_procurement_iqc_ap_mutation
    BEFORE UPDATE ON ar_ap_ledger
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_ap_mutation();
ALTER TABLE ar_ap_ledger
    ENABLE ALWAYS TRIGGER trg_00_guard_procurement_iqc_ap_mutation;

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_settlement_line()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_reason TEXT;
BEGIN
    v_reason := fn_procurement_iqc_ap_hold_reason(NEW.ledger_id,NULL);
    IF v_reason IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='supplier settlement contains held payable: ' || v_reason,
            CONSTRAINT='procurement_iqc_settlement_hold_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_00_guard_procurement_iqc_settlement_line
    BEFORE INSERT OR UPDATE ON supplier_settlement_batch_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_settlement_line();
ALTER TABLE supplier_settlement_batch_lines
    ENABLE ALWAYS TRIGGER trg_00_guard_procurement_iqc_settlement_line;

-- Register the two dedicated negative-AP source types.  They remain CREDIT open
-- items, preserve supplier/currency/rate identity, and may retain an open
-- remainder when the positive source AP has already been partly paid.
ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_source_doc_type_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_source_doc_type_chk CHECK (
    source_doc_type = ANY(ARRAY[
        'SALES_SHIPMENT','SALES_RETURN','PURCHASE_RECEIPT','PURCHASE_RETURN',
        'PURCHASE_IQC_CREDIT','SUBCONTRACT_RECEIPT','SUBCONTRACT_RETURN',
        'SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET','SUBCONTRACT_IQC_CREDIT',
        'DIRECT_RECEIPT','DIRECT_PAYMENT']));

CREATE OR REPLACE FUNCTION fn_derive_ar_ap_open_item_metadata()
RETURNS TRIGGER AS $$
BEGIN
    NEW.business_type := CASE
        WHEN NEW.direction='AR' THEN 'SALES'
        WHEN NEW.source_doc_type IN(
            'PURCHASE_RECEIPT','PURCHASE_RETURN','PURCHASE_IQC_CREDIT')
            THEN 'PURCHASE'
        WHEN NEW.source_doc_type IN(
            'SUBCONTRACT_RECEIPT','SUBCONTRACT_RETURN','SUBCONTRACT_WASTE',
            'SUBCONTRACT_LOSS_OFFSET','SUBCONTRACT_IQC_CREDIT')
            THEN 'SUBCONTRACT'
        ELSE 'DIRECT'
    END;
    NEW.open_item_kind := CASE
        WHEN NEW.direction='AR' AND NEW.source_doc_type='DIRECT_RECEIPT'
            THEN 'CUSTOMER_PREPAYMENT'
        WHEN NEW.direction='AR' THEN 'RECEIVABLE'
        WHEN NEW.source_doc_type='DIRECT_PAYMENT' THEN 'PREPAYMENT'
        WHEN NEW.source_doc_type IN(
            'SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET')
            THEN 'CLAIM_CREDIT'
        WHEN COALESCE(NEW.amount_original_local,0)<0 THEN 'CREDIT'
        ELSE 'PAYABLE'
    END;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ======================== zero-grant permission surface ========================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM permissions permission
        WHERE permission.code IN(
            'procurement_iqc_rejection:view',
            'procurement_iqc_rejection:view_all',
            'procurement_iqc_rejection:amount:view',
            'procurement_iqc_rejection:record_return',
            'procurement_iqc_rejection:confirm_credit',
            'procurement_iqc_rejection:close_no_credit',
            'procurement_iqc_rejection:reverse')
          AND (
              EXISTS(SELECT 1 FROM department_permissions x
                     WHERE x.permission_id=permission.id)
              OR EXISTS(SELECT 1 FROM role_permissions x
                        WHERE x.permission_id=permission.id)
              OR EXISTS(SELECT 1 FROM user_permission_overrides x
                        WHERE x.permission_id=permission.id)
              OR EXISTS(SELECT 1 FROM manager_permission_delegations x
                        WHERE x.permission_id=permission.id)
          )
    ) THEN
        RAISE EXCEPTION
            'V440 refuses pre-existing IQC rejection permission grants';
    END IF;
END;
$$;

INSERT INTO permissions(
    code,name,module,category,sort_order,action_type,description,active,assignable)
VALUES
    ('procurement_iqc_rejection:view','查看IQC不合格闭环',
     '采购管理','IQC不合格闭环',265,'VIEW',
     '查看本人归属的采购/委外IQC不合格闭环任务',TRUE,TRUE),
    ('procurement_iqc_rejection:view_all','查看全部IQC不合格闭环',
     '采购管理','IQC不合格闭环',266,'VIEW',
     '跨归属查看全部采购/委外IQC不合格闭环任务',TRUE,TRUE),
    ('procurement_iqc_rejection:amount:view','查看IQC不合格金额',
     '采购管理','IQC不合格闭环',267,'VIEW',
     '查看失败原币/本币金额与供应商贷项金额',TRUE,TRUE),
    ('procurement_iqc_rejection:record_return','登记IQC不合格实物退回',
     '采购管理','IQC不合格闭环',268,'EXECUTE',
     '跨归属执行队列登记结构化实物退回事实',TRUE,TRUE),
    ('procurement_iqc_rejection:confirm_credit','确认IQC供应商贷项',
     '采购管理','IQC不合格闭环',269,'APPROVE',
     '财务确认供应商贷项并生成专用负应付及受控抵销',TRUE,TRUE),
    ('procurement_iqc_rejection:close_no_credit','确认零金额无需贷项',
     '采购管理','IQC不合格闭环',270,'APPROVE',
     '财务对零金额不合格任务确认无需生成贷项',TRUE,TRUE),
    ('procurement_iqc_rejection:reverse','反向IQC不合格闭环',
     '采购管理','IQC不合格闭环',271,'EXECUTE',
     '按闭账与下游约束反向贷项、零金额结案或实物退回',TRUE,TRUE)
ON CONFLICT(code) DO UPDATE SET
    name=EXCLUDED.name,module=EXCLUDED.module,category=EXCLUDED.category,
    sort_order=EXCLUDED.sort_order,action_type=EXCLUDED.action_type,
    description=EXCLUDED.description,active=TRUE,assignable=TRUE;

DO $$
BEGIN
    IF EXISTS(
        SELECT 1 FROM permission_surfaces
        WHERE (surface_key='procurement.iqc-rejection'
               AND id<>'44000000-0000-4000-8000-000000000001'::UUID)
           OR (id='44000000-0000-4000-8000-000000000001'::UUID
               AND surface_key<>'procurement.iqc-rejection')
    ) THEN
        RAISE EXCEPTION
            'V440 IQC rejection surface identity conflicts with the stable UUID';
    END IF;
END;
$$;

INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled)
VALUES(
    '44000000-0000-4000-8000-000000000001',
    'procurement.iqc-rejection',
    '采购/委外 IQC 不合格闭环',
    265,
    TRUE)
ON CONFLICT(surface_key) DO UPDATE SET
    name=EXCLUDED.name,sort_order=EXCLUDED.sort_order,enabled=TRUE;

INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN(
    'procurement_iqc_rejection:view',
    'procurement_iqc_rejection:view_all',
    'procurement_iqc_rejection:amount:view',
    'procurement_iqc_rejection:record_return',
    'procurement_iqc_rejection:confirm_credit',
    'procurement_iqc_rejection:close_no_credit',
    'procurement_iqc_rejection:reverse')
WHERE surface.surface_key='procurement.iqc-rejection'
ON CONFLICT(surface_id,permission_id) DO NOTHING;

DO $$
DECLARE
    v_grants BIGINT;
    v_links BIGINT;
BEGIN
    SELECT count(*) INTO v_grants
    FROM (
        SELECT permission_id FROM department_permissions
        UNION ALL SELECT permission_id FROM role_permissions
        UNION ALL SELECT permission_id FROM user_permission_overrides
        UNION ALL SELECT permission_id FROM manager_permission_delegations
    ) grant_row
    JOIN permissions permission ON permission.id=grant_row.permission_id
    WHERE permission.code LIKE 'procurement_iqc_rejection:%';
    IF v_grants<>0 THEN
        RAISE EXCEPTION
            'V440 IQC rejection permissions must start with zero grants';
    END IF;
    SELECT count(*) INTO v_links
    FROM permission_surface_permissions link
    JOIN permission_surfaces surface ON surface.id=link.surface_id
    JOIN permissions permission ON permission.id=link.permission_id
    WHERE surface.surface_key='procurement.iqc-rejection'
      AND permission.code LIKE 'procurement_iqc_rejection:%';
    IF v_links<>7 THEN
        RAISE EXCEPTION 'V440 IQC rejection permission surface is incomplete';
    END IF;
END;
$$;

COMMENT ON TABLE procurement_iqc_rejection_cases IS
    'IQC失败来源/AP/金额冻结投影；质量、实物退回、财务贷项、零金额结案与反向分层';
COMMENT ON TABLE procurement_iqc_rejection_events IS
    'IQC不合格闭环追加式证据账，禁止更新和删除';
COMMENT ON TABLE procurement_iqc_rejection_commands IS
    '用户命令UUID、请求摘要与CAS结果的追加式幂等账';
COMMENT ON TABLE procurement_iqc_replacement_allocations IS
    '已退IQC失败切片对补货收货明细的显式数量/原币/本币分配';
COMMENT ON FUNCTION fn_procurement_iqc_ap_hold_reason(UUID,UUID) IS
    '历史无IQC sidecar放行；待检/部分处置或失败未达贷项/零金额终态时返回冻结原因';
