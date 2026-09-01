-- Build measurement-capture suggestions only after every physical legacy
-- document module has been imported. This script consumes target UUID rows,
-- never unit names or goods.m_weight.
--
-- Important: generic legacy Weight has no unit. It may create a PROVISIONAL
-- UI suggestion, but never a CONFIRMED/ENFORCED measurement profile.

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.measurement_capture_profiles') IS NULL
       OR to_regclass('public.legacy_measurement_profile_snapshots') IS NULL
       OR to_regclass('public.legacy_measurement_exceptions') IS NULL THEN
        RAISE EXCEPTION
            'measurement learning schema is missing; apply V442 before legacy inference';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM legacy_migration_runs
        WHERE status = 'RUNNING'
          AND migration_mode = 'BOOTSTRAP'
          AND export_manifest_sha256 IS NOT NULL
          AND source_backup_sha256 IS NOT NULL
          AND export_approval_reference IS NOT NULL
          AND migration_repository_commit IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'measurement inference requires one active manifest-bound bootstrap run';
    END IF;
END
$$;

CREATE TEMP TABLE measurement_physical_stage (
    source_code          VARCHAR(50) NOT NULL,
    operation_family     VARCHAR(20) NOT NULL,
    source_document_id   UUID NOT NULL,
    source_item_id       UUID NOT NULL,
    goods_id             UUID NOT NULL,
    business_date        DATE NOT NULL,
    business_qty         NUMERIC(33,4),
    business_unit_id     UUID,
    unit_rate            NUMERIC(18,6),
    actual_weight        NUMERIC(33,4)
) ON COMMIT DROP;

INSERT INTO measurement_physical_stage
SELECT 'P_IN_ITEM', 'PROCUREMENT', receipt.id, item.id, item.goods_id,
       receipt.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM purchase_receipt_items item
JOIN purchase_receipts receipt ON receipt.id = item.receipt_id
WHERE receipt.status = 1
  AND NOT receipt.is_deleted
  AND NOT item.is_deleted
UNION ALL
SELECT 'P_WITHDRAW_ITEM', 'PROCUREMENT', ret.id, item.id, item.goods_id,
       ret.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM purchase_return_items item
JOIN purchase_returns ret ON ret.id = item.return_id
WHERE ret.status = 1
  AND NOT ret.is_deleted
  AND NOT item.is_deleted
UNION ALL
SELECT CASE document.doc_type
           WHEN 'TRANSFER' THEN 'O_TRANSFER_ITEM'
           WHEN 'OTHER_IN' THEN 'O_OTHER_IN_ITEM'
           WHEN 'OTHER_OUT' THEN 'O_OTHER_OUT_ITEM'
           WHEN 'DRAW' THEN 'O_PDRAW_ITEM'
           WHEN 'WDRAW' THEN 'O_WDRAW_ITEM'
           WHEN 'FINISHED_IN' THEN 'O_IN_ITEM'
           WHEN 'FINISHED_OUT' THEN 'O_OUT_ITEM'
       END,
       'WAREHOUSE', document.id, item.id, item.goods_id,
       document.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM stock_document_items item
JOIN stock_documents document ON document.id = item.doc_id
WHERE document.status = 1
  AND document.doc_type IN (
      'TRANSFER', 'OTHER_IN', 'OTHER_OUT', 'DRAW', 'WDRAW',
      'FINISHED_IN', 'FINISHED_OUT'
  )
  AND NOT document.is_deleted
  AND NOT item.is_deleted
UNION ALL
SELECT 'S_OUT_ITEM', 'SALES', shipment.id, item.id, item.goods_id,
       shipment.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM sales_shipment_items item
JOIN sales_shipments shipment ON shipment.id = item.shipment_id
WHERE shipment.status = 1
  AND NOT shipment.is_deleted
  AND NOT item.is_deleted
UNION ALL
SELECT 'S_OTHER_OUT_ITEM', 'SALES', shipment.id, item.id, item.goods_id,
       shipment.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM sales_other_shipment_items item
