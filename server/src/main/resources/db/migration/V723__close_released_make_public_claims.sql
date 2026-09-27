-- Cancelling an analysis first releases its exact unused physical entitlement.
-- Closing the corresponding promise afterwards must remain final if the source
-- receipt is later reversed. A numeric released_qty alone is not proof: formal
-- production use and transfers also release the original reservation.
CREATE FUNCTION fn_preplan_make_public_claim_releasable_received_qty(p_claim UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(exact.qty),0)
    FROM preplan_make_public_claims claim
    JOIN preplan_analysis_stock_exact_pegs exact ON exact.make_public_claim_id=claim.id
    JOIN stock_documents document ON document.id=exact.source_stock_document_id
      AND document.status=1 AND NOT document.is_deleted
    JOIN stock_document_items item ON item.id=exact.source_stock_document_item_id AND NOT item.is_deleted
    JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id
      AND NOT reservation.is_deleted AND reservation.consumed_qty=0
      AND reservation.qty=exact.qty AND reservation.released_qty=exact.qty
      AND reservation.status=1
    WHERE claim.id=p_claim
      AND NOT EXISTS(SELECT 1 FROM v_preplan_stock_entitlement_beneficiary_balance balance
          WHERE balance.stock_reservation_id=reservation.id AND balance.effective_qty>0)
      AND COALESCE((SELECT sum(release.qty)
          FROM preplan_stock_entitlement_events release
          WHERE release.stock_reservation_id=reservation.id AND release.event_type='RELEASE'
            AND release.beneficiary_analysis_id=claim.target_analysis_id
            AND release.event_group_id=claim.target_analysis_id
            AND release.idempotency_key LIKE 'PREPLAN-ANALYSIS-CANCEL:%'),0)>=exact.qty
$$;

DO $close_released_promise$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_make_public_claim()'::regprocedure) INTO definition;
    needle:='NEW.qty>fn_preplan_make_public_claim_pending_qty(claim.id)';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V723 manufacturing promise cancellation guard changed'; END IF;
    EXECUTE replace(definition,needle,'NEW.qty>LEAST(
        claim.qty-fn_preplan_make_public_claim_cancelled_qty(claim.id),
        fn_preplan_make_public_claim_pending_qty(claim.id)
          +fn_preplan_make_public_claim_releasable_received_qty(claim.id))');
END;
$close_released_promise$;
