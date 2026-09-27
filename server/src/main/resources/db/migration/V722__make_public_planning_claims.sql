-- A manufacturing promise is not inventory. These append-only records reserve
-- only the public part of an existing plan; actual stock still uses the one
-- stock_reservations / exact-pegs / entitlement-events chain.
CREATE TABLE preplan_make_public_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_plan_item_id UUID NOT NULL REFERENCES production_plan_items(id),
    target_analysis_id UUID NOT NULL,
    target_material_id UUID NOT NULL,
    qty NUMERIC(18,4) NOT NULL CHECK(qty>0),
    idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 200),
    request_hash TEXT NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY(target_analysis_id,target_material_id)
      REFERENCES production_material_analysis_materials(analysis_id,id),
    UNIQUE(created_by,idempotency_key)
);
CREATE INDEX idx_make_public_claim_source ON preplan_make_public_claims(source_plan_item_id,created_at,id);
CREATE INDEX idx_make_public_claim_target ON preplan_make_public_claims(target_analysis_id,target_material_id);
CREATE TABLE preplan_make_public_claim_cancellations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id UUID NOT NULL REFERENCES preplan_make_public_claims(id),
    qty NUMERIC(18,4) NOT NULL CHECK(qty>0),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 1000),
    idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 200),
    request_hash TEXT NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(created_by,idempotency_key)
);
CREATE INDEX idx_make_public_claim_cancel ON preplan_make_public_claim_cancellations(claim_id);
DO $command_kind$
DECLARE expression TEXT;
BEGIN
    SELECT regexp_replace(pg_get_constraintdef(oid),'^CHECK ','') INTO expression FROM pg_constraint
      WHERE conrelid='production_material_analysis_commands'::regclass AND conname='production_material_analysis_command_operation_chk';
    ALTER TABLE production_material_analysis_commands DROP CONSTRAINT production_material_analysis_command_operation_chk;
    EXECUTE 'ALTER TABLE production_material_analysis_commands ADD CONSTRAINT production_material_analysis_command_operation_chk CHECK ('
      ||expression||' OR operation IN(''MAKE_PUBLIC_CLAIM'',''MAKE_PUBLIC_CANCEL''))';
END;
$command_kind$;
ALTER TABLE preplan_analysis_stock_exact_pegs
    ADD COLUMN make_public_claim_id UUID REFERENCES preplan_make_public_claims(id),
    DROP CONSTRAINT preplan_exact_peg_origin_anchor_chk,
    ADD CONSTRAINT preplan_exact_peg_origin_anchor_chk CHECK(
        num_nonnulls(supply_action_allocation_id,make_source_analysis_item_id,make_public_claim_id)=1),
    ADD CONSTRAINT preplan_exact_peg_public_make_shape_chk CHECK(make_public_claim_id IS NULL OR (
        source_receipt_type='MAKE' AND source_disposition_event_id IS NULL
        AND source_stock_document_id IS NOT NULL AND source_stock_document_item_id IS NOT NULL
        AND source_receipt_id=source_stock_document_id AND beneficiary_reason='ORIGIN_MAKE'));
CREATE INDEX idx_exact_make_public_claim ON preplan_analysis_stock_exact_pegs(make_public_claim_id)
    WHERE make_public_claim_id IS NOT NULL;
CREATE FUNCTION fn_guard_make_public_exact_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.make_public_claim_id IS DISTINCT FROM OLD.make_public_claim_id THEN
        RAISE EXCEPTION 'public manufacturing exact origin is immutable' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_make_public_exact_identity BEFORE UPDATE OF make_public_claim_id
    ON preplan_analysis_stock_exact_pegs FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_exact_identity();

CREATE FUNCTION fn_preplan_make_public_claim_cancelled_qty(p_claim UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(qty),0) FROM preplan_make_public_claim_cancellations WHERE claim_id=p_claim
$$;
CREATE FUNCTION fn_preplan_make_public_claim_received_qty(p_claim UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(exact.qty),0) FROM preplan_analysis_stock_exact_pegs exact
    JOIN stock_documents doc ON doc.id=exact.source_stock_document_id AND doc.status=1 AND NOT doc.is_deleted
    JOIN stock_document_items item ON item.id=exact.source_stock_document_item_id AND NOT item.is_deleted
    WHERE exact.make_public_claim_id=p_claim