JOIN sales_other_shipments shipment ON shipment.id = item.shipment_id
WHERE shipment.status = 1
  AND NOT shipment.is_deleted
  AND NOT item.is_deleted
UNION ALL
SELECT 'S_WITHDRAW_ITEM', 'SALES', ret.id, item.id, item.goods_id,
       ret.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM sales_return_items item
JOIN sales_returns ret ON ret.id = item.return_id
WHERE ret.status = 1
  AND NOT ret.is_deleted
  AND NOT item.is_deleted;

INSERT INTO measurement_physical_stage
SELECT 'E_IN_ITEM', 'SUBCONTRACT', receipt.id, item.id, item.goods_id,
       receipt.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM subcontract_receipt_items item
JOIN subcontract_receipts receipt ON receipt.id = item.receipt_id
WHERE receipt.status = 1
  AND NOT receipt.is_deleted
  AND NOT item.is_deleted
UNION ALL
SELECT 'E_SOUT_ITEM', 'SUBCONTRACT', issue.id, item.id, item.goods_id,
       issue.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM subcontract_material_issue_items item
JOIN subcontract_material_issues issue ON issue.id = item.issue_id
WHERE issue.status = 1
  AND NOT issue.is_deleted
  AND NOT item.is_deleted
UNION ALL
SELECT 'E_WITHDRAW_ITEM', 'SUBCONTRACT', ret.id, item.id, item.goods_id,
       ret.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM subcontract_return_items item
JOIN subcontract_returns ret ON ret.id = item.return_id
WHERE ret.status = 1
  AND NOT ret.is_deleted
  AND NOT item.is_deleted
UNION ALL
SELECT 'E_SWITHDRAW_ITEM', 'SUBCONTRACT', ret.id, item.id, item.goods_id,
       ret.bill_date, item.qty, item.unit_id, item.unit_rate, item.weight
FROM subcontract_material_return_items item
JOIN subcontract_material_returns ret
  ON ret.id = item.material_return_id
WHERE ret.status = 1
  AND NOT ret.is_deleted
  AND NOT item.is_deleted;

-- Deterministic unit fallback for inference only: a missing transaction unit
-- may use the goods UUID unit when the stored rate is exactly 1. Explicit
-- transaction units always win. The source business rows are not rewritten.
UPDATE measurement_physical_stage stage
SET business_unit_id = goods.unit_id
FROM goods
WHERE goods.id = stage.goods_id
  AND stage.business_unit_id IS NULL
  AND COALESCE(stage.unit_rate, 1) = 1
  AND goods.unit_id IS NOT NULL;

CREATE TEMP TABLE measurement_bound_run ON COMMIT DROP AS
SELECT run_id,
       export_manifest_sha256::text AS export_manifest_sha256,
       source_backup_sha256,
       migration_repository_commit,
       export_approval_reference
FROM legacy_migration_runs
WHERE status = 'RUNNING'
  AND migration_mode = 'BOOTSTRAP'
  AND export_manifest_sha256 IS NOT NULL
  AND source_backup_sha256 IS NOT NULL
  AND export_approval_reference IS NOT NULL
  AND migration_repository_commit IS NOT NULL
ORDER BY started_at DESC, run_id
LIMIT 1;

-- A positive generic legacy Weight proves that a number was captured, but no
-- source supplies its unit. Invalid quantity/unit/rate shapes are quarantined
-- and excluded from profile inference.
INSERT INTO legacy_measurement_exceptions(
    migration_run_id,
    operation_family,
    source_type,
    source_record_key,
    goods_id,
    issue_code,
    business_qty,
    actual_weight,
    details,
    evidence_fingerprint
)
SELECT run.run_id,
       stage.operation_family,
       stage.source_code,
       stage.source_item_id::text,
       stage.goods_id,
       issue.issue_code,
       stage.business_qty,
       stage.actual_weight,
       jsonb_build_object(
           'sourceDocumentId', stage.source_document_id,
           'businessDate', stage.business_date,
           'weightUnitEvidence', 'UNKNOWN'
       ),
       encode(
           digest(
               concat_ws(
                   '|',
                   stage.source_code,
                   stage.source_document_id::text,
                   stage.source_item_id::text,
                   stage.goods_id::text,
                   stage.business_qty::text,
                   stage.business_unit_id::text,
                   stage.unit_rate::text,
                   stage.actual_weight::text,
                   issue.issue_code
               ),
               'sha256'
           ),
           'hex'
       )
