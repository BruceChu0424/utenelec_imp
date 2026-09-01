-- V442: auditable measurement-capture learning.
--
-- Quantity remains qty + unit UUID + unit_rate. Actual total weight is an
-- independent fact with an explicit unit UUID. A learned profile controls
-- future capture UX only; it never rewrites inventory, prices, historical
-- rows, or goods.m_weight.

ALTER TABLE legacy_migration_runs
    ADD COLUMN source_backup_sha256 VARCHAR(64),
    ADD COLUMN export_approval_reference VARCHAR(200);
ALTER TABLE legacy_migration_runs
    ADD CONSTRAINT legacy_migration_runs_source_backup_hash_chk CHECK (
        source_backup_sha256 IS NULL
        OR source_backup_sha256 ~ '^[0-9a-f]{64}$'
    ),
    ADD CONSTRAINT legacy_migration_runs_export_approval_chk CHECK (
        export_approval_reference IS NULL
        OR export_approval_reference ~
            '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$'
    );

CREATE TABLE unit_measurement_profiles (
    unit_id                 UUID PRIMARY KEY
        REFERENCES units(id) ON DELETE RESTRICT,
    measurement_dimension  VARCHAR(20) NOT NULL,
    canonical_unit_id       UUID
        REFERENCES units(id) ON DELETE RESTRICT,
    to_canonical_factor     NUMERIC(24,12),
    provenance              VARCHAR(30) NOT NULL,
    version                 BIGINT NOT NULL DEFAULT 0,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT unit_measurement_profile_dimension_chk CHECK (
        measurement_dimension IN (
            'COUNT', 'MASS', 'LENGTH', 'AREA', 'VOLUME', 'OTHER'
        )
    ),
    CONSTRAINT unit_measurement_profile_provenance_chk CHECK (
        provenance IN (
            'MANUAL_GOVERNANCE',
            'GOVERNED_IMPORT',
            'LEGACY_EXPLICIT_ID'
        )
    ),
    CONSTRAINT unit_measurement_profile_conversion_chk CHECK (
        (canonical_unit_id IS NULL AND to_canonical_factor IS NULL)
        OR
        (canonical_unit_id IS NOT NULL AND to_canonical_factor > 0)
    ),
    CONSTRAINT unit_measurement_profile_version_chk CHECK (version >= 0)
);

CREATE TABLE measurement_capture_profiles (
    id                                      UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),
    goods_id                                UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    operation_family                        VARCHAR(20) NOT NULL,
    status                                  VARCHAR(20) NOT NULL
        DEFAULT 'UNCLASSIFIED',
    inferred_preference                     VARCHAR(50),
    manual_override_preference              VARCHAR(50),
    effective_preference                    VARCHAR(50),
    business_unit_id                        UUID
        REFERENCES units(id) ON DELETE RESTRICT,
    actual_weight_unit_id                   UUID
        REFERENCES units(id) ON DELETE RESTRICT,
    confidence                              NUMERIC(5,4) NOT NULL DEFAULT 0,
    active_evidence_count                   BIGINT NOT NULL DEFAULT 0,
    quantity_document_count                 BIGINT NOT NULL DEFAULT 0,
    quantity_day_count                      BIGINT NOT NULL DEFAULT 0,
    quantity_and_weight_document_count      BIGINT NOT NULL DEFAULT 0,
    quantity_and_weight_day_count           BIGINT NOT NULL DEFAULT 0,
    inference_conflict                      BOOLEAN NOT NULL DEFAULT FALSE,
    evidence_fingerprint                    VARCHAR(64),
    source_registry_version                 INTEGER,
    version                                 BIGINT NOT NULL DEFAULT 0,
    last_evidence_at                        TIMESTAMPTZ,
    created_at                              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT measurement_capture_profile_family_chk CHECK (
        operation_family IN (
            'PROCUREMENT', 'WAREHOUSE', 'SALES', 'SUBCONTRACT', 'PRODUCTION'
        )
    ),
    CONSTRAINT measurement_capture_profile_status_chk CHECK (
        status IN (
            'UNCLASSIFIED', 'PROVISIONAL', 'CONFIRMED', 'CONFLICT'
        )
    ),
    CONSTRAINT measurement_capture_profile_inferred_preference_chk CHECK (
        inferred_preference IS NULL
        OR inferred_preference IN (
            'BUSINESS_QUANTITY',
            'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
        )
    ),
    CONSTRAINT measurement_capture_profile_manual_preference_chk CHECK (
        manual_override_preference IS NULL
        OR manual_override_preference IN (
            'BUSINESS_QUANTITY',
            'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
        )
    ),
    CONSTRAINT measurement_capture_profile_effective_preference_chk CHECK (
        effective_preference IS NULL
        OR effective_preference IN (
            'BUSINESS_QUANTITY',
            'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
        )
    ),
    CONSTRAINT measurement_capture_profile_effective_projection_chk CHECK (
        effective_preference IS NOT DISTINCT FROM
            COALESCE(manual_override_preference, inferred_preference)
    ),
    CONSTRAINT measurement_capture_profile_confidence_chk CHECK (
        confidence BETWEEN 0 AND 1
    ),
    CONSTRAINT measurement_capture_profile_counts_chk CHECK (
        active_evidence_count >= 0
        AND quantity_document_count >= 0
        AND quantity_day_count >= 0
        AND quantity_and_weight_document_count >= 0
        AND quantity_and_weight_day_count >= 0
        AND quantity_and_weight_document_count <= active_evidence_count
    ),
    CONSTRAINT measurement_capture_profile_conflict_chk CHECK (
        (status <> 'CONFLICT' OR inference_conflict)
        AND (
            status NOT IN ('UNCLASSIFIED', 'PROVISIONAL')
            OR NOT inference_conflict
        )
    ),
    CONSTRAINT measurement_capture_profile_confirmed_shape_chk CHECK (
        status <> 'CONFIRMED'
        OR (
            effective_preference IS NOT NULL
            AND (
                effective_preference <> 'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
                OR actual_weight_unit_id IS NOT NULL
            )
        )
    ),
    CONSTRAINT measurement_capture_profile_fingerprint_chk CHECK (
        evidence_fingerprint IS NULL
        OR evidence_fingerprint ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT measurement_capture_profile_version_chk CHECK (version >= 0),
    CONSTRAINT measurement_capture_profile_dimension_uk
        UNIQUE (goods_id, operation_family)
);

