-- Shared manufacturing direct handover retains the existing physical transfer,
-- workshop membership, report approval, FQC and ISSUE chain. These immutable
-- slices prove only which private source share the handover may consume.
CREATE TABLE preplan_aggregate_direct_transfer_slices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_item_id UUID NOT NULL REFERENCES production_workshop_direct_transfer_items(id) DEFERRABLE INITIALLY DEFERRED,
    slice_no INTEGER NOT NULL CHECK(slice_no>0),
    source_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    target_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    aggregate_alias_id UUID REFERENCES preplan_aggregate_material_aliases(id),
    supply_action_allocation_id UUID REFERENCES preplan_supply_action_allocations(id),
    qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT aggregate_direct_slice_scope CHECK(aggregate_alias_id IS NOT NULL OR supply_action_allocation_id IS NOT NULL),
    UNIQUE(transfer_item_id,slice_no),
    UNIQUE NULLS NOT DISTINCT(transfer_item_id,aggregate_alias_id,supply_action_allocation_id)
);
CREATE INDEX idx_aggregate_direct_alias ON preplan_aggregate_direct_transfer_slices(aggregate_alias_id,transfer_item_id) WHERE aggregate_alias_id IS NOT NULL;
CREATE INDEX idx_aggregate_direct_member ON preplan_aggregate_direct_transfer_slices(supply_action_allocation_id,transfer_item_id) WHERE supply_action_allocation_id IS NOT NULL;
CREATE INDEX idx_aggregate_direct_source ON preplan_aggregate_direct_transfer_slices(source_material_id,transfer_item_id);
CREATE INDEX idx_aggregate_direct_target ON preplan_aggregate_direct_transfer_slices(target_material_id,transfer_item_id);

CREATE FUNCTION fn_preplan_aggregate_direct_scopes(p_producing UUID,p_demand UUID)
RETURNS TABLE(source_material_id UUID,target_material_id UUID,alias_id UUID,allocation_id UUID)
LANGUAGE plpgsql STABLE AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM production_execution_segments segment JOIN production_plans plan ON plan.id=segment.plan_id
   JOIN preplan_aggregate_batches batch ON batch.analysis_id=plan.material_analysis_id WHERE segment.id=p_producing) THEN RETURN; END IF;
 RETURN QUERY
 WITH context AS MATERIALIZED (
   SELECT source_item.id AS source_item,source_item.source_type,source_item.parent_analysis_material_id AS old_source,
          source_plan.id AS source_plan,source_plan.material_analysis_id AS analysis_id,
          target_plan.material_analysis_item_id AS target_item,demand.goods_id,demand.color_id,demand.unit_id
   FROM production_execution_segments producing
   JOIN production_plans source_plan ON source_plan.id=producing.plan_id AND NOT source_plan.is_deleted AND NOT source_plan.is_canceled
   JOIN production_material_analysis_items source_item ON source_item.id=source_plan.material_analysis_item_id AND NOT source_item.is_deleted
   JOIN production_material_demands demand ON demand.id=p_demand AND NOT demand.is_deleted AND demand.supply_route='MAKE'
   JOIN production_execution_segments receiving ON receiving.id=demand.execution_segment_id AND NOT receiving.is_deleted
   JOIN production_plans target_plan ON target_plan.id=receiving.plan_id AND NOT target_plan.is_deleted AND NOT target_plan.is_canceled
      AND target_plan.material_analysis_id=source_plan.material_analysis_id
   WHERE producing.id=p_producing AND NOT producing.is_deleted AND producing.id<>receiving.id
      AND producing.product_goods_id=demand.goods_id AND producing.product_color_id IS NOT DISTINCT FROM demand.color_id
 ), sources AS MATERIALIZED (
   SELECT context.*,context.old_source AS material_id,NULL::uuid AS member
   FROM context WHERE context.source_type='MAKE_COMPONENT' AND context.old_source IS NOT NULL
   UNION ALL
   SELECT context.*,allocation.analysis_material_id,allocation.id
   FROM context JOIN preplan_aggregate_batches batch ON batch.anchor_analysis_item_id=context.source_item
      AND batch.plan_id=context.source_plan AND batch.analysis_id=context.analysis_id AND batch.route='MAKE'
   JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
   JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id AND allocation.external_item_id=context.source_item
   WHERE context.source_type='AGGREGATE_MAKE'
 )
 SELECT source.material_id,source.material_id,NULL::uuid,source.member
 FROM sources source JOIN production_material_analysis_materials material ON material.id=source.material_id
 WHERE source.member IS NOT NULL AND fn_analysis_plan_material_matches(source.target_item,material.id)
   AND (material.goods_id,material.color_id,material.unit_id) IS NOT DISTINCT FROM (source.goods_id,source.color_id,source.unit_id)
 UNION ALL
 SELECT source.material_id,alias.aggregate_material_id,alias.id,source.member
 FROM sources source JOIN preplan_aggregate_material_aliases alias ON alias.source_material_id=source.material_id
 JOIN production_material_analysis_materials target ON target.id=alias.aggregate_material_id AND target.analysis_item_id=source.target_item
 WHERE fn_preplan_aggregate_alias_valid(alias.id)
   AND (target.goods_id,target.color_id,target.unit_id) IS NOT DISTINCT FROM (source.goods_id,source.color_id,source.unit_id);