FROM measurement_physical_stage stage
CROSS JOIN measurement_bound_run run
JOIN legacy_measurement_source_registry registry
  ON registry.registry_version = 1
 AND registry.source_code = stage.source_code
CROSS JOIN LATERAL (
    VALUES
        (
            'WEIGHT_WITHOUT_QUANTITY'::varchar,
            COALESCE(stage.actual_weight, 0) > 0
            AND COALESCE(stage.business_qty, 0) <= 0
        ),
        (
            'NEGATIVE_QUANTITY'::varchar,
            COALESCE(stage.business_qty, 0) < 0
        ),
        (
            'NEGATIVE_WEIGHT'::varchar,
            COALESCE(stage.actual_weight, 0) < 0
        ),
        (
            'MISSING_BUSINESS_UNIT'::varchar,
            COALESCE(stage.business_qty, 0) > 0
            AND stage.business_unit_id IS NULL
        ),
        (
            'INVALID_UNIT_RATE'::varchar,
            COALESCE(stage.business_qty, 0) > 0
            AND COALESCE(stage.unit_rate, 0) <= 0
        ),
        (
            'SOURCE_CAPABILITY_DRIFT'::varchar,
            COALESCE(stage.actual_weight, 0) > 0
            AND registry.weight_mode LIKE 'ALL_ZERO%'
        )
) issue(issue_code, applies)
WHERE issue.applies
ON CONFLICT ON CONSTRAINT legacy_measurement_exception_uk DO NOTHING;

CREATE TEMP TABLE measurement_classified_stage ON COMMIT DROP AS
SELECT stage.*,
       registry.weight_mode,
       (
           COALESCE(stage.business_qty, 0) > 0
           AND stage.business_unit_id IS NOT NULL
           AND COALESCE(stage.unit_rate, 0) > 0
           AND COALESCE(stage.actual_weight, 0) >= 0
           AND NOT (
               COALESCE(stage.actual_weight, 0) > 0
               AND registry.weight_mode LIKE 'ALL_ZERO%'
           )
       ) AS valid_measurement,
       (
           COALESCE(stage.actual_weight, 0) <> 0
           AND (
               COALESCE(stage.business_qty, 0) <= 0
               OR COALESCE(stage.actual_weight, 0) < 0
               OR registry.weight_mode LIKE 'ALL_ZERO%'
           )
       ) AS blocking_weight_issue,
       (
           COALESCE(stage.actual_weight, 0) > 0
           AND registry.weight_mode LIKE 'ALL_ZERO%'
       ) AS source_capability_drift
FROM measurement_physical_stage stage
JOIN legacy_measurement_source_registry registry
  ON registry.registry_version = 1
 AND registry.source_code = stage.source_code
 AND registry.evidence_role = 'PHYSICAL';