CREATE INDEX idx_measurement_capture_profiles_resolution
    ON measurement_capture_profiles(
        operation_family, goods_id, status, effective_preference
    );

CREATE TABLE measurement_capture_line_snapshots (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_document_type     VARCHAR(80) NOT NULL,
    source_document_id       UUID NOT NULL,
    source_item_id           UUID NOT NULL,
    goods_id                 UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    operation_family         VARCHAR(20) NOT NULL,
    business_qty             NUMERIC(18,4) NOT NULL,
    business_unit_id         UUID NOT NULL
        REFERENCES units(id) ON DELETE RESTRICT,
    unit_rate                NUMERIC(18,6) NOT NULL,
    actual_weight            NUMERIC(18,4),
    actual_weight_unit_id    UUID
        REFERENCES units(id) ON DELETE RESTRICT,
    declared_preference      VARCHAR(50),
    profile_id               UUID
        REFERENCES measurement_capture_profiles(id) ON DELETE RESTRICT,
    profile_version          BIGINT,
    version                  BIGINT NOT NULL DEFAULT 0,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT measurement_capture_line_family_chk CHECK (
        operation_family IN (
            'PROCUREMENT', 'WAREHOUSE', 'SALES', 'SUBCONTRACT', 'PRODUCTION'
        )
    ),
    CONSTRAINT measurement_capture_line_qty_chk CHECK (
        business_qty > 0 AND unit_rate > 0
    ),
    CONSTRAINT measurement_capture_line_weight_chk CHECK (
        (actual_weight IS NULL AND actual_weight_unit_id IS NULL)
        OR (actual_weight > 0 AND actual_weight_unit_id IS NOT NULL)
    ),
    CONSTRAINT measurement_capture_line_preference_chk CHECK (
        declared_preference IS NULL
        OR declared_preference IN (
            'BUSINESS_QUANTITY',
            'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
        )
    ),
    CONSTRAINT measurement_capture_line_declared_shape_chk CHECK (
        declared_preference
            IS DISTINCT FROM 'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
        OR actual_weight IS NOT NULL
    ),
    CONSTRAINT measurement_capture_line_version_chk CHECK (
        version >= 0 AND (profile_version IS NULL OR profile_version >= 0)
    ),
    CONSTRAINT measurement_capture_line_source_uk
        UNIQUE (source_document_type, source_item_id)
);