END $$;

-- Keep the original non-shared responsibility unchanged. Preserve function
-- identity so existing relationship and source-custody callers use this proof.
DO $originals$
DECLARE definition TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_workshop_direct_responsibility_allows(uuid,uuid)'::regprocedure) INTO definition;
 EXECUTE replace(definition,'FUNCTION public.fn_workshop_direct_responsibility_allows(',
    'FUNCTION public.fn_workshop_direct_responsibility_allows_before_v715(');
 SELECT pg_get_functiondef('fn_workshop_direct_remaining_for_source(uuid,uuid)'::regprocedure) INTO definition;
 EXECUTE replace(definition,'FUNCTION public.fn_workshop_direct_remaining_for_source(',
    'FUNCTION public.fn_workshop_direct_remaining_for_source_before_v715(');
END $originals$;
CREATE OR REPLACE FUNCTION fn_workshop_direct_responsibility_allows(p_producing UUID,p_demand UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN fn_workshop_direct_responsibility_allows_before_v715(p_producing,p_demand)
    OR EXISTS(SELECT 1 FROM fn_preplan_aggregate_direct_scopes(p_producing,p_demand));
END $$;

-- A direct delivery uses the same actual FINISHED_IN/exact origin as warehouse
-- receipts. Never sum a transfer promise and that origin as two supplies.
CREATE FUNCTION fn_preplan_aggregate_direct_slice_represented(p_slice UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE slice preplan_aggregate_direct_transfer_slices%ROWTYPE; report_item UUID; total NUMERIC;
BEGIN
 SELECT * INTO slice FROM preplan_aggregate_direct_transfer_slices WHERE id=p_slice;
 SELECT source_report_item_id INTO report_item FROM production_workshop_direct_transfer_items
   WHERE id=slice.transfer_item_id AND reversal_id IS NULL;
 IF report_item IS NULL THEN RETURN 0; END IF;
 IF slice.aggregate_alias_id IS NOT NULL THEN
   SELECT COALESCE(sum(fn_preplan_aggregate_delegation_active_qty(delegation.id)),0) INTO total FROM preplan_make_entitlement_delegations delegation
   JOIN preplan_stock_entitlement_events source ON source.id=delegation.source_entitlement_event_id
   JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=source.stock_reservation_id
   JOIN stock_document_items item ON item.id=exact.source_stock_document_item_id
   JOIN stock_documents doc ON doc.id=item.doc_id AND doc.status=1 AND NOT doc.is_deleted
   WHERE delegation.aggregate_alias_id=slice.aggregate_alias_id AND item.source_daily_report_item_id=report_item;
 ELSE
   SELECT COALESCE(sum(exact.qty),0) INTO total FROM preplan_analysis_stock_exact_pegs exact
   JOIN stock_document_items item ON item.id=exact.source_stock_document_item_id
   JOIN stock_documents doc ON doc.id=item.doc_id AND doc.status=1 AND NOT doc.is_deleted
   WHERE exact.supply_action_allocation_id=slice.supply_action_allocation_id AND item.source_daily_report_item_id=report_item;
 END IF;
 RETURN LEAST(slice.qty_base,total);
END $$;

CREATE FUNCTION fn_preplan_aggregate_direct_unrepresented(p_alias UUID,p_member UUID,p_source UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN COALESCE((SELECT sum(GREATEST(slice.qty_base-fn_preplan_aggregate_direct_slice_represented(slice.id),0))
   FROM preplan_aggregate_direct_transfer_slices slice JOIN production_workshop_direct_transfer_items transfer ON transfer.id=slice.transfer_item_id AND transfer.reversal_id IS NULL
   WHERE (p_alias IS NULL OR slice.aggregate_alias_id=p_alias) AND (p_member IS NULL OR slice.supply_action_allocation_id=p_member)
     AND (p_source IS NULL OR slice.source_material_id=p_source)),0);
END $$;

CREATE FUNCTION fn_preplan_aggregate_direct_scope_remaining(p_source UUID,p_target UUID,p_alias UUID,p_member UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE capacity NUMERIC:=99999999999999; future NUMERIC;
BEGIN
 IF p_member IS NOT NULL THEN
   capacity:=GREATEST(fn_preplan_allocation_admitted_qty(p_member)-fn_preplan_allocation_received_qty(p_member)
       -fn_preplan_aggregate_direct_unrepresented(NULL,p_member,NULL),0);
 END IF;
 IF p_alias IS NOT NULL THEN
   IF NOT fn_preplan_aggregate_alias_valid(p_alias) THEN RETURN 0; END IF;
   capacity:=LEAST(capacity,GREATEST(fn_preplan_aggregate_alias_qty(p_alias)-fn_preplan_aggregate_alias_delegated_qty(p_alias)
       -fn_preplan_aggregate_direct_unrepresented(p_alias,NULL,NULL),0));
   SELECT GREATEST(pending_qty-fn_preplan_aggregate_direct_unrepresented(NULL,NULL,p_source),0) INTO future
     FROM fn_preplan_aggregate_alias_supply_sources(p_target) WHERE alias_id=p_alias;
   future:=COALESCE(future,0);
   capacity:=LEAST(capacity,future);
 ELSIF EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases alias
       WHERE alias.source_material_id=p_source AND fn_preplan_aggregate_alias_identity_valid(alias.id)) THEN
   capacity:=LEAST(capacity,GREATEST(fn_preplan_aggregate_source_retained_qty(p_source)
       -fn_preplan_aggregate_target_committed_qty(p_source)-fn_preplan_aggregate_direct_unrepresented(NULL,NULL,p_source),0));
 END IF;
 RETURN GREATEST(capacity,0);
END $$;

CREATE OR REPLACE FUNCTION fn_workshop_direct_remaining_for_source(p_producing UUID,p_demand UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE baseline NUMERIC; capacity NUMERIC; old_source UUID;
BEGIN
 baseline:=fn_workshop_direct_remaining_for_source_before_v715(p_producing,p_demand);
 IF NOT EXISTS(SELECT 1 FROM production_execution_segments segment JOIN production_plans plan ON plan.id=segment.plan_id
   JOIN preplan_aggregate_batches batch ON batch.analysis_id=plan.material_analysis_id WHERE segment.id=p_producing) THEN RETURN baseline; END IF;
 SELECT sum(fn_preplan_aggregate_direct_scope_remaining(scope.source_material_id,scope.target_material_id,scope.alias_id,scope.allocation_id))
 INTO capacity FROM fn_preplan_aggregate_direct_scopes(p_producing,p_demand) scope;
 IF capacity IS NOT NULL THEN RETURN LEAST(baseline,capacity); END IF;
 -- An original parent retains only its untransferred share, even when an old
 -- approved demand still contains the pre-transfer full requirement.
 SELECT item.parent_analysis_material_id INTO old_source FROM production_execution_segments segment
 JOIN production_plans plan ON plan.id=segment.plan_id JOIN production_material_analysis_items item ON item.id=plan.material_analysis_item_id
 WHERE segment.id=p_producing AND item.source_type='MAKE_COMPONENT';
 IF EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=old_source AND fn_preplan_aggregate_alias_identity_valid(alias.id)) THEN
   baseline:=LEAST(baseline,GREATEST(fn_preplan_aggregate_source_retained_qty(old_source)
      -fn_preplan_aggregate_target_committed_qty(old_source),0));
 END IF;
 RETURN baseline;
END $$;

CREATE FUNCTION fn_guard_aggregate_direct_slices() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Aggregate direct-transfer source proofs are append-only' USING ERRCODE='55000'; END IF;
 IF pg_trigger_depth()<2 THEN RAISE EXCEPTION 'Aggregate direct-transfer proof must be created by its real handover' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_aggregate_direct_slices BEFORE INSERT OR UPDATE OR DELETE ON preplan_aggregate_direct_transfer_slices
FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_direct_slices();

CREATE FUNCTION fn_record_aggregate_direct_slices() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE producing UUID; remaining NUMERIC; scope RECORD; take NUMERIC; ordinal INTEGER:=0; actor UUID;
BEGIN
 SELECT source.execution_segment_id,round(NEW.qty*COALESCE(source.unit_rate,1),4),header.created_by
 INTO producing,remaining,actor FROM production_daily_report_items source
 JOIN production_workshop_direct_transfers header ON header.id=NEW.transfer_id WHERE source.id=NEW.source_report_item_id;
 IF NOT EXISTS(SELECT 1 FROM fn_preplan_aggregate_direct_scopes(producing,NEW.to_demand_id)) THEN RETURN NEW; END IF;
 -- Source-material locks serialize warehouse attribution and alias/member
 -- handovers in the same ownership scope, not across unrelated workshops.
 PERFORM 1 FROM production_material_analysis_materials material WHERE material.id IN(
   SELECT source_material_id FROM fn_preplan_aggregate_direct_scopes(producing,NEW.to_demand_id)) ORDER BY material.id FOR UPDATE;
 IF remaining>fn_workshop_direct_remaining_for_source(producing,NEW.to_demand_id) THEN
   RAISE EXCEPTION '共享直送数量超过准确来源的可交接份额' USING ERRCODE='23514'; END IF;
 FOR scope IN SELECT * FROM fn_preplan_aggregate_direct_scopes(producing,NEW.to_demand_id) ORDER BY allocation_id NULLS FIRST,alias_id NULLS FIRST LOOP
   take:=LEAST(remaining,fn_preplan_aggregate_direct_scope_remaining(scope.source_material_id,scope.target_material_id,scope.alias_id,scope.allocation_id));
   IF take<=0 THEN CONTINUE; END IF;
   ordinal:=ordinal+1;
   INSERT INTO preplan_aggregate_direct_transfer_slices(transfer_item_id,slice_no,source_material_id,target_material_id,aggregate_alias_id,supply_action_allocation_id,qty_base,created_by)
   VALUES(NEW.id,ordinal,scope.source_material_id,scope.target_material_id,scope.alias_id,scope.allocation_id,take,actor);
   remaining:=remaining-take;
   EXIT WHEN remaining=0;
 END LOOP;
 IF remaining<>0 THEN RAISE EXCEPTION '共享直送来源份额不足，不能使用其他来源或公共产出兜底' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_aggregate_direct_slices BEFORE INSERT ON production_workshop_direct_transfer_items
FOR EACH ROW EXECUTE FUNCTION fn_record_aggregate_direct_slices();

-- Reserved handover rights permit this exact incoming line-side lot to pass
-- directly to its proved alias. Other stock is still protected by retained qty.
CREATE FUNCTION fn_preplan_aggregate_direct_delegate_credit(p_alias UUID,p_event UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN COALESCE((SELECT sum(GREATEST(LEAST(slice.qty_base-fn_preplan_aggregate_direct_slice_represented(slice.id),exact.qty-COALESCE((
      SELECT sum(fn_preplan_aggregate_delegation_active_qty(delegation.id)) FROM preplan_make_entitlement_delegations delegation
      JOIN preplan_stock_entitlement_events delegated_source ON delegated_source.id=delegation.source_entitlement_event_id
      WHERE delegation.aggregate_alias_id=p_alias AND delegated_source.stock_reservation_id=source.stock_reservation_id),0)),0))
   FROM preplan_stock_entitlement_events source JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=source.stock_reservation_id
   JOIN stock_document_items item ON item.id=exact.source_stock_document_item_id
   JOIN production_workshop_direct_transfer_items transfer ON transfer.source_report_item_id=item.source_daily_report_item_id AND transfer.reversal_id IS NULL
   JOIN production_workshop_direct_transfers header ON header.id=transfer.transfer_id
   JOIN stock_reservations reservation ON reservation.id=source.stock_reservation_id AND reservation.warehouse_id=header.line_side_warehouse_id
   JOIN preplan_aggregate_direct_transfer_slices slice ON slice.transfer_item_id=transfer.id AND slice.aggregate_alias_id=p_alias
      AND slice.source_material_id=exact.origin_analysis_material_id
   WHERE source.id=p_event),0);
END $$;

DO $delegation_credit$
DECLARE definition TEXT; needle TEXT:='OR NEW.qty>fn_preplan_aggregate_source_delegate_available_qty(NEW.source_analysis_material_id)';
BEGIN
 SELECT pg_get_functiondef('fn_check_preplan_make_entitlement_delegation()'::regprocedure) INTO definition;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 aggregate delegation quota anchor changed'; END IF;
 EXECUTE replace(definition,needle,'OR NEW.qty>GREATEST(fn_preplan_aggregate_source_delegate_available_qty(NEW.source_analysis_material_id),
     fn_preplan_aggregate_direct_delegate_credit(NEW.aggregate_alias_id,NEW.source_entitlement_event_id))');
END $delegation_credit$;

CREATE FUNCTION fn_preplan_aggregate_delegation_owns_restored_lot(p_delegation UUID,p_lot UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN EXISTS(WITH RECURSIVE owned(id) AS (
   SELECT event.id FROM preplan_make_entitlement_delegations header
   JOIN preplan_stock_entitlement_events event ON event.event_group_id=header.id AND event.event_type='MAKE_DELEGATE_IN'
   WHERE header.id=p_delegation AND header.aggregate_alias_id IS NOT NULL
   UNION
   SELECT restored.id FROM owned parent
   JOIN preplan_stock_entitlement_events counter ON counter.source_entitlement_event_id=parent.id
   JOIN preplan_stock_entitlement_events restored ON restored.counter_event_id=counter.id AND restored.event_type='RESTORE'
   JOIN preplan_make_entitlement_delegations header ON header.id=p_delegation
   WHERE (counter.event_type='FORMALIZE' OR (counter.event_type='MAKE_DELEGATE_OUT' AND EXISTS(
       SELECT 1 FROM preplan_make_entitlement_delegations child WHERE child.id=counter.event_group_id AND child.aggregate_alias_id IS NOT NULL)))
     AND restored.stock_reservation_id=header.stock_reservation_id AND restored.beneficiary_analysis_id=header.analysis_id
     AND restored.beneficiary_analysis_material_id=header.target_analysis_material_id
 ) SELECT 1 FROM owned WHERE id=p_lot);
END $$;
DO $delegation_restored_totals$
DECLARE definition TEXT; needle TEXT:='AND event.source_entitlement_event_id = in_event_id';
BEGIN
 SELECT pg_get_functiondef('fn_validate_preplan_make_delegation_totals()'::regprocedure) INTO definition;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 delegation paired-restoration anchor changed'; END IF;
 EXECUTE replace(definition,needle,'AND (event.source_entitlement_event_id = in_event_id OR (
     header.aggregate_alias_id IS NOT NULL AND fn_preplan_aggregate_delegation_owns_restored_lot(header.id,event.source_entitlement_event_id)))');
END $delegation_restored_totals$;

CREATE FUNCTION fn_preplan_aggregate_exact_formalized(p_exact UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN EXISTS(SELECT 1 FROM preplan_analysis_stock_exact_pegs exact
   JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id
   JOIN stock_document_items item ON item.id=exact.source_stock_document_item_id
   JOIN production_plan_items plan_item ON plan_item.id=item.upstream_item_id
   JOIN production_plans plan ON plan.id=plan_item.plan_id
   WHERE exact.id=p_exact AND exact.source_receipt_type='MAKE'
     AND fn_preplan_aggregate_make_origin(plan.material_analysis_item_id,exact.supply_action_allocation_id,exact.origin_analysis_material_id,plan.id)
     AND reservation.status IN(0,1) AND reservation.release_reason='TRANSFERRED_TO_PLAN'
     AND reservation.qty=exact.qty AND reservation.released_qty>0 AND reservation.released_qty<=exact.qty
     AND reservation.consumed_qty=0 AND NOT reservation.is_deleted
     AND fn_preplan_reservation_has_qualified_origin(reservation.id)
     AND COALESCE((SELECT sum(formal.qty-COALESCE((SELECT sum(restored.qty) FROM preplan_stock_entitlement_events restored
          WHERE restored.counter_event_id=formal.id AND restored.event_type='RESTORE'),0))
          FROM preplan_stock_entitlement_events formal WHERE formal.stock_reservation_id=reservation.id AND formal.event_type='FORMALIZE'),0)=reservation.released_qty);
END $$;
DO $same_transaction_formalization$
DECLARE definition TEXT; needle TEXT;
BEGIN
 SELECT replace(pg_get_functiondef('fn_check_preplan_analysis_stock_exact_peg()'::regprocedure),chr(13),'') INTO definition;
 needle:='OR reservation.status <> 0';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 exact reservation status anchor changed'; END IF;
 definition:=replace(definition,needle,'OR (reservation.status <> 0 AND NOT fn_preplan_aggregate_exact_formalized(NEW.id))');
 needle:='OR reservation.released_qty <> 0';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 exact reservation release anchor changed'; END IF;
 definition:=replace(definition,needle,'OR (reservation.released_qty <> 0 AND NOT fn_preplan_aggregate_exact_formalized(NEW.id))');
 needle:=E'GREATEST(\n            reservation.qty - reservation.consumed_qty\n                - reservation.released_qty, 0)';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 exact allocation quantity anchor changed'; END IF;
 EXECUTE replace(definition,needle,'(CASE WHEN fn_preplan_aggregate_exact_formalized(NEW.id) THEN NEW.qty ELSE '||needle||' END)');
END $same_transaction_formalization$;

-- Commit only when each real shared direct receipt entered the same exact
-- ownership ledger used by warehouse receipts. A generic or guessed source
-- cannot silently bypass private accounting.
CREATE FUNCTION fn_assert_aggregate_direct_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE slice RECORD; received NUMERIC; before_qty NUMERIC;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM preplan_aggregate_direct_transfer_slices WHERE transfer_item_id=NEW.id) THEN RETURN NULL; END IF;
 IF (SELECT sum(qty_base) FROM preplan_aggregate_direct_transfer_slices WHERE transfer_item_id=NEW.id)
     IS DISTINCT FROM (SELECT round(NEW.qty*COALESCE(unit_rate,1),4) FROM production_daily_report_items WHERE id=NEW.source_report_item_id) THEN
   RAISE EXCEPTION '共享直送份额之和必须等于实际交接基本数量' USING ERRCODE='23514';
 END IF;
 FOR slice IN SELECT proof.* FROM preplan_aggregate_direct_transfer_slices proof
   JOIN production_workshop_direct_transfer_items transfer ON transfer.id=proof.transfer_item_id AND transfer.reversal_id IS NULL
   WHERE proof.transfer_item_id=NEW.id ORDER BY proof.slice_no LOOP
   SELECT COALESCE(sum(item.base_qty),0) INTO received FROM stock_document_items item
   JOIN stock_documents doc ON doc.id=item.doc_id AND doc.doc_type='FINISHED_IN' AND doc.status=1 AND NOT doc.is_deleted
   JOIN production_workshop_direct_transfer_items transfer ON transfer.source_report_item_id=item.source_daily_report_item_id
   WHERE transfer.id=NEW.id AND NOT item.is_deleted AND NOT fn_finished_in_is_public_output(item.id);
   SELECT COALESCE(sum(qty_base),0) INTO before_qty FROM preplan_aggregate_direct_transfer_slices
     WHERE transfer_item_id=NEW.id AND slice_no<slice.slice_no;
   IF fn_preplan_aggregate_direct_slice_represented(slice.id)<LEAST(slice.qty_base,GREATEST(received-before_qty,0)) THEN
     RAISE EXCEPTION '共享直送实收缺少原来源至接收需求的精确权益证明' USING ERRCODE='23514';
   END IF;
   IF slice.aggregate_alias_id IS NOT NULL AND fn_preplan_aggregate_alias_delegated_qty(slice.aggregate_alias_id)
       +fn_preplan_aggregate_direct_unrepresented(slice.aggregate_alias_id,NULL,NULL)>fn_preplan_aggregate_alias_qty(slice.aggregate_alias_id) THEN
     RAISE EXCEPTION '共享直送与仓库权益合计超过原路径承接份额' USING ERRCODE='23514';
   END IF;
   IF slice.supply_action_allocation_id IS NOT NULL AND fn_preplan_allocation_received_qty(slice.supply_action_allocation_id)
       +fn_preplan_aggregate_direct_unrepresented(NULL,slice.supply_action_allocation_id,NULL)>fn_preplan_allocation_admitted_qty(slice.supply_action_allocation_id) THEN
     RAISE EXCEPTION '共享直送与仓库实收合计超过原来源产出份额' USING ERRCODE='23514';
   END IF;
 END LOOP;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_aggregate_direct_receipt AFTER INSERT OR UPDATE ON production_workshop_direct_transfer_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_aggregate_direct_receipt();

CREATE FUNCTION fn_guard_aggregate_direct_cancellation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.status='CANCELLED' AND OLD.status<>'CANCELLED' AND EXISTS(
   SELECT 1 FROM preplan_aggregate_batches batch
   JOIN preplan_aggregate_material_aliases alias ON alias.batch_id=batch.id
   JOIN preplan_aggregate_direct_transfer_slices slice ON slice.aggregate_alias_id=alias.id
   JOIN v_workshop_direct_supply_lots lot ON lot.id=slice.transfer_item_id
   WHERE batch.action_id=NEW.id AND lot.received_qty>fn_workshop_source_net_moved_from_technical(lot.id)) THEN
   RAISE EXCEPTION '共享批次仍有车间直送材料，先退回正常仓或撤回实际入库后再撤销'
     USING ERRCODE='23514',CONSTRAINT='aggregate_direct_material_cancellation_dependency';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_aggregate_direct_cancellation BEFORE UPDATE OF status ON preplan_supply_actions
FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_direct_cancellation();

-- The existing package lifecycle may close an approved shared-direct DRAW
-- only after its real issues have all been reversed. Keep the approved history
-- as REVERSED; never turn it back into a draft or delete it.
CREATE FUNCTION fn_preplan_aggregate_direct_draw_reversible(p_document UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN EXISTS(SELECT 1 FROM stock_documents document WHERE document.id=p_document AND document.doc_type='DRAW'
   AND document.status=1 AND NOT document.is_deleted AND document.issue_status=0
   AND EXISTS(SELECT 1 FROM stock_document_items item WHERE item.doc_id=document.id AND NOT item.is_deleted)
   AND NOT EXISTS(SELECT 1 FROM stock_document_items item WHERE item.doc_id=document.id AND NOT item.is_deleted AND (
     item.issued_qty<>0 OR NOT EXISTS(SELECT 1 FROM production_material_stock_postings issue
       WHERE issue.stock_document_item_id=item.id AND issue.posting_type='ISSUE')
     OR COALESCE((SELECT sum(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END)
          FROM production_material_stock_postings WHERE stock_document_item_id=item.id),0)<>0
     OR EXISTS(SELECT 1 FROM production_material_stock_postings posting WHERE posting.stock_document_item_id=item.id AND
       (posting.posting_type NOT IN('ISSUE','ISSUE_REVERSE') OR NOT EXISTS(
         SELECT 1 FROM production_workshop_direct_source_allocations source
         JOIN production_workshop_direct_transfer_items transfer ON transfer.id=source.transfer_item_id AND transfer.reversal_id IS NULL
         JOIN production_workshop_direct_transfers header ON header.id=transfer.transfer_id AND header.line_side_warehouse_id=document.warehouse_id
         JOIN preplan_aggregate_direct_transfer_slices proof ON proof.transfer_item_id=transfer.id
         JOIN production_material_demands demand ON demand.id=posting.demand_id
         WHERE source.stock_reservation_id=posting.reservation_id AND transfer.to_demand_id IN(demand.id,demand.split_root_demand_id)
           AND NOT EXISTS(SELECT 1 FROM production_workshop_direct_source_allocations other_source
             WHERE other_source.stock_reservation_id=posting.reservation_id AND NOT EXISTS(
               SELECT 1 FROM preplan_aggregate_direct_transfer_slices other_proof WHERE other_proof.transfer_item_id=other_source.transfer_item_id))
           AND NOT EXISTS(SELECT 1 FROM production_execution_segment_events event WHERE event.execution_segment_id=demand.execution_segment_id AND event.action='START')
           AND NOT EXISTS(SELECT 1 FROM production_daily_report_items report WHERE report.execution_segment_id=demand.execution_segment_id AND NOT report.is_deleted)
       )))
   )));
END $$;

-- V535's outer actual-warehouse/qualified-origin guard remains unchanged.
-- Material ISSUE takes a posting-owned WIP position before its reversal stores
-- that same position back. Recognize only a whole, single-source, same-pool
-- shared-direct round trip; no value or movement is rewritten by this proof.
CREATE FUNCTION fn_preplan_aggregate_returned_issue_parent(p_current UUID)
RETURNS UUID LANGUAGE plpgsql STABLE AS $$
DECLARE returned stock_value_events%ROWTYPE; issued stock_value_events%ROWTYPE;
    root stock_value_nodes%ROWTYPE; current_pool stock_value_nodes%ROWTYPE;
    transfer stock_value_position_transfers%ROWTYPE; source_root UUID; parent UUID; issue_posting UUID;
    visited UUID[]:='{}'::uuid[]; candidates INTEGER;
BEGIN
 SELECT * INTO current_pool FROM stock_value_nodes WHERE id=p_current AND kind='POOL';
 SELECT * INTO returned FROM stock_value_events WHERE id=current_pool.creation_event_id AND operation='POSITION_STORE'
   AND result_head_id=current_pool.id AND pool_id=current_pool.pool_id;
 IF returned.id IS NULL OR returned.qty_base<=0 THEN RETURN NULL; END IF;
 SELECT count(*) INTO candidates FROM stock_value_position_transfers WHERE event_id=returned.id;
 IF candidates<>1 THEN RETURN NULL; END IF;
 SELECT * INTO transfer FROM stock_value_position_transfers WHERE event_id=returned.id;
 IF transfer.target_node_id IS DISTINCT FROM returned.result_node_id OR transfer.qty_base<>returned.qty_base
    OR transfer.range_from<>0 OR transfer.range_to<>returned.qty_base OR transfer.quantity_basis<>returned.qty_base
    OR transfer.reversal_of_transfer_id IS NOT NULL THEN RETURN NULL; END IF;
 source_root:=transfer.source_root_id;

 -- Both physical movement identities were appended with their ISSUE facts.
 -- One complete ISSUE_REVERSE must reverse the exact source posting, whose
 -- only direct allocation has an immutable shared alias/member slice.
 SELECT count(*),min(original.id::text)::uuid INTO candidates,issue_posting
 FROM production_material_movement_links restored_link
 JOIN production_material_stock_events restored_event ON restored_event.id=restored_link.event_id AND restored_event.event_type='ISSUE_REVERSE'
 JOIN production_material_stock_postings reversal ON reversal.event_id=restored_event.id AND reversal.stock_document_item_id=restored_link.document_item_id AND reversal.posting_type='ISSUE_REVERSE'
 JOIN production_material_stock_postings original ON original.id=reversal.source_posting_id AND original.posting_type='ISSUE'
 JOIN production_material_movement_links original_link ON original_link.event_id=original.event_id AND original_link.document_item_id=original.stock_document_item_id
 WHERE restored_link.movement_id=returned.movement_id AND reversal.qty_base=original.qty_base AND reversal.qty_base=returned.qty_base
   AND original.stock_document_item_id=reversal.stock_document_item_id AND original.reservation_id=reversal.reservation_id
   AND (SELECT count(*) FROM production_workshop_direct_source_allocations source WHERE source.stock_reservation_id=original.reservation_id)=1
   AND EXISTS(SELECT 1 FROM production_workshop_direct_source_allocations source
      JOIN production_workshop_direct_transfer_items direct ON direct.id=source.transfer_item_id
      JOIN production_workshop_direct_transfers header ON header.id=direct.transfer_id
      JOIN stock_value_pools pool ON pool.id=current_pool.pool_id AND pool.warehouse_id=header.line_side_warehouse_id
      JOIN preplan_aggregate_direct_transfer_slices proof ON proof.transfer_item_id=direct.id
      WHERE source.stock_reservation_id=original.reservation_id AND source.qty_base=original.qty_base AND proof.qty_base=original.qty_base
        AND (SELECT count(*) FROM preplan_aggregate_direct_transfer_slices other WHERE other.transfer_item_id=direct.id)=1);
 IF candidates<>1 THEN RETURN NULL; END IF;
 SELECT value.* INTO issued FROM production_material_stock_postings posting
 JOIN production_material_movement_links link ON link.event_id=posting.event_id AND link.document_item_id=posting.stock_document_item_id
 JOIN stock_value_events value ON value.movement_id=link.movement_id AND value.operation='ISSUE'
 WHERE posting.id=issue_posting;
 IF issued.id IS NULL OR issued.pool_id<>returned.pool_id OR issued.qty_base<>returned.qty_base
    OR issued.qty_before<>issued.qty_base OR returned.qty_before<>0 OR current_pool.quantity_basis<>issued.qty_before THEN RETURN NULL; END IF;
 LOOP
   IF source_root IS NULL OR source_root=ANY(visited) OR cardinality(visited)>=16 THEN RETURN NULL; END IF;
   visited:=visited||source_root;
   SELECT * INTO root FROM stock_value_nodes WHERE id=source_root AND kind='ISSUE_POSITION' AND root_issue_id=id;
   IF root.id IS NULL OR root.pool_id<>issued.pool_id OR root.quantity_basis<>issued.qty_base
      OR NOT EXISTS(SELECT 1 FROM stock_value_nodes remainder WHERE remainder.id=root.return_head_id AND remainder.active
          AND remainder.range_from=remainder.range_to AND remainder.quantity_basis=root.quantity_basis) THEN RETURN NULL; END IF;
   EXIT WHEN root.id=issued.result_node_id;
   IF root.owner_kind<>'WIP' OR root.owner_id IS DISTINCT FROM issue_posting
      OR NOT EXISTS(SELECT 1 FROM stock_value_events event WHERE event.id=root.creation_event_id AND event.operation='POSITION_MOVE'
          AND event.result_node_id=root.id AND event.pool_id=issued.pool_id AND event.qty_base=issued.qty_base) THEN RETURN NULL; END IF;
   SELECT count(*) INTO candidates FROM stock_value_position_transfers WHERE event_id=root.creation_event_id;
   IF candidates<>1 THEN RETURN NULL; END IF;
   SELECT * INTO transfer FROM stock_value_position_transfers WHERE event_id=root.creation_event_id;
   IF transfer.target_node_id<>root.id OR transfer.source_slice_id IS DISTINCT FROM issue_posting
      OR transfer.qty_base<>issued.qty_base OR transfer.range_from<>0 OR transfer.range_to<>issued.qty_base
      OR transfer.quantity_basis<>issued.qty_base OR transfer.reversal_of_transfer_id IS NOT NULL THEN RETURN NULL; END IF;
   source_root:=transfer.source_root_id;
 END LOOP;
 -- The returned pool must extend the exact empty remainder of that ISSUE,
 -- with no intervening receipt, consumption, other source or warehouse.
 SELECT count(*),min(edge.parent_node_id::text)::uuid INTO candidates,parent FROM stock_value_edges edge
 JOIN stock_value_nodes previous ON previous.id=edge.parent_node_id AND previous.kind='POOL' AND previous.pool_id=issued.pool_id
 WHERE edge.child_node_id=p_current AND edge.creation_event_id=returned.id AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1;
 IF candidates<>1 OR parent IS DISTINCT FROM issued.result_head_id THEN RETURN NULL; END IF;
 SELECT count(*),min(edge.parent_node_id::text)::uuid INTO candidates,parent FROM stock_value_edges edge
 JOIN stock_value_nodes previous ON previous.id=edge.parent_node_id AND previous.kind='POOL' AND previous.pool_id=issued.pool_id
 WHERE edge.child_node_id=root.id AND edge.interval_from=0 AND edge.interval_to=root.quantity_basis AND edge.denominator=root.quantity_basis;
 IF candidates<>1 THEN RETURN NULL; END IF;
 RETURN parent;
END $$;
DO $completed_issue_return$
DECLARE definition TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_stock_value_completed_issue_return_parent(uuid)'::regprocedure) INTO definition;
 EXECUTE replace(definition,'FUNCTION public.fn_stock_value_completed_issue_return_parent(',
     'FUNCTION public.fn_stock_value_completed_issue_return_parent_before_v715(');
END $completed_issue_return$;
CREATE OR REPLACE FUNCTION fn_stock_value_completed_issue_return_parent(p_current UUID)
RETURNS UUID LANGUAGE plpgsql STABLE AS $$
DECLARE original UUID;
BEGIN
 original:=fn_stock_value_completed_issue_return_parent_before_v715(p_current);
 IF original IS NOT NULL THEN RETURN original; END IF;
 RETURN fn_preplan_aggregate_returned_issue_parent(p_current);
END $$;

DO $subcontract_source$
DECLARE definition TEXT; needle TEXT:='AND analysis_item.source_type = ''SUBCONTRACT_MAKE''';
BEGIN
 SELECT pg_get_functiondef('fn_assert_subcontract_preparation_source_before_v535(uuid)'::regprocedure) INTO definition;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 subcontract preparation source anchor changed'; END IF;
 EXECUTE replace(definition,needle,'AND (analysis_item.source_type = ''SUBCONTRACT_MAKE'' OR (
   analysis_item.source_type=''AGGREGATE_MAKE'' AND EXISTS(SELECT 1 FROM preplan_aggregate_batches shared
     WHERE shared.action_id=task.supply_action_id AND shared.route=''SUBCONTRACT''
       AND shared.analysis_id=task.analysis_id AND shared.anchor_analysis_item_id=task.preparation_item_id
       AND shared.plan_id IS NOT NULL)))');
END $subcontract_source$;

CREATE FUNCTION fn_preplan_aggregate_subcontract_task_source(p_task UUID,p_child UUID,p_plan UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN EXISTS(SELECT 1 FROM preplan_subcontract_make_tasks task JOIN preplan_aggregate_batches batch ON batch.action_id=task.supply_action_id
   JOIN production_material_analysis_items child ON child.id=batch.anchor_analysis_item_id AND child.source_type='AGGREGATE_MAKE'
   WHERE task.id=p_task AND task.preparation_item_id=p_child AND batch.anchor_analysis_item_id=p_child
     AND batch.plan_id=p_plan AND batch.route='SUBCONTRACT' AND task.analysis_id=batch.analysis_id AND child.analysis_id=batch.analysis_id);
END $$;
DO $subcontract_qualified$
DECLARE definition TEXT; needle TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_subcontract_preparation_reservation_has_qualified_origin(uuid)'::regprocedure) INTO definition;
 needle:='child.source_type=''SUBCONTRACT_MAKE''';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 subcontract qualified child anchor changed'; END IF;
 definition:=replace(definition,needle,'(child.source_type=''SUBCONTRACT_MAKE'' OR (child.source_type=''AGGREGATE_MAKE''
     AND EXISTS(SELECT 1 FROM preplan_aggregate_batches shared WHERE shared.anchor_analysis_item_id=child.id
       AND shared.plan_id=plan.id AND shared.analysis_id=child.analysis_id AND shared.route=''SUBCONTRACT'')))');
 needle:='task.preparation_item_id=child.id';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 subcontract qualified task anchor changed'; END IF;
 definition:=replace(definition,needle,needle||' AND (child.source_type<>''AGGREGATE_MAKE'' OR fn_preplan_aggregate_subcontract_task_source(task.id,child.id,plan.id))');
 needle:='task.analysis_material_id=child.parent_analysis_material_id';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V715 subcontract qualified parent anchor changed'; END IF;
 EXECUTE replace(definition,needle,'('||needle||' OR fn_preplan_aggregate_subcontract_task_source(task.id,child.id,plan.id))');
END $subcontract_qualified$;

SELECT fn_audit_track_table('preplan_aggregate_direct_transfer_slices','NONE','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
 SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V715 reset policy anchor changed'; END IF;
 EXECUTE replace(definition,anchor,anchor||E',\n (''preplan_aggregate_direct_transfer_slices'', ''CLEAR'')');
END $reset_policy$;