CREATE TEMP TABLE measurement_profile_aggregate ON COMMIT DROP AS
SELECT goods_id,
       operation_family,
       COUNT(*) FILTER (
           WHERE valid_measurement
             AND COALESCE(actual_weight, 0) = 0
       ) AS quantity_only_count,
       COUNT(*) FILTER (
           WHERE valid_measurement
             AND COALESCE(actual_weight, 0) > 0
       ) AS quantity_and_weight_count,
       COUNT(*) FILTER (
           WHERE COALESCE(actual_weight, 0) > 0
             AND COALESCE(business_qty, 0) <= 0
       ) AS weight_without_quantity_count,
       COUNT(*) FILTER (WHERE NOT valid_measurement)
           AS invalid_measurement_count,
       COUNT(*) FILTER (WHERE source_capability_drift)
           AS source_capability_drift_count,
       COUNT(*) FILTER (WHERE blocking_weight_issue)
           AS blocking_weight_issue_count,
       COUNT(DISTINCT source_document_id) FILTER (
           WHERE valid_measurement
       ) AS distinct_document_count,
       COUNT(DISTINCT source_document_id) FILTER (
           WHERE valid_measurement
             AND COALESCE(actual_weight, 0) = 0
       ) AS quantity_document_count,
       COUNT(DISTINCT business_date) FILTER (
           WHERE valid_measurement
             AND COALESCE(actual_weight, 0) = 0
       ) AS quantity_day_count,
       COUNT(DISTINCT source_document_id) FILTER (
           WHERE valid_measurement
             AND COALESCE(actual_weight, 0) > 0
       ) AS positive_weight_document_count,
       COUNT(DISTINCT business_date) FILTER (
           WHERE valid_measurement
             AND COALESCE(actual_weight, 0) > 0
       ) AS positive_weight_day_count,
       CASE
           WHEN COUNT(DISTINCT business_unit_id) FILTER (
                    WHERE valid_measurement
                ) = 1
               THEN (
                   ARRAY_AGG(DISTINCT business_unit_id) FILTER (
                       WHERE valid_measurement
                   )
               )[1]
           ELSE NULL
       END AS business_unit_id,
       MAX(business_date) FILTER (WHERE valid_measurement)
           AS last_evidence_date
FROM measurement_classified_stage
GROUP BY goods_id, operation_family;

CREATE TEMP TABLE measurement_profile_candidates ON COMMIT DROP AS
SELECT aggregate.*,
       run.run_id,
       run.export_manifest_sha256,
       run.source_backup_sha256,
       run.migration_repository_commit,
       run.export_approval_reference,
       CASE
           WHEN aggregate.blocking_weight_issue_count > 0
               THEN NULL
           WHEN aggregate.positive_weight_document_count > 0
               THEN 'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
           ELSE NULL
       END AS recommended_preference,
       CASE
           WHEN aggregate.blocking_weight_issue_count > 0
               THEN 'REVIEW'
           WHEN aggregate.positive_weight_document_count >= 3
                AND aggregate.positive_weight_day_count >= 2
               THEN 'PATTERN_CONFIRMED'
           WHEN aggregate.positive_weight_document_count > 0
               THEN 'PROVISIONAL'
           ELSE 'NO_SIGNAL'
       END AS recommendation_status,
       CASE
           WHEN aggregate.blocking_weight_issue_count > 0 THEN 0.0000
           WHEN aggregate.positive_weight_document_count >= 3
                AND aggregate.positive_weight_day_count >= 2
               THEN 0.7500
           WHEN aggregate.positive_weight_document_count > 0 THEN 0.5000
           ELSE 0.0000
       END AS confidence,
       encode(
           digest(
               concat_ws(
                   '|',
                   run.export_manifest_sha256,
                   aggregate.goods_id::text,
                   aggregate.operation_family,
                   aggregate.quantity_only_count::text,
                   aggregate.quantity_and_weight_count::text,
                   aggregate.weight_without_quantity_count::text,
                   aggregate.invalid_measurement_count::text,
                   aggregate.source_capability_drift_count::text,
                   aggregate.distinct_document_count::text,
                   aggregate.positive_weight_document_count::text,
                   aggregate.positive_weight_day_count::text
               ),
               'sha256'
           ),
           'hex'
       ) AS evidence_fingerprint
FROM measurement_profile_aggregate aggregate
CROSS JOIN measurement_bound_run run;