CREATE INDEX idx_measurement_capture_line_profile
    ON measurement_capture_line_snapshots(profile_id, profile_version);

CREATE TABLE measurement_capture_evidence (
    event_id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id                  UUID NOT NULL
        REFERENCES measurement_capture_profiles(id) ON DELETE RESTRICT,
    goods_id                    UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    operation_family            VARCHAR(20) NOT NULL,
    idempotency_key             VARCHAR(200) NOT NULL,
    stage                       VARCHAR(20) NOT NULL,
    source_document_type        VARCHAR(80) NOT NULL,
    source_document_id          UUID NOT NULL,
    source_item_id              UUID NOT NULL,
    source_event_key            VARCHAR(240) NOT NULL,
    business_qty                NUMERIC(18,4),
    business_unit_id            UUID
        REFERENCES units(id) ON DELETE RESTRICT,
    unit_rate                   NUMERIC(18,6),
    actual_weight               NUMERIC(18,4),
    actual_weight_unit_id       UUID
        REFERENCES units(id) ON DELETE RESTRICT,
    declared_preference         VARCHAR(50),
    weight_capture_available    BOOLEAN NOT NULL,
    reliability                 NUMERIC(5,4) NOT NULL,
    reversible                  BOOLEAN NOT NULL DEFAULT TRUE,
    business_date               DATE NOT NULL,
    reverses_event_id           UUID
        REFERENCES measurement_capture_evidence(event_id)
        ON DELETE RESTRICT,
    reverses_fingerprint        VARCHAR(64),
    payload_fingerprint         VARCHAR(64) NOT NULL,
    evidence_fingerprint        VARCHAR(64) NOT NULL,
    recorded_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    recorded_by                 UUID
        REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT measurement_capture_evidence_family_chk CHECK (
        operation_family IN (
            'PROCUREMENT', 'WAREHOUSE', 'SALES', 'SUBCONTRACT', 'PRODUCTION'
        )
    ),
    CONSTRAINT measurement_capture_evidence_stage_chk CHECK (
        stage IN ('APPROVED', 'POSTED', 'REVERSED')
    ),
    CONSTRAINT measurement_capture_evidence_preference_chk CHECK (
        declared_preference IS NULL
        OR declared_preference IN (
            'BUSINESS_QUANTITY',
            'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
        )
    ),
    CONSTRAINT measurement_capture_evidence_measurement_chk CHECK (
        (
            stage = 'REVERSED'
            AND reverses_event_id IS NOT NULL
            AND reverses_fingerprint IS NOT NULL
        )
        OR
        (
            stage IN ('APPROVED', 'POSTED')
            AND business_qty > 0
            AND business_unit_id IS NOT NULL
            AND unit_rate > 0
            AND reverses_event_id IS NULL
            AND reverses_fingerprint IS NULL
        )
    ),
    CONSTRAINT measurement_capture_evidence_weight_chk CHECK (
        (actual_weight IS NULL AND actual_weight_unit_id IS NULL)
        OR (actual_weight > 0 AND actual_weight_unit_id IS NOT NULL)
    ),
    CONSTRAINT measurement_capture_evidence_declared_shape_chk CHECK (
        declared_preference
            IS DISTINCT FROM 'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
        OR actual_weight IS NOT NULL
    ),
    CONSTRAINT measurement_capture_evidence_reliability_chk CHECK (
        reliability BETWEEN 0 AND 1
    ),
    CONSTRAINT measurement_capture_evidence_payload_hash_chk CHECK (
        payload_fingerprint ~ '^[0-9a-f]{64}$'
        AND evidence_fingerprint ~ '^[0-9a-f]{64}$'
        AND (
            reverses_fingerprint IS NULL
            OR reverses_fingerprint ~ '^[0-9a-f]{64}$'
        )
    ),
    CONSTRAINT measurement_capture_evidence_idempotency_uk
        UNIQUE (idempotency_key),
    CONSTRAINT measurement_capture_evidence_source_event_uk
        UNIQUE (source_event_key)
);

CREATE INDEX idx_measurement_capture_evidence_profile_timeline
    ON measurement_capture_evidence(profile_id, business_date, event_id);
CREATE INDEX idx_measurement_capture_evidence_source
    ON measurement_capture_evidence(
        source_document_type, source_document_id, source_item_id
    );

