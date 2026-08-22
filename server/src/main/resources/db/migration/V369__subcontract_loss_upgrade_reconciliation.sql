-- V369: forward reconcile the short V330-V368 source window. Normal application
-- startup completes all Flyway migrations before accepting writes; these guards
-- also fail closed if a nonstandard partial rollout admitted business rows.

UPDATE subcontract_loss_cases loss
SET suggested_claim_amount_local=loss.claim_amount_local,
    claim_amount_local=0,
    updated_at=now()
WHERE loss.decided_at IS NULL
  AND loss.claim_amount_local<>0
  AND NOT EXISTS (
      SELECT 1 FROM subcontract_loss_resolutions resolution
      WHERE resolution.case_id=loss.id);

ALTER TABLE subcontract_loss_cases
    DROP CONSTRAINT subcontract_loss_cases_qty_summary_shape_chk;
ALTER TABLE subcontract_loss_cases
    ADD CONSTRAINT subcontract_loss_cases_qty_summary_shape_chk CHECK (
        (quantity_summary_kind='SAME_UNIT'
            AND quantity_unit_id IS NOT NULL
            AND actual_loss_qty IS NOT NULL
            AND allowed_loss_qty IS NOT NULL
            AND excess_loss_qty IS NOT NULL
            AND actual_loss_qty=allowed_loss_qty+excess_loss_qty)
        OR (quantity_summary_kind='MIXED_UNITS'
            AND actual_loss_qty IS NULL
            AND allowed_loss_qty IS NULL
            AND excess_loss_qty IS NULL
            AND quantity_unit_id IS NULL));

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM subcontract_loss_cases loss
        JOIN subcontract_loss_case_lines line ON line.case_id=loss.id
        GROUP BY loss.id,loss.quantity_summary_kind,loss.quantity_unit_id
        HAVING (
            loss.quantity_summary_kind='SAME_UNIT'
            AND (COUNT(DISTINCT line.unit_id)<>1
                 OR COUNT(*) FILTER(WHERE line.unit_id IS NULL)<>0
                 OR MIN(line.unit_id::text)::UUID IS DISTINCT FROM loss.quantity_unit_id))
    ) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='existing subcontract loss header quantity summary mixes units';
    END IF;
END
$$;