INSERT INTO legacy_measurement_profile_snapshots(
    migration_run_id,
    goods_id,
    operation_family,
    registry_version,
    export_manifest_sha256,
    source_backup_sha256,
    repository_commit,
    approval_reference,
    quantity_only_count,
    quantity_and_weight_count,
    weight_without_quantity_count,
    invalid_measurement_count,
    source_capability_drift_count,
    distinct_document_count,
    positive_weight_document_count,
    positive_weight_day_count,
    recommended_preference,
    recommendation_status,
    confidence,
    evidence_fingerprint
)
SELECT run_id,
       goods_id,
       operation_family,
       1,
       export_manifest_sha256,
       source_backup_sha256,
       migration_repository_commit,
       export_approval_reference,
       quantity_only_count,
       quantity_and_weight_count,
       weight_without_quantity_count,
       invalid_measurement_count,
       source_capability_drift_count,
       distinct_document_count,
       positive_weight_document_count,
       positive_weight_day_count,
       recommended_preference,
       recommendation_status,
       confidence,
       evidence_fingerprint
FROM measurement_profile_candidates
ON CONFLICT ON CONSTRAINT legacy_measurement_snapshot_uk DO NOTHING;

-- Zero/absent legacy Weight never confirms BUSINESS_QUANTITY. The current
-- quantity form remains the safe default, so only positive weight patterns
-- need a profile row. Because legacy weight unit is unknown, even a strong
-- 3-document/2-day pattern remains PROVISIONAL until a future user supplies
-- an explicit actual-weight unit UUID.
INSERT INTO measurement_capture_profiles(
    goods_id,
    operation_family,
    status,
    inferred_preference,
    effective_preference,
    business_unit_id,
    actual_weight_unit_id,
    confidence,
    active_evidence_count,
    quantity_document_count,
    quantity_day_count,
    quantity_and_weight_document_count,
    quantity_and_weight_day_count,
    inference_conflict,
    evidence_fingerprint,
    source_registry_version,
    version,
    last_evidence_at
)
SELECT goods_id,
       operation_family,
       'PROVISIONAL',
       recommended_preference,
       recommended_preference,
       business_unit_id,
       NULL,
       confidence,
       quantity_only_count + quantity_and_weight_count,
       quantity_document_count,
       quantity_day_count,
       positive_weight_document_count,
       positive_weight_day_count,
       FALSE,
       evidence_fingerprint,
       1,
       0,
       last_evidence_date::timestamptz
FROM measurement_profile_candidates
WHERE recommended_preference =
    'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT'
ON CONFLICT (goods_id, operation_family) DO UPDATE
SET inferred_preference =
        EXCLUDED.inferred_preference,
    effective_preference =
        COALESCE(
            measurement_capture_profiles.manual_override_preference,
            EXCLUDED.inferred_preference
        ),
    business_unit_id =
        COALESCE(
            measurement_capture_profiles.business_unit_id,
            EXCLUDED.business_unit_id
        ),
    confidence = EXCLUDED.confidence,
    active_evidence_count = EXCLUDED.active_evidence_count,
    quantity_document_count = EXCLUDED.quantity_document_count,
    quantity_day_count = EXCLUDED.quantity_day_count,
    quantity_and_weight_document_count =
        EXCLUDED.quantity_and_weight_document_count,
    quantity_and_weight_day_count =
        EXCLUDED.quantity_and_weight_day_count,
    inference_conflict =
        measurement_capture_profiles.manual_override_preference IS NOT NULL
        AND measurement_capture_profiles.manual_override_preference
            IS DISTINCT FROM EXCLUDED.inferred_preference,
    status = CASE
        WHEN measurement_capture_profiles.manual_override_preference
                 IS NOT NULL
             AND measurement_capture_profiles.manual_override_preference
                 IS DISTINCT FROM EXCLUDED.inferred_preference
            THEN 'CONFLICT'
        WHEN measurement_capture_profiles.manual_override_preference
                 IS NOT NULL
            THEN measurement_capture_profiles.status
        ELSE 'PROVISIONAL'
    END,
    evidence_fingerprint = EXCLUDED.evidence_fingerprint,
    source_registry_version = 1,
    version = measurement_capture_profiles.version + 1,
    last_evidence_at = EXCLUDED.last_evidence_at,
    updated_at = now()
WHERE measurement_capture_profiles.evidence_fingerprint
      IS DISTINCT FROM EXCLUDED.evidence_fingerprint;

COMMIT;