$$;
CREATE FUNCTION fn_preplan_make_public_claim_pending_qty(p_claim UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT GREATEST(qty-fn_preplan_make_public_claim_cancelled_qty(id)
        -fn_preplan_make_public_claim_received_qty(id),0) FROM preplan_make_public_claims WHERE id=p_claim),0)
$$;

CREATE FUNCTION fn_preplan_make_public_produced_qty(p_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH budget AS (
      SELECT item.id,item.qty*COALESCE(item.unit_rate,1)
        -COALESCE(action.public_surplus_qty,link.public_surplus_qty*COALESCE(item.unit_rate,1)) private_qty
      FROM production_plan_items item JOIN production_material_analysis_plan_links link ON link.plan_id=item.plan_id
      LEFT JOIN preplan_aggregate_batches batch ON batch.plan_id=item.plan_id AND batch.route='MAKE'
      LEFT JOIN preplan_supply_actions action ON action.id=batch.action_id
      WHERE item.id=p_item
    )
    SELECT COALESCE((SELECT COALESCE(sum(report.qty*COALESCE(report.unit_rate,1))
        FILTER(WHERE fn_daily_report_is_public_output(report.id)),0)
      +GREATEST(COALESCE(sum(report.qty*COALESCE(report.unit_rate,1))
        FILTER(WHERE NOT fn_daily_report_is_public_output(report.id)),0)-budget.private_qty,0)
      FROM budget LEFT JOIN production_daily_report_items report ON report.plan_item_id=budget.id AND NOT report.is_deleted
        AND EXISTS(SELECT 1 FROM production_daily_reports header WHERE header.id=report.report_id AND header.status=1 AND NOT header.is_deleted)
      GROUP BY budget.id,budget.private_qty),0)
$$;

CREATE VIEW v_preplan_make_public_supply_state AS
WITH plan_source AS (
    SELECT item.id source_plan_item_id,plan.id source_plan_id,analysis.id source_analysis_id,
      analysis.warehouse_id,item.goods_id,item.color_id,goods.unit_id,plan.bill_no document_no,
      plan.status source_status,COALESCE(batch_action.public_surplus_qty,link.public_surplus_qty*COALESCE(item.unit_rate,1)) planned_public_qty,
      (plan.status IN(0,1) AND NOT plan.is_deleted AND NOT plan.is_canceled
        AND NOT plan.is_stopped AND NOT plan.is_closed) source_open,
      (plan.status IN(0,1) AND NOT plan.is_deleted AND NOT plan.is_canceled) source_valid,
      item.qty*COALESCE(item.unit_rate,1)-COALESCE(batch_action.public_surplus_qty,link.public_surplus_qty*COALESCE(item.unit_rate,1)) private_qty,
      COALESCE(item.plan_end_date,plan.delivery_date) expected_date
    FROM production_material_analysis_plan_links link
    JOIN production_plans plan ON plan.id=link.plan_id
    JOIN production_plan_items item ON item.plan_id=plan.id AND NOT item.is_deleted
    JOIN goods ON goods.id=item.goods_id
    JOIN production_material_analysis_items origin ON origin.id=plan.material_analysis_item_id
    JOIN production_material_analyses analysis ON analysis.id=link.analysis_id AND NOT analysis.is_deleted AND analysis.status<>'CANCELLED'
    LEFT JOIN preplan_aggregate_batches batch ON batch.plan_id=plan.id AND batch.route='MAKE'
    LEFT JOIN preplan_supply_actions batch_action ON batch_action.id=batch.action_id AND batch_action.status<>'CANCELLED'
    WHERE link.allocation_status IN('SUBMITTED','APPROVED')
      AND origin.source_type NOT IN('SUBCONTRACT_MAKE','SUBCONTRACT_PREPARATION')
      AND NOT EXISTS(SELECT 1 FROM preplan_aggregate_batches preparation
          WHERE preparation.plan_id=plan.id AND preparation.route='SUBCONTRACT')
      AND COALESCE(batch_action.public_surplus_qty,link.public_surplus_qty*COALESCE(item.unit_rate,1))>0
), received AS (
    SELECT source.source_plan_item_id,
      COALESCE(sum(item.base_qty) FILTER(WHERE fn_finished_in_is_public_output(item.id)),0)
      +GREATEST(COALESCE(sum(item.base_qty) FILTER(WHERE NOT fn_finished_in_is_public_output(item.id)),0)
        -source.private_qty,0) received_public_qty
    FROM plan_source source
    LEFT JOIN stock_document_items item ON item.upstream_item_id=source.source_plan_item_id
      AND item.bill_type='FINISHED_IN' AND NOT item.is_deleted
      AND EXISTS(SELECT 1 FROM stock_documents doc WHERE doc.id=item.doc_id AND doc.status=1 AND NOT doc.is_deleted)
    GROUP BY source.source_plan_item_id,source.private_qty
), claimed AS (
    SELECT source_plan_item_id,sum(qty-fn_preplan_make_public_claim_cancelled_qty(id)) claimed_qty,
      sum(fn_preplan_make_public_claim_pending_qty(id)) claim_open_qty
    FROM preplan_make_public_claims GROUP BY source_plan_item_id
)
SELECT source.source_plan_item_id,source.source_plan_id,source.source_analysis_id,source.warehouse_id,
    source.goods_id,source.color_id,source.unit_id,source.document_no,source.source_status,
    source.planned_public_qty,received.received_public_qty,
    COALESCE(claimed.claimed_qty,0)::numeric claimed_qty,COALESCE(claimed.claim_open_qty,0)::numeric claim_open_qty,
    CASE WHEN source.source_valid THEN LEAST(GREATEST(source.planned_public_qty-COALESCE(claimed.claimed_qty,0),0),
      GREATEST((CASE WHEN source.source_open THEN source.planned_public_qty
        ELSE LEAST(source.planned_public_qty,fn_preplan_make_public_produced_qty(source.source_plan_item_id)) END)
        -received.received_public_qty-COALESCE(claimed.claim_open_qty,0),0))
      ELSE 0 END::numeric available_to_claim_qty,
    source.expected_date
FROM plan_source source JOIN received USING(source_plan_item_id)
LEFT JOIN claimed USING(source_plan_item_id);

CREATE FUNCTION fn_preplan_make_public_target_is_source(p_plan_item UUID,p_target_material UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    WITH RECURSIVE equivalent(material_id) AS (
        SELECT p_target_material
        UNION
        SELECT CASE WHEN alias.source_material_id=equivalent.material_id
                    THEN alias.aggregate_material_id ELSE alias.source_material_id END
        FROM equivalent JOIN preplan_aggregate_material_aliases alias
          ON alias.source_material_id=equivalent.material_id OR alias.aggregate_material_id=equivalent.material_id
    )
    SELECT EXISTS(
        SELECT 1 FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id
        JOIN production_material_analysis_items source ON source.id=plan.material_analysis_item_id
        WHERE item.id=p_plan_item AND (
          source.root_material_id IN(SELECT material_id FROM equivalent)
          OR source.parent_analysis_material_id IN(SELECT material_id FROM equivalent)
          OR EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
              JOIN preplan_supply_action_allocations allocation ON allocation.action_id=batch.action_id
              WHERE batch.plan_id=plan.id AND allocation.analysis_material_id IN(SELECT material_id FROM equivalent))))
$$;

CREATE FUNCTION fn_guard_make_public_claim() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source v_preplan_make_public_supply_state%ROWTYPE;
        target production_material_analysis_materials%ROWTYPE; target_header production_material_analyses%ROWTYPE;
        claim preplan_make_public_claims%ROWTYPE; total NUMERIC;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'manufacturing public claims are append-only' USING ERRCODE='55000'; END IF;
    IF TG_TABLE_NAME='preplan_make_public_claim_cancellations' THEN
        SELECT * INTO claim FROM preplan_make_public_claims WHERE id=NEW.claim_id;
        PERFORM 1 FROM production_plan_items WHERE id=claim.source_plan_item_id FOR UPDATE;
        IF claim.id IS NULL OR NEW.qty>fn_preplan_make_public_claim_pending_qty(claim.id) THEN
            RAISE EXCEPTION 'only unreceived manufacturing claim quantity can be cancelled' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    PERFORM 1 FROM production_plan_items WHERE id=NEW.source_plan_item_id FOR UPDATE;
    SELECT * INTO source FROM v_preplan_make_public_supply_state WHERE source_plan_item_id=NEW.source_plan_item_id;
    SELECT * INTO target FROM production_material_analysis_materials WHERE id=NEW.target_material_id FOR UPDATE;
    SELECT * INTO target_header FROM production_material_analyses WHERE id=NEW.target_analysis_id;
    IF source.source_plan_item_id IS NULL OR fn_preplan_make_public_target_is_source(NEW.source_plan_item_id,NEW.target_material_id)
       OR target.analysis_id IS DISTINCT FROM NEW.target_analysis_id OR NOT target.active
       OR target.confirmed_route IS NULL OR target_header.is_deleted OR target_header.status='CANCELLED'
       OR NOT fn_warehouse_same_main(source.warehouse_id,target_header.warehouse_id)
       OR (source.goods_id,source.color_id,source.unit_id) IS DISTINCT FROM (target.goods_id,target.color_id,target.unit_id)
       OR NEW.qty>source.available_to_claim_qty
       OR NEW.qty+COALESCE((SELECT sum(c.qty-fn_preplan_make_public_claim_cancelled_qty(c.id))
            FROM preplan_make_public_claims c WHERE c.target_material_id=NEW.target_material_id),0)
            >fn_preplan_aggregate_source_capacity(NEW.target_material_id) THEN
        RAISE EXCEPTION 'manufacturing public claim source, owner or remaining quantity changed' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_make_public_claim BEFORE INSERT OR UPDATE OR DELETE ON preplan_make_public_claims
    FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_claim();
CREATE TRIGGER trg_guard_make_public_claim_cancellation BEFORE INSERT OR UPDATE OR DELETE ON preplan_make_public_claim_cancellations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_claim();

-- Ordering a parent later must inherit an existing child promise through the
-- same immutable BOM alias as existing purchase/manufacturing supply. Otherwise
-- the original child becomes display-zero and the canonical child orders again.
DO $alias_public_promise$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_preplan_aggregate_material_pending_qty(uuid,uuid[])'::regprocedure),chr(13),'') INTO definition;
    needle:='total:=total+COALESCE((SELECT sum(pending_qty) FROM fn_preplan_aggregate_direct_make_sources(p_material)),0);';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V722 aggregate pending contract changed'; END IF;
    EXECUTE replace(definition,needle,needle||'
    total:=total+COALESCE((SELECT sum(fn_preplan_make_public_claim_pending_qty(claim.id))
        FROM preplan_make_public_claims claim WHERE claim.target_material_id=p_material),0);');
    SELECT replace(pg_get_functiondef('fn_preplan_aggregate_alias_supply_sources(uuid)'::regprocedure),chr(13),'') INTO definition;
    needle:='UNION ALL SELECT ''PLAN_ITEM'',source_id,arranged_qty FROM fn_preplan_aggregate_direct_make_sources(alias.source_material_id)';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V722 aggregate related source contract changed'; END IF;
    EXECUTE replace(definition,needle,needle||'
            UNION ALL SELECT ''MAKE_PUBLIC_CLAIM'',claim.id,claim.qty-fn_preplan_make_public_claim_cancelled_qty(claim.id)
              FROM preplan_make_public_claims claim WHERE claim.target_material_id=alias.source_material_id
                AND claim.qty>fn_preplan_make_public_claim_cancelled_qty(claim.id)');
END;
$alias_public_promise$;

CREATE FUNCTION fn_check_make_public_exact_peg(p_exact UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE exact preplan_analysis_stock_exact_pegs%ROWTYPE; claim preplan_make_public_claims%ROWTYPE;
        reservation stock_reservations%ROWTYPE; item stock_document_items%ROWTYPE; doc stock_documents%ROWTYPE;
        source production_plan_items%ROWTYPE; target production_material_analysis_materials%ROWTYPE;
        source_total NUMERIC; claim_total NUMERIC; public_total NUMERIC; public_capacity NUMERIC;
        formally_transferred BOOLEAN:=FALSE;
BEGIN
    SELECT * INTO exact FROM preplan_analysis_stock_exact_pegs WHERE id=p_exact;
    SELECT * INTO claim FROM preplan_make_public_claims WHERE id=exact.make_public_claim_id FOR UPDATE;
    SELECT * INTO source FROM production_plan_items WHERE id=claim.source_plan_item_id FOR UPDATE;
    SELECT * INTO reservation FROM stock_reservations WHERE id=exact.stock_reservation_id;
    SELECT * INTO item FROM stock_document_items WHERE id=exact.source_stock_document_item_id;
    SELECT * INTO doc FROM stock_documents WHERE id=item.doc_id;
    SELECT * INTO target FROM production_material_analysis_materials WHERE id=claim.target_material_id;
    formally_transferred:=reservation.status IN(0,1) AND reservation.release_reason='TRANSFERRED_TO_PLAN'
      AND reservation.released_qty>0 AND reservation.released_qty<=exact.qty
      AND COALESCE((SELECT sum(formal.qty-COALESCE((SELECT sum(restored.qty)
          FROM preplan_stock_entitlement_events restored WHERE restored.counter_event_id=formal.id
            AND restored.event_type='RESTORE'),0)) FROM preplan_stock_entitlement_events formal
          WHERE formal.stock_reservation_id=reservation.id AND formal.event_type='FORMALIZE'),0)=reservation.released_qty;
    IF claim.id IS NULL OR reservation.id IS NULL OR source.id IS NULL OR target.id IS NULL
       OR exact.source_receipt_type<>'MAKE' OR exact.beneficiary_reason<>'ORIGIN_MAKE'
       OR (exact.origin_analysis_id,exact.origin_analysis_material_id) IS DISTINCT FROM (claim.target_analysis_id,claim.target_material_id)
       OR (exact.beneficiary_analysis_id,exact.beneficiary_analysis_material_id) IS DISTINCT FROM (claim.target_analysis_id,claim.target_material_id)
       OR item.upstream_item_id IS DISTINCT FROM source.id OR item.doc_id IS DISTINCT FROM exact.source_stock_document_id
       OR item.bill_type<>'FINISHED_IN' OR item.is_deleted OR doc.status<>1 OR doc.is_deleted
       OR (item.goods_id,item.color_id,item.unit_id) IS DISTINCT FROM (source.goods_id,source.color_id,source.unit_id)
       OR (target.goods_id,target.color_id,target.unit_id) IS DISTINCT FROM
          (source.goods_id,source.color_id,(SELECT unit_id FROM goods WHERE id=source.goods_id))
       OR reservation.owner_type<>'PREPLAN_ANALYSIS' OR reservation.purpose<>'PREPLAN_MATERIAL'
       OR reservation.owner_id IS DISTINCT FROM claim.target_analysis_id OR reservation.qty IS DISTINCT FROM exact.qty
       OR reservation.supply_type<>'PRODUCTION_PLAN_ITEM' OR reservation.supply_id IS DISTINCT FROM source.id
       OR reservation.source_doc_type<>'PRODUCTION_INBOUND' OR reservation.source_doc_id IS DISTINCT FROM doc.id
       OR reservation.warehouse_id IS DISTINCT FROM doc.warehouse_id
       OR (reservation.goods_id,reservation.color_id) IS DISTINCT FROM (source.goods_id,source.color_id)
       OR reservation.is_deleted OR reservation.consumed_qty<>0
       OR (reservation.status<>0 AND NOT COALESCE(formally_transferred,FALSE))
       OR (reservation.released_qty<>0 AND NOT COALESCE(formally_transferred,FALSE))
       OR NOT fn_preplan_reservation_has_qualified_origin(reservation.id)
       OR NOT fn_warehouse_same_main(doc.warehouse_id,(SELECT warehouse_id FROM production_material_analyses WHERE id=claim.target_analysis_id)) THEN
        RAISE EXCEPTION 'public manufacturing receipt must retain its exact claimed plan, owner and physical lot' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(sum(e.qty),0) INTO claim_total FROM preplan_analysis_stock_exact_pegs e
      JOIN stock_documents d ON d.id=e.source_stock_document_id AND d.status=1 AND NOT d.is_deleted
      WHERE e.make_public_claim_id=claim.id;
    IF claim_total>claim.qty-fn_preplan_make_public_claim_cancelled_qty(claim.id) THEN
        RAISE EXCEPTION 'public manufacturing receipt exceeds its claim' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(sum(e.qty),0) INTO source_total FROM preplan_analysis_stock_exact_pegs e
      WHERE e.source_stock_document_item_id=item.id;
    source_total:=source_total+COALESCE((SELECT sum(allocated_qty) FROM production_material_make_receipt_allocations
        WHERE receipt_item_id=item.id AND status='EFFECTIVE'),0);
    IF source_total>item.base_qty THEN RAISE EXCEPTION 'manufacturing receipt lot is over-allocated' USING ERRCODE='23514'; END IF;
    SELECT COALESCE(sum(e.qty),0) INTO public_total
      FROM preplan_analysis_stock_exact_pegs e JOIN preplan_make_public_claims c ON c.id=e.make_public_claim_id
      JOIN stock_documents d ON d.id=e.source_stock_document_id AND d.status=1 AND NOT d.is_deleted
      WHERE c.source_plan_item_id=source.id;
    SELECT received_public_qty INTO public_capacity FROM v_preplan_make_public_supply_state
      WHERE source_plan_item_id=source.id;
    IF public_capacity IS NULL OR public_total>public_capacity THEN
        RAISE EXCEPTION 'public manufacturing claims cannot seize the private receipt share' USING ERRCODE='23514';
    END IF;
END;
$$;
DO $exact_claim_branch$
DECLARE definition TEXT; anchor TEXT:=E'BEGIN\n';
BEGIN
    SELECT pg_get_functiondef('fn_check_preplan_analysis_stock_exact_peg()'::regprocedure) INTO definition;
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V722 exact peg guard entry changed'; END IF;
    EXECUTE replace(definition,anchor,anchor||'
    IF NEW.make_public_claim_id IS NOT NULL THEN
        PERFORM fn_check_make_public_exact_peg(NEW.id); RETURN NEW;
    END IF;
');
    SELECT pg_get_functiondef('fn_guard_public_output_inherited_peg()'::regprocedure) INTO definition;
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V722 public output guard entry changed'; END IF;
    EXECUTE replace(definition,anchor,anchor||'
    IF TG_TABLE_NAME=''preplan_analysis_stock_exact_pegs'' AND (to_jsonb(NEW)->>''make_public_claim_id'') IS NOT NULL THEN
        RETURN NEW; -- Deferred exact guard validates the independent claim and physical lot.
    END IF;
');
END;
$exact_claim_branch$;

-- Keep the actual movement, FQC release and immutable ORIGIN_MAKE evidence in
-- the common qualification predicate. Only the plan-to-beneficiary proof gains
-- an alternative: an independent public claim may belong to another analysis.
DO $qualified_public_claim$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_preplan_reservation_has_qualified_origin(uuid)'::regprocedure),chr(13),'') INTO definition;
    needle:='AND make_source.analysis_id=exact.origin_analysis_id
                   AND ((make_source.source_type=''MAKE_COMPONENT'' AND make_source.parent_analysis_material_id=exact.origin_analysis_material_id)
                       OR fn_preplan_aggregate_make_origin(make_source.id,exact.supply_action_allocation_id,exact.origin_analysis_material_id,plan.id))
                   AND NOT fn_finished_in_is_public_output(stock_item.id)';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V722 qualified MAKE provenance contract changed'; END IF;
    EXECUTE replace(definition,needle,'AND ((make_source.analysis_id=exact.origin_analysis_id
                   AND ((make_source.source_type=''MAKE_COMPONENT'' AND make_source.parent_analysis_material_id=exact.origin_analysis_material_id)
                       OR fn_preplan_aggregate_make_origin(make_source.id,exact.supply_action_allocation_id,exact.origin_analysis_material_id,plan.id))
                   AND NOT fn_finished_in_is_public_output(stock_item.id))
                 OR EXISTS(SELECT 1 FROM preplan_make_public_claims claim
                    WHERE claim.id=exact.make_public_claim_id
                      AND claim.source_plan_item_id=stock_item.upstream_item_id
                      AND claim.target_analysis_id=exact.origin_analysis_id
                      AND claim.target_material_id=exact.origin_analysis_material_id
                      AND claim.qty-fn_preplan_make_public_claim_cancelled_qty(claim.id)>=exact.qty))');
END;
$qualified_public_claim$;

CREATE FUNCTION fn_guard_make_public_claim_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='production_plan_items' THEN
        IF EXISTS(SELECT 1 FROM preplan_make_public_claims c WHERE c.source_plan_item_id=OLD.id
            AND c.qty>fn_preplan_make_public_claim_cancelled_qty(c.id)) AND
          (TG_OP='DELETE' OR (NEW.goods_id,NEW.color_id,NEW.unit_id,NEW.unit_rate,NEW.plan_id,NEW.is_deleted)
            IS DISTINCT FROM (OLD.goods_id,OLD.color_id,OLD.unit_id,OLD.unit_rate,OLD.plan_id,OLD.is_deleted)
            OR NEW.qty<OLD.qty) THEN
            RAISE EXCEPTION 'manufacturing source has public claims; release them before changing its identity or quantity' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='production_plans' THEN
        IF EXISTS(SELECT 1 FROM preplan_make_public_claims c JOIN production_plan_items i ON i.id=c.source_plan_item_id
            WHERE i.plan_id=OLD.id AND fn_preplan_make_public_claim_pending_qty(c.id)>0) AND
          (TG_OP='DELETE' OR NEW.is_deleted OR NEW.is_canceled
            OR (NEW.status IS DISTINCT FROM OLD.status AND NOT(OLD.status=0 AND NEW.status=1))
            OR (NEW.material_analysis_id,NEW.material_analysis_item_id,NEW.bom_depth)
             IS DISTINCT FROM (OLD.material_analysis_id,OLD.material_analysis_item_id,OLD.bom_depth)) THEN
            RAISE EXCEPTION 'manufacturing source has unreceived public claims' USING ERRCODE='23514';
        END IF;
    ELSE
        IF (TG_OP='DELETE' OR NEW.is_deleted OR NEW.status='CANCELLED' OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id)
          AND EXISTS(SELECT 1 FROM preplan_make_public_claims c JOIN production_plan_items i ON i.id=c.source_plan_item_id
            JOIN production_plans p ON p.id=i.plan_id WHERE (c.target_analysis_id=OLD.id OR p.material_analysis_id=OLD.id)
              AND c.qty>fn_preplan_make_public_claim_cancelled_qty(c.id)) THEN
            RAISE EXCEPTION 'analysis has public manufacturing claims; release them first' USING ERRCODE='23514';
        END IF;
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_make_public_plan_item BEFORE UPDATE OR DELETE ON production_plan_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_claim_lifecycle();
CREATE TRIGGER trg_guard_make_public_plan BEFORE UPDATE OR DELETE ON production_plans
    FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_claim_lifecycle();
CREATE TRIGGER trg_guard_make_public_analysis BEFORE UPDATE OR DELETE ON production_material_analyses
    FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_claim_lifecycle();
CREATE FUNCTION fn_guard_make_public_target_material() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM preplan_make_public_claims c WHERE c.target_material_id=OLD.id
        AND c.qty>fn_preplan_make_public_claim_cancelled_qty(c.id)) AND
      (TG_OP='DELETE' OR NOT NEW.active OR (NEW.analysis_id,NEW.goods_id,NEW.color_id,NEW.unit_id)
        IS DISTINCT FROM (OLD.analysis_id,OLD.goods_id,OLD.color_id,OLD.unit_id)) THEN
        RAISE EXCEPTION 'material still owns a public manufacturing claim; release it before removing its identity' USING ERRCODE='23514';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_make_public_target_material BEFORE UPDATE OF active,analysis_id,goods_id,color_id,unit_id OR DELETE
    ON production_material_analysis_materials FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_target_material();
CREATE FUNCTION fn_guard_make_public_budget_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source_plan UUID;
BEGIN
    IF TG_TABLE_NAME='preplan_supply_actions' THEN
        SELECT plan_id INTO source_plan FROM preplan_aggregate_batches WHERE action_id=OLD.id AND route='MAKE';
        IF source_plan IS NULL THEN IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW; END IF;
        IF TG_OP<>'DELETE' AND NEW.status<>'CANCELLED'
            AND NEW.public_surplus_qty>=OLD.public_surplus_qty THEN RETURN NEW; END IF;
    ELSE
        source_plan:=OLD.plan_id;
        IF TG_OP<>'DELETE' AND NEW.allocation_status IN('SUBMITTED','APPROVED')
            AND NEW.public_surplus_qty>=OLD.public_surplus_qty THEN RETURN NEW; END IF;
    END IF;
    IF EXISTS(SELECT 1 FROM preplan_make_public_claims claim JOIN production_plan_items item ON item.id=claim.source_plan_item_id
        WHERE item.plan_id=source_plan AND claim.qty>fn_preplan_make_public_claim_cancelled_qty(claim.id)) THEN
        RAISE EXCEPTION 'public manufacturing source budget has claims and cannot be removed or reduced' USING ERRCODE='23514';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_make_public_action_budget BEFORE UPDATE OF public_surplus_qty,status OR DELETE
    ON preplan_supply_actions FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_budget_source();
CREATE TRIGGER trg_guard_make_public_plan_link_budget BEFORE UPDATE OF public_surplus_qty,allocation_status OR DELETE
    ON production_material_analysis_plan_links FOR EACH ROW EXECUTE FUNCTION fn_guard_make_public_budget_source();

-- FINISHED_IN recomputes plan.is_closed before publishing its receipt/pegs in
-- the same transaction. Validate closure/stoppage against the final facts,
-- while allowing already-produced public output to fulfil its existing claims.
CREATE FUNCTION fn_check_make_public_plan_closure() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM production_plans plan JOIN production_plan_items item ON item.plan_id=plan.id
        JOIN v_preplan_make_public_supply_state source ON source.source_plan_item_id=item.id
        WHERE plan.id=NEW.id AND (plan.is_closed OR plan.is_stopped)
          AND source.claim_open_qty>GREATEST(fn_preplan_make_public_produced_qty(item.id)-source.received_public_qty,0)) THEN
        RAISE EXCEPTION 'manufacturing source cannot close or stop before its public claims can be fulfilled' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_make_public_plan_closure AFTER UPDATE OF is_closed,is_stopped ON production_plans
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_make_public_plan_closure();

SELECT fn_audit_track_table('preplan_make_public_claims','NONE','data_change',false);
SELECT fn_audit_track_table('preplan_make_public_claim_cancellations','NONE','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V722 reset policy anchor changed'; END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n (''preplan_make_public_claims'', ''CLEAR''),\n (''preplan_make_public_claim_cancellations'', ''CLEAR'')');
END;
$reset_policy$;
