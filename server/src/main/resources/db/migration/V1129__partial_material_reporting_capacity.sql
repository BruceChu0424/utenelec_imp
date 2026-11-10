-- A partially issued ordinary work order may only report the output jointly
-- supported by all frozen material demands. Complete issue, zero-material and
-- separately authorized recovery/supplement flows retain their existing rules.
-- NULL means this additional partial-issue ceiling does not apply; never zero.
-- The existing event timestamp is transaction-start time, so it cannot prove
-- whether a reversal followed a checkpoint. Postings are inserted after demand locks.
-- Keep historical rows NULL; assigning them a sequence would invent history.
CREATE SEQUENCE production_material_stock_posting_order_seq;
ALTER TABLE production_material_stock_postings ADD COLUMN ledger_order BIGINT;
ALTER SEQUENCE production_material_stock_posting_order_seq OWNED BY production_material_stock_postings.ledger_order;
ALTER TABLE production_material_stock_postings ALTER COLUMN ledger_order
    SET DEFAULT nextval('production_material_stock_posting_order_seq');
CREATE UNIQUE INDEX uq_material_stock_posting_ledger_order
    ON production_material_stock_postings(ledger_order) WHERE ledger_order IS NOT NULL;

-- Only existing INSERT grantees need nextval; do not grant setval/UPDATE.
DO $sequence_permissions$
DECLARE permission RECORD; role_sql TEXT;
BEGIN
    FOR permission IN SELECT DISTINCT acl.grantee FROM pg_class relation
        CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl,acldefault('s',relation.relowner))) acl
        WHERE relation.oid='production_material_stock_posting_order_seq'::regclass AND acl.grantee<>relation.relowner
    LOOP
        role_sql:=CASE WHEN permission.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(permission.grantee)) END;
        EXECUTE 'REVOKE ALL ON SEQUENCE production_material_stock_posting_order_seq FROM '||role_sql;
    END LOOP;
    FOR permission IN SELECT DISTINCT acl.grantee FROM pg_class relation
        CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl,acldefault('r',relation.relowner))) acl
        WHERE relation.oid='production_material_stock_postings'::regclass AND acl.privilege_type='INSERT'
    LOOP
        role_sql:=CASE WHEN permission.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(permission.grantee)) END;
        EXECUTE 'GRANT USAGE ON SEQUENCE production_material_stock_posting_order_seq TO '||role_sql;
    END LOOP;
END;
$sequence_permissions$;