CREATE TABLE measurement_capture_decision_events (
    event_id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id                     UUID NOT NULL
        REFERENCES measurement_capture_profiles(id) ON DELETE RESTRICT,
    goods_id                       UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    operation_family               VARCHAR(20) NOT NULL,
    idempotency_key                VARCHAR(200) NOT NULL,
    action                         VARCHAR(30) NOT NULL,
    preference                     VARCHAR(50),
    actor_id                       UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    reason                         VARCHAR(500) NOT NULL,
    expected_version               BIGINT NOT NULL,
    resulting_version              BIGINT NOT NULL,
    evidence_fingerprint           VARCHAR(64),
    decided_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT measurement_capture_decision_family_chk CHECK (
        operation_family IN (
            'PROCUREMENT', 'WAREHOUSE', 'SALES', 'SUBCONTRACT', 'PRODUCTION'
        )
    ),
    CONSTRAINT measurement_capture_decision_action_chk CHECK (
        action IN ('OVERRIDE', 'CLEAR_OVERRIDE')
    ),
    CONSTRAINT measurement_capture_decision_preference_chk CHECK (
        (
            action = 'OVERRIDE'
            AND preference IN (
                'BUSINESS_QUANTITY',
                'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
            )
        )
        OR (action = 'CLEAR_OVERRIDE' AND preference IS NULL)
    ),
    CONSTRAINT measurement_capture_decision_reason_chk CHECK (
        reason = btrim(reason) AND length(reason) BETWEEN 2 AND 500
    ),
    CONSTRAINT measurement_capture_decision_version_chk CHECK (
        expected_version >= 0
        AND resulting_version = expected_version + 1
    ),
    CONSTRAINT measurement_capture_decision_fingerprint_chk CHECK (
        evidence_fingerprint IS NULL
        OR evidence_fingerprint ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT measurement_capture_decision_idempotency_uk
        UNIQUE (idempotency_key)
);

CREATE INDEX idx_measurement_capture_decision_profile_timeline
    ON measurement_capture_decision_events(profile_id, decided_at, event_id);

CREATE TABLE legacy_measurement_source_registry (
    registry_version       INTEGER NOT NULL,
    source_code            VARCHAR(50) NOT NULL,
    operation_family       VARCHAR(20),
    evidence_role          VARCHAR(30) NOT NULL,
    quantity_rule          VARCHAR(80) NOT NULL,
    weight_mode            VARCHAR(50) NOT NULL,
    zero_weight_meaning    VARCHAR(40) NOT NULL
        DEFAULT 'UNKNOWN_NOT_CAPTURED',
    weight_unit_evidence   VARCHAR(30) NOT NULL DEFAULT 'UNKNOWN',
    active                 BOOLEAN NOT NULL DEFAULT TRUE,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT legacy_measurement_source_registry_pk
        PRIMARY KEY (registry_version, source_code),
    CONSTRAINT legacy_measurement_source_registry_version_chk CHECK (
        registry_version > 0
    ),
    CONSTRAINT legacy_measurement_source_registry_family_chk CHECK (
        operation_family IS NULL
        OR operation_family IN (
            'PROCUREMENT', 'WAREHOUSE', 'SALES', 'SUBCONTRACT', 'PRODUCTION'
        )
    ),
    CONSTRAINT legacy_measurement_source_registry_role_chk CHECK (
        evidence_role IN (
            'PLANNED', 'PHYSICAL', 'BALANCE', 'STOCKTAKE',
            'BOM_REQUIREMENT', 'EMPTY', 'MASTER_REFERENCE'
        )
    ),
    CONSTRAINT legacy_measurement_source_registry_unit_chk CHECK (
        weight_unit_evidence IN ('UNKNOWN', 'EXPLICIT_UUID')
    )
);

INSERT INTO legacy_measurement_source_registry(
    registry_version, source_code, operation_family, evidence_role,
    quantity_rule, weight_mode
) VALUES
    (1, 'P_APPLICATION_ITEM', 'PROCUREMENT', 'PLANNED', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'P_ORDER_ITEM', 'PROCUREMENT', 'PLANNED', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'P_IN_ITEM', 'PROCUREMENT', 'PHYSICAL', 'QTY_X_URATE', 'OPTIONAL'),
    (1, 'P_WITHDRAW_ITEM', 'PROCUREMENT', 'PHYSICAL', 'QTY_X_URATE', 'OPTIONAL'),
    (1, 'O_TRANSFER_ITEM', 'WAREHOUSE', 'PHYSICAL', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'O_OTHER_IN_ITEM', 'WAREHOUSE', 'PHYSICAL', 'QTY_X_URATE', 'OPTIONAL_SPARSE'),
    (1, 'O_OTHER_OUT_ITEM', 'WAREHOUSE', 'PHYSICAL', 'QTY_X_URATE', 'OPTIONAL'),
    (1, 'O_PDRAW_ITEM', 'WAREHOUSE', 'PHYSICAL', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'O_WDRAW_ITEM', 'WAREHOUSE', 'PHYSICAL', 'QTY_X_URATE', 'OPTIONAL_SPARSE'),
    (1, 'O_IN_ITEM', 'WAREHOUSE', 'PHYSICAL', 'QTY_X_URATE', 'OPTIONAL_MATERIAL'),
    (1, 'O_OUT_ITEM', 'WAREHOUSE', 'PHYSICAL', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'O_CHECK_ITEM', 'WAREHOUSE', 'STOCKTAKE', 'NOWQTY_MINUS_QTY', 'NO_RELIABLE_STOCKTAKE_WEIGHT'),
    (1, 'STOCK_GOODS', 'WAREHOUSE', 'BALANCE', 'LATEST_YEAR_FACTQTY', 'FACT_LEDGER'),
    (1, 'S_QUOTE_ITEM', 'SALES', 'EMPTY', 'BQTY_X_URATE', 'EMPTY_NO_WEIGHT_EXPORT'),
    (1, 'S_ORDER_ITEM', 'SALES', 'PLANNED', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'S_OUT_ITEM', 'SALES', 'PHYSICAL', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'S_OTHER_OUT_ITEM', 'SALES', 'PHYSICAL', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'S_WITHDRAW_ITEM', 'SALES', 'PHYSICAL', 'QTY_X_URATE', 'ALL_ZERO_WITH_QTY_ANOMALY'),
    (1, 'E_ASK_ITEM', 'SUBCONTRACT', 'EMPTY', 'NO_BUSINESS_QTY', 'EMPTY_NO_QTY_WEIGHT'),
    (1, 'E_APPLICATION_ITEM', 'SUBCONTRACT', 'EMPTY', 'QTY_X_URATE', 'EMPTY'),
    (1, 'E_ORDER_ITEM', 'SUBCONTRACT', 'PLANNED', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'E_IN_ITEM', 'SUBCONTRACT', 'PHYSICAL', 'QTY_X_URATE', 'OPTIONAL_MATERIAL'),
    (1, 'E_SOUT_ITEM', 'SUBCONTRACT', 'PHYSICAL', 'POSITIVE_STQTY_ELSE_QTY_REJECT_DIFFERENCE', 'OPTIONAL_MATERIAL'),
    (1, 'E_WITHDRAW_ITEM', 'SUBCONTRACT', 'PHYSICAL', 'QTY_X_URATE', 'OPTIONAL_SPARSE'),
    (1, 'E_SWITHDRAW_ITEM', 'SUBCONTRACT', 'PHYSICAL', 'QTY_X_URATE', 'ALL_ZERO'),
    (1, 'E_SWASTE_ITEM', 'SUBCONTRACT', 'PHYSICAL', 'MANUAL_REVIEW_ONLY', 'MANUAL_REVIEW_ONLY'),
    (1, 'E_ORDER_COST_ITEM', 'SUBCONTRACT', 'BOM_REQUIREMENT', 'QTY_REQUIREMENT', 'NO_WEIGHT'),
    (1, 'F_PLAN_ITEM', 'PRODUCTION', 'PLANNED', 'QTY_X_URATE', 'PLAN_INBOUND_WEIGHT_ONLY_OBSERVED'),
    (1, 'F_DATE_REPORT_ITEM', 'PRODUCTION', 'EMPTY', 'QTY_X_URATE', 'EMPTY'),
    (1, 'F_PLAN_COST_ITEM', 'PRODUCTION', 'BOM_REQUIREMENT', 'QTY_REQUIREMENT', 'NO_WEIGHT'),
    (1, 'B_GOODS', NULL, 'MASTER_REFERENCE', 'BASIC_UNIT_ONLY', 'MASTER_WEIGHT_NOT_USABLE_FOR_INFERENCE');

CREATE TABLE legacy_measurement_profile_snapshots (
    id                                  UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),
    migration_run_id                    UUID NOT NULL
        REFERENCES legacy_migration_runs(run_id) ON DELETE RESTRICT,
    goods_id                            UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    operation_family                    VARCHAR(20) NOT NULL,
    registry_version                    INTEGER NOT NULL,
    export_manifest_sha256              VARCHAR(64) NOT NULL,
    source_backup_sha256                VARCHAR(64) NOT NULL,
    repository_commit                   VARCHAR(64) NOT NULL,
    approval_reference                  VARCHAR(200) NOT NULL,
    quantity_only_count                 BIGINT NOT NULL,
    quantity_and_weight_count           BIGINT NOT NULL,
    weight_without_quantity_count       BIGINT NOT NULL,
    invalid_measurement_count           BIGINT NOT NULL,
    source_capability_drift_count       BIGINT NOT NULL,
    distinct_document_count             BIGINT NOT NULL,
    positive_weight_document_count      BIGINT NOT NULL,
    positive_weight_day_count           BIGINT NOT NULL,
    recommended_preference              VARCHAR(50),
    recommendation_status               VARCHAR(20) NOT NULL,
    confidence                          NUMERIC(5,4) NOT NULL,
    evidence_fingerprint                VARCHAR(64) NOT NULL,
    created_at                          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT legacy_measurement_snapshot_family_chk CHECK (
        operation_family IN (
            'PROCUREMENT', 'WAREHOUSE', 'SALES', 'SUBCONTRACT', 'PRODUCTION'
        )
    ),
    CONSTRAINT legacy_measurement_snapshot_registry_version_chk CHECK (
        registry_version = 1
    ),
    CONSTRAINT legacy_measurement_snapshot_counts_chk CHECK (
        quantity_only_count >= 0
        AND quantity_and_weight_count >= 0
        AND weight_without_quantity_count >= 0
        AND invalid_measurement_count >= 0
        AND source_capability_drift_count >= 0
        AND distinct_document_count >= 0
        AND positive_weight_document_count >= 0
        AND positive_weight_day_count >= 0
    ),
    CONSTRAINT legacy_measurement_snapshot_recommendation_chk CHECK (
        recommended_preference IS NULL
        OR recommended_preference =
            'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
    ),
    CONSTRAINT legacy_measurement_snapshot_status_chk CHECK (
        recommendation_status IN (
            'NO_SIGNAL', 'PROVISIONAL', 'PATTERN_CONFIRMED', 'REVIEW'
        )
    ),
    CONSTRAINT legacy_measurement_snapshot_confidence_chk CHECK (
        confidence BETWEEN 0 AND 1
    ),
    CONSTRAINT legacy_measurement_snapshot_hash_chk CHECK (
        export_manifest_sha256 ~ '^[0-9a-f]{64}$'
        AND source_backup_sha256 ~ '^[0-9a-f]{64}$'
        AND repository_commit ~ '^[0-9a-f]{40,64}$'
        AND evidence_fingerprint ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT legacy_measurement_snapshot_uk
        UNIQUE (goods_id, operation_family, evidence_fingerprint)
);

CREATE TABLE legacy_measurement_exceptions (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    migration_run_id            UUID NOT NULL
        REFERENCES legacy_migration_runs(run_id) ON DELETE RESTRICT,
    operation_family            VARCHAR(20) NOT NULL,
    source_type                 VARCHAR(80) NOT NULL,
    source_record_key           VARCHAR(300) NOT NULL,
    goods_id                    UUID
        REFERENCES goods(id) ON DELETE RESTRICT,
    warehouse_id                UUID
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    color_id                    UUID
        REFERENCES colors(id) ON DELETE RESTRICT,
    issue_code                  VARCHAR(60) NOT NULL,
    business_qty                NUMERIC(33,4),
    actual_weight               NUMERIC(33,4),
    actual_weight_unit_id       UUID
        REFERENCES units(id) ON DELETE RESTRICT,
    details                     JSONB NOT NULL DEFAULT '{}'::JSONB,
    evidence_fingerprint        VARCHAR(64) NOT NULL,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at                 TIMESTAMPTZ,
    resolved_by                 UUID
        REFERENCES users(id) ON DELETE RESTRICT,
    resolution_note             VARCHAR(500),
    CONSTRAINT legacy_measurement_exception_family_chk CHECK (
        operation_family IN (
            'PROCUREMENT', 'WAREHOUSE', 'SALES', 'SUBCONTRACT', 'PRODUCTION'
        )
    ),
    CONSTRAINT legacy_measurement_exception_issue_chk CHECK (
        issue_code IN (
            'WEIGHT_WITHOUT_QUANTITY',
            'NEGATIVE_QUANTITY',
            'NEGATIVE_WEIGHT',
            'QUANTITY_WEIGHT_SIGN_CONFLICT',
            'MISSING_BUSINESS_UNIT',
            'INVALID_UNIT_RATE',
            'ALTERNATE_QUANTITY_CONFLICT',
            'LEGACY_WEIGHT_UNIT_UNKNOWN',
            'FACT_NULL_FALLBACK',
            'SOURCE_CAPABILITY_DRIFT'
        )
    ),
    CONSTRAINT legacy_measurement_exception_hash_chk CHECK (
        evidence_fingerprint ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT legacy_measurement_exception_resolution_chk CHECK (
        (resolved_at IS NULL AND resolved_by IS NULL AND resolution_note IS NULL)
        OR
        (
            resolved_at IS NOT NULL
            AND resolved_by IS NOT NULL
            AND resolution_note = btrim(resolution_note)
            AND length(resolution_note) BETWEEN 2 AND 500
        )
    ),
    CONSTRAINT legacy_measurement_exception_uk
        UNIQUE (
            migration_run_id, source_type, source_record_key,
            issue_code, evidence_fingerprint
        )
);

CREATE INDEX idx_legacy_measurement_exceptions_open
    ON legacy_measurement_exceptions(
        operation_family, issue_code, created_at
    )
    WHERE resolved_at IS NULL;

-- Transitional nullable columns. Existing source paths still carry generic
-- unitless weight and therefore do not become learning evidence. Enforcement
-- is deliberately deferred until every caller submits an explicit unit UUID.
ALTER TABLE stock_movements
    ADD COLUMN actual_weight_unit_id UUID;
ALTER TABLE stock_movements
    ADD CONSTRAINT stock_movements_actual_weight_unit_fk
        FOREIGN KEY (actual_weight_unit_id)
        REFERENCES units(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE stock_movements
    VALIDATE CONSTRAINT stock_movements_actual_weight_unit_fk;

ALTER TABLE procurement_inspection_items
    ADD COLUMN received_weight_unit_id UUID;
ALTER TABLE procurement_inspection_items
    ADD CONSTRAINT procurement_inspection_received_weight_unit_fk
        FOREIGN KEY (received_weight_unit_id)
        REFERENCES units(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE procurement_inspection_items
    VALIDATE CONSTRAINT procurement_inspection_received_weight_unit_fk;

CREATE OR REPLACE FUNCTION fn_reject_measurement_append_only_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = TG_TABLE_NAME || ' is append-only',
        DETAIL =
            'Measurement learning evidence cannot be updated or deleted.',
        HINT =
            'Append a reversal or decision event; never rewrite history.',
        CONSTRAINT = TG_TABLE_NAME || '_append_only_guard';
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_set_updated_at_unit_measurement_profiles
    BEFORE UPDATE ON unit_measurement_profiles
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_measurement_capture_profiles
    BEFORE UPDATE ON measurement_capture_profiles
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_measurement_capture_line_snapshots
    BEFORE UPDATE ON measurement_capture_line_snapshots
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_00_reject_measurement_capture_evidence_mutation
    BEFORE UPDATE OR DELETE ON measurement_capture_evidence
    FOR EACH ROW EXECUTE FUNCTION
        fn_reject_measurement_append_only_mutation();
CREATE TRIGGER trg_00_reject_measurement_capture_decision_mutation
    BEFORE UPDATE OR DELETE ON measurement_capture_decision_events
    FOR EACH ROW EXECUTE FUNCTION
        fn_reject_measurement_append_only_mutation();
CREATE TRIGGER trg_00_reject_legacy_measurement_registry_mutation
    BEFORE UPDATE OR DELETE ON legacy_measurement_source_registry
    FOR EACH ROW EXECUTE FUNCTION
        fn_reject_measurement_append_only_mutation();
CREATE TRIGGER trg_00_reject_legacy_measurement_snapshot_mutation
    BEFORE UPDATE OR DELETE ON legacy_measurement_profile_snapshots
    FOR EACH ROW EXECUTE FUNCTION
        fn_reject_measurement_append_only_mutation();

ALTER TABLE measurement_capture_evidence
    ENABLE ALWAYS TRIGGER
        trg_00_reject_measurement_capture_evidence_mutation;
ALTER TABLE measurement_capture_decision_events
    ENABLE ALWAYS TRIGGER
        trg_00_reject_measurement_capture_decision_mutation;
ALTER TABLE legacy_measurement_source_registry
    ENABLE ALWAYS TRIGGER
        trg_00_reject_legacy_measurement_registry_mutation;
ALTER TABLE legacy_measurement_profile_snapshots
    ENABLE ALWAYS TRIGGER
        trg_00_reject_legacy_measurement_snapshot_mutation;

CREATE TRIGGER trg_audit_unit_measurement_profiles
    AFTER INSERT OR UPDATE OR DELETE ON unit_measurement_profiles
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_measurement_capture_profiles
    AFTER INSERT OR UPDATE OR DELETE ON measurement_capture_profiles
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_measurement_capture_line_snapshots
    AFTER INSERT OR UPDATE OR DELETE ON measurement_capture_line_snapshots
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_measurement_capture_evidence
    AFTER INSERT OR UPDATE OR DELETE ON measurement_capture_evidence
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_measurement_capture_decision_events
    AFTER INSERT OR UPDATE OR DELETE ON measurement_capture_decision_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_legacy_measurement_source_registry
    AFTER INSERT OR UPDATE OR DELETE ON legacy_measurement_source_registry
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_legacy_measurement_profile_snapshots
    AFTER INSERT OR UPDATE OR DELETE ON legacy_measurement_profile_snapshots
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_legacy_measurement_exceptions
    AFTER INSERT OR UPDATE OR DELETE ON legacy_measurement_exceptions
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE VIEW v_measurement_capture_profile_resolution AS
SELECT profile.id,
       profile.goods_id,
       profile.operation_family,
       CASE
           WHEN profile.manual_override_preference IS NOT NULL
               THEN 'MANUAL_OVERRIDE'
           ELSE profile.status
       END AS status,
       CASE
           WHEN profile.effective_preference =
                    'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
                AND profile.actual_weight_unit_id IS NOT NULL
               THEN 'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
           ELSE 'BUSINESS_QUANTITY'
       END AS primary_input,
       CASE
           WHEN profile.effective_preference =
                    'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
                AND profile.actual_weight_unit_id IS NOT NULL
               THEN 'VISIBLE'
           WHEN profile.status = 'CONFIRMED'
                AND profile.effective_preference = 'BUSINESS_QUANTITY'
               THEN 'HIDDEN'
           ELSE 'OFFERED'
       END AS secondary_policy,
       COALESCE(profile.business_unit_id, goods.unit_id)
           AS business_unit_id,
       profile.actual_weight_unit_id,
       profile.confidence,
       profile.active_evidence_count,
       profile.evidence_fingerprint,
       profile.version,
       profile.last_evidence_at
FROM measurement_capture_profiles profile
JOIN goods ON goods.id = profile.goods_id;

COMMENT ON TABLE measurement_capture_profiles IS
    '货品×业务场景的未来采集偏好投影；不改变 qty/unit/rate、价格或历史业务事实';
COMMENT ON TABLE measurement_capture_line_snapshots IS
    '跨业务明细的显式计量快照；实际重量有值时必须同时保存重量单位 UUID';
COMMENT ON TABLE measurement_capture_evidence IS
    '已审核/已过账计量观察的 append-only 证据；草稿输入不得进入自动学习';
COMMENT ON TABLE measurement_capture_decision_events IS
    '人工覆盖和撤销覆盖的 append-only 决定；expectedVersion 防止并发静默覆盖';
COMMENT ON TABLE legacy_measurement_source_registry IS
    '旧库表级计量能力注册表；0 重量表示未采集/未知，不按单位名称或 goods.m_weight 推断';
COMMENT ON TABLE legacy_measurement_profile_snapshots IS
    '仅允许 formatVersion 3 manifest 绑定导出生成的聚合画像；本地未绑定 CSV 不得写入';
COMMENT ON TABLE legacy_measurement_exceptions IS
    '旧库无法安全自动归一的少量计量异常；业务事实不猜测、不静默丢弃';
COMMENT ON COLUMN stock_movements.actual_weight_unit_id IS
    '本次流水实际总重量的显式单位 UUID；过渡期历史/旧调用可能为空且不得成为自动学习证据';
COMMENT ON COLUMN procurement_inspection_items.received_weight_unit_id IS
    'IQC 收货实际总重量的显式单位 UUID；过渡期历史/旧调用可能为空且不得成为自动学习证据';