-- These are immutable evidence of an observed full kit, never inventory balances.
CREATE TABLE production_material_full_kit_proofs (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
 planned_qty NUMERIC NOT NULL CHECK(planned_qty>0),
 rules_version INTEGER NOT NULL CHECK(rules_version=1),
 source_stock_order BIGINT NOT NULL,
 ledger_order BIGINT NOT NULL UNIQUE,
 created_transaction xid8 NOT NULL DEFAULT pg_current_xact_id(),
 created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_material_full_kit_proof_segment ON production_material_full_kit_proofs(execution_segment_id,ledger_order DESC);
CREATE TABLE production_material_full_kit_proof_items (
 proof_id UUID NOT NULL REFERENCES production_material_full_kit_proofs(id),
 demand_id UUID NOT NULL REFERENCES production_material_demands(id),
 supported_qty NUMERIC NOT NULL CHECK(supported_qty>=0),
 identity_snapshot JSONB NOT NULL,
 PRIMARY KEY(proof_id,demand_id)
);
CREATE INDEX idx_material_issue_reverse_proof ON production_material_stock_postings(demand_id,ledger_order)
 WHERE posting_type='ISSUE_REVERSE' AND ledger_order IS NOT NULL;
CREATE INDEX idx_material_unordered_issue_proof ON production_material_stock_postings(demand_id,event_id)
 WHERE posting_type='ISSUE' AND ledger_order IS NULL;
CREATE INDEX idx_material_posting_demand_order ON production_material_stock_postings(demand_id,ledger_order DESC)
 WHERE ledger_order IS NOT NULL;

CREATE FUNCTION fn_material_full_kit_identity(p_demand UUID) RETURNS JSONB LANGUAGE sql STABLE AS $$
 SELECT jsonb_build_object('rulesVersion',1,
  'segment',jsonb_build_array(segment.id,segment.planned_qty,to_jsonb(segment)->'source_plan_item_id',
     to_jsonb(segment)->'product_goods_id',to_jsonb(segment)->'product_color_id',
     to_jsonb(segment)->'product_unit_id',to_jsonb(segment)->'product_unit_rate'),
  'demand',jsonb_build_array(demand.id,demand.required_qty,to_jsonb(demand)->'goods_id',to_jsonb(demand)->'color_id',
     to_jsonb(demand)->'unit_id',to_jsonb(demand)->'requirement_mode',to_jsonb(demand)->'per_product_qty',
     to_jsonb(demand)->'required_for_product_qty',to_jsonb(demand)->'requirement_fingerprint',
     to_jsonb(demand)->'consumption_snapshot'))
 FROM production_material_demands demand JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
 WHERE demand.id=p_demand;
$$;

CREATE FUNCTION fn_material_kit_stock_order(p_segment UUID) RETURNS BIGINT LANGUAGE sql STABLE AS $$
 SELECT COALESCE(MAX((SELECT MAX(posting.ledger_order) FROM production_material_stock_postings posting
    WHERE posting.demand_id=demand.id AND posting.ledger_order IS NOT NULL)),0)
 FROM production_material_demands demand WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
  AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED');
$$;

CREATE FUNCTION fn_execution_full_kit_checkpoint_valid(p_segment UUID,p_stock_order BIGINT DEFAULT NULL) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 WITH current_demands AS MATERIALIZED (
  SELECT demand.id,fn_material_full_kit_identity(demand.id) AS identity_snapshot
  FROM production_material_demands demand WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
   AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED')
 )
 SELECT EXISTS(SELECT 1 FROM production_material_full_kit_proofs proof
  JOIN production_execution_segments segment ON segment.id=proof.execution_segment_id AND NOT segment.is_deleted
  WHERE proof.execution_segment_id=p_segment AND proof.rules_version=1 AND proof.planned_qty=segment.planned_qty
   AND (p_stock_order IS NULL OR proof.source_stock_order=p_stock_order)
   AND (SELECT COUNT(*) FROM current_demands)>0
   AND (SELECT COUNT(*) FROM production_material_full_kit_proof_items item WHERE item.proof_id=proof.id)
       =(SELECT COUNT(*) FROM current_demands)
   AND NOT EXISTS(SELECT 1 FROM current_demands demand
    LEFT JOIN production_material_full_kit_proof_items item ON item.proof_id=proof.id AND item.demand_id=demand.id
    WHERE item.demand_id IS NULL OR item.identity_snapshot IS DISTINCT FROM demand.identity_snapshot
     OR fn_demand_material_output_capacity(demand.id,GREATEST(item.supported_qty-COALESCE((
       SELECT SUM(reversed.qty_base) FROM production_material_stock_postings reversed
       JOIN production_material_stock_postings original ON original.id=reversed.source_posting_id AND original.posting_type='ISSUE'
       WHERE reversed.demand_id=demand.id AND reversed.posting_type='ISSUE_REVERSE'
        AND reversed.ledger_order>proof.ledger_order
        AND (original.ledger_order IS NULL OR original.ledger_order<proof.ledger_order)),0),0))<proof.planned_qty));
$$;

CREATE FUNCTION fn_guard_material_full_kit_proof() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE planned NUMERIC; owner_segment UUID;
BEGIN
 IF TG_TABLE_NAME='production_material_full_kit_proofs' THEN
  SELECT planned_qty INTO planned FROM production_execution_segments WHERE id=NEW.execution_segment_id AND NOT is_deleted;
  IF NEW.rules_version<>1 OR NEW.planned_qty IS DISTINCT FROM planned
    OR NEW.source_stock_order IS DISTINCT FROM fn_material_kit_stock_order(NEW.execution_segment_id)
    OR COALESCE(fn_execution_material_output_capacity(NEW.execution_segment_id,TRUE),0)<planned THEN
   RAISE EXCEPTION 'A full-kit checkpoint requires the current complete frozen material capacity' USING ERRCODE='23514';
  END IF;
  NEW.ledger_order:=nextval('production_material_stock_posting_order_seq');
  NEW.created_transaction:=pg_current_xact_id();
 ELSE
  SELECT proof.execution_segment_id,proof.planned_qty INTO owner_segment,planned
   FROM production_material_full_kit_proofs proof WHERE proof.id=NEW.proof_id AND proof.created_transaction=pg_current_xact_id();
  IF owner_segment IS NULL OR NOT EXISTS(SELECT 1 FROM production_material_demands demand
       WHERE demand.id=NEW.demand_id AND demand.execution_segment_id=owner_segment AND NOT demand.is_deleted
        AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED'))
    OR NEW.identity_snapshot IS DISTINCT FROM fn_material_full_kit_identity(NEW.demand_id)
    OR NEW.supported_qty IS DISTINCT FROM fn_execution_material_net_issued_qty(NEW.demand_id)
    OR fn_demand_material_output_capacity(NEW.demand_id,NEW.supported_qty)<planned THEN
   RAISE EXCEPTION 'Full-kit checkpoint material identities and exact supporting quantities must match this transaction' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_material_full_kit_proof BEFORE INSERT ON production_material_full_kit_proofs FOR EACH ROW EXECUTE FUNCTION fn_guard_material_full_kit_proof();
CREATE TRIGGER trg_guard_material_full_kit_proof_item BEFORE INSERT ON production_material_full_kit_proof_items FOR EACH ROW EXECUTE FUNCTION fn_guard_material_full_kit_proof();
CREATE TRIGGER trg_material_full_kit_proof_immutable BEFORE UPDATE OR DELETE ON production_material_full_kit_proofs FOR EACH ROW EXECUTE FUNCTION fn_reject_production_material_ledger_mutation();
CREATE TRIGGER trg_material_full_kit_proof_item_immutable BEFORE UPDATE OR DELETE ON production_material_full_kit_proof_items FOR EACH ROW EXECUTE FUNCTION fn_reject_production_material_ledger_mutation();
ALTER TABLE production_material_full_kit_proofs ENABLE ALWAYS TRIGGER trg_guard_material_full_kit_proof;
ALTER TABLE production_material_full_kit_proof_items ENABLE ALWAYS TRIGGER trg_guard_material_full_kit_proof_item;
ALTER TABLE production_material_full_kit_proofs ENABLE ALWAYS TRIGGER trg_material_full_kit_proof_immutable;
ALTER TABLE production_material_full_kit_proof_items ENABLE ALWAYS TRIGGER trg_material_full_kit_proof_item_immutable;

-- Called only at existing locked mutation boundaries, once per affected segment.
-- It takes no new locks and never changes an accepted material or output fact.
CREATE FUNCTION fn_capture_execution_full_material_kit(p_segment UUID) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE segment production_execution_segments%ROWTYPE; proof_id UUID; source_order BIGINT;
BEGIN
 SELECT * INTO segment FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted;
 source_order:=fn_material_kit_stock_order(p_segment);
 IF NOT FOUND OR segment.material_requirement_mode='ZERO_MATERIAL'
  OR fn_execution_full_kit_checkpoint_valid(p_segment,source_order)
  OR COALESCE(fn_execution_material_output_capacity(p_segment,TRUE),0)<segment.planned_qty
  OR NOT EXISTS(SELECT 1 FROM production_material_demands WHERE execution_segment_id=p_segment AND NOT is_deleted
      AND material_increment_request_id IS NULL AND status NOT IN('RELEASED','REVERSED')) THEN RETURN FALSE; END IF;
 INSERT INTO production_material_full_kit_proofs(execution_segment_id,planned_qty,rules_version,source_stock_order)
 VALUES(p_segment,segment.planned_qty,1,source_order) RETURNING id INTO proof_id;
 INSERT INTO production_material_full_kit_proof_items(proof_id,demand_id,supported_qty,identity_snapshot)
 SELECT proof_id,demand.id,fn_execution_material_net_issued_qty(demand.id),fn_material_full_kit_identity(demand.id)
 FROM production_material_demands demand WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
  AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED');
 RETURN TRUE;
END;
$$;

CREATE FUNCTION fn_execution_partial_material_report_room(p_segment UUID,p_exclude_report UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE segment production_execution_segments%ROWTYPE; capacity NUMERIC; occupied NUMERIC; single_kit BOOLEAN;
BEGIN
 SELECT * INTO segment FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted;
 IF NOT FOUND THEN RETURN 0; END IF;
 IF segment.material_requirement_mode='ZERO_MATERIAL' THEN RETURN NULL; END IF;
 capacity:=COALESCE(fn_execution_material_output_capacity(segment.id,TRUE),0);
 IF capacity>=segment.planned_qty OR fn_execution_full_kit_checkpoint_valid(p_segment) THEN RETURN NULL; END IF;
 -- Legacy timestamps do not prove chronology. A complete single physical ISSUE
 -- is independently provable; multiple unknown events are never added into a guessed peak.
 WITH demands AS MATERIALIZED (
  SELECT demand.id,CASE WHEN demand.consumption_snapshot IS NOT NULL THEN
       LEAST(demand.required_qty,fn_material_snapshot_required(demand.consumption_snapshot,segment.planned_qty))
     WHEN demand.requirement_mode='LINEAR' AND demand.per_product_qty>0 THEN LEAST(demand.required_qty,demand.per_product_qty*segment.planned_qty)
     ELSE demand.required_qty END AS full_threshold
  FROM production_material_demands demand WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
    AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED')
 ), legacy_issue AS MATERIALIZED (
  SELECT original.event_id,original.demand_id,SUM(original.qty_base-COALESCE((SELECT SUM(reversed.qty_base)
    FROM production_material_stock_postings reversed WHERE reversed.source_posting_id=original.id AND reversed.posting_type='ISSUE_REVERSE'),0)) AS qty
  FROM production_material_stock_postings original JOIN demands ON demands.id=original.demand_id
  WHERE original.posting_type='ISSUE' AND original.ledger_order IS NULL GROUP BY original.event_id,original.demand_id
 )
 SELECT EXISTS(SELECT 1 FROM legacy_issue issue JOIN demands ON demands.id=issue.demand_id
  GROUP BY issue.event_id HAVING COUNT(*)=(SELECT COUNT(*) FROM demands) AND bool_and(issue.qty>=demands.full_threshold)) INTO single_kit;
 IF single_kit THEN RETURN NULL; END IF;
 SELECT COALESCE(SUM(item.qty),0) INTO occupied FROM production_daily_report_items item
 JOIN production_daily_reports report ON report.id=item.report_id
 WHERE item.execution_segment_id=p_segment AND item.fqc_recovery_authorization_id IS NULL
  AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1)
  AND (p_exclude_report IS NULL OR report.id<>p_exclude_report);
 RETURN GREATEST(capacity-occupied,0);
END;
$$;
COMMENT ON FUNCTION fn_execution_partial_material_report_room(UUID,UUID) IS
 'Current verifiable frozen material capacity less active ordinary output; full-kit exemption needs an immutable owner checkpoint or a proven single legacy ISSUE. NULL is no extra ceiling; missing historical proof remains conservative.';

-- Preserve the owning ledger's existing role boundary, including installations
-- with separate migration/runtime roles and restricted default privileges.
REVOKE ALL ON production_material_full_kit_proofs,production_material_full_kit_proof_items FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_capture_execution_full_material_kit(UUID) FROM PUBLIC;
DO $proof_permissions$
DECLARE permission RECORD; role_sql TEXT;
BEGIN
 FOR permission IN SELECT DISTINCT acl.grantee,acl.privilege_type FROM pg_class relation
  CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl,acldefault('r',relation.relowner))) acl
  WHERE relation.oid='production_material_stock_postings'::regclass AND acl.privilege_type IN('SELECT','INSERT')
 LOOP
  role_sql:=CASE WHEN permission.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(permission.grantee)) END;
  IF permission.privilege_type='SELECT' THEN
   EXECUTE 'GRANT SELECT ON production_material_full_kit_proofs,production_material_full_kit_proof_items TO '||role_sql;
  ELSE
   EXECUTE 'GRANT INSERT ON production_material_full_kit_proofs,production_material_full_kit_proof_items TO '||role_sql;
   EXECUTE 'GRANT EXECUTE ON FUNCTION fn_capture_execution_full_material_kit(UUID) TO '||role_sql;
  END IF;
 END LOOP;
END;
$proof_permissions$;
