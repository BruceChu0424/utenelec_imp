-- Public on-hand adoption is a stock-balance reservation, never an invented IQC
-- receipt or manufacture origin. Its exact material identity survives MRP handoff.
CREATE TABLE preplan_physical_stock_claim_commands (
 id uuid PRIMARY KEY, analysis_id uuid NOT NULL REFERENCES production_material_analyses(id),
 idempotency_key text NOT NULL UNIQUE, request_hash text NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL REFERENCES users(id)
);
CREATE INDEX idx_preplan_physical_claim_analysis ON preplan_physical_stock_claim_commands(analysis_id);
CREATE INDEX idx_preplan_physical_claim_actor ON preplan_physical_stock_claim_commands(created_by);
CREATE TABLE preplan_physical_stock_claim_allocations (
 id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
 stock_reservation_id uuid PRIMARY KEY REFERENCES stock_reservations(id),
 command_id uuid NOT NULL REFERENCES preplan_physical_stock_claim_commands(id),
 material_id uuid NOT NULL REFERENCES production_material_analysis_materials(id),
 qty numeric(18,4) NOT NULL CHECK(qty>0), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_preplan_physical_claim_command ON preplan_physical_stock_claim_allocations(command_id);
CREATE INDEX idx_preplan_physical_claim_material ON preplan_physical_stock_claim_allocations(material_id);
CREATE TABLE preplan_physical_stock_formalizations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 source_reservation_id uuid NOT NULL REFERENCES stock_reservations(id),
 source_analysis_id uuid NOT NULL REFERENCES production_material_analyses(id),
 source_material_id uuid NOT NULL REFERENCES production_material_analysis_materials(id),
 target_reservation_id uuid NOT NULL REFERENCES stock_reservations(id),
 package_id uuid NOT NULL REFERENCES production_planning_packages(id),
 demand_id uuid NOT NULL REFERENCES production_material_demands(id),
 qty numeric(18,4) NOT NULL CHECK(qty>0), idempotency_key text NOT NULL UNIQUE,
 created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES users(id),
 restored_at timestamptz, restored_by uuid REFERENCES users(id),
 CHECK((restored_at IS NULL)=(restored_by IS NULL))
);
CREATE INDEX idx_preplan_physical_formal_source ON preplan_physical_stock_formalizations(source_reservation_id);
CREATE INDEX idx_preplan_physical_formal_material ON preplan_physical_stock_formalizations(source_material_id);
CREATE INDEX idx_preplan_physical_formal_analysis ON preplan_physical_stock_formalizations(source_analysis_id);
CREATE INDEX idx_preplan_physical_formal_target ON preplan_physical_stock_formalizations(target_reservation_id);
CREATE INDEX idx_preplan_physical_formal_package ON preplan_physical_stock_formalizations(package_id);
CREATE INDEX idx_preplan_physical_formal_demand ON preplan_physical_stock_formalizations(demand_id);
CREATE INDEX idx_preplan_physical_formal_actor ON preplan_physical_stock_formalizations(created_by);
CREATE INDEX idx_preplan_physical_restore_actor ON preplan_physical_stock_formalizations(restored_by);

DO $physical_owner$
DECLARE definition text;
BEGIN
 SELECT pg_get_expr(conbin,conrelid) INTO STRICT definition FROM pg_constraint
 WHERE conrelid='stock_reservations'::regclass AND conname='stock_reservations_owner_shape_chk';
 EXECUTE format('ALTER TABLE stock_reservations DROP CONSTRAINT stock_reservations_owner_shape_chk,
 ADD CONSTRAINT stock_reservations_owner_shape_chk CHECK((%s) OR (
 owner_type=''PREPLAN_ANALYSIS'' AND purpose=''PREPLAN_MATERIAL'' AND owner_id IS NOT NULL
 AND order_item_id IS NULL AND demand_id IS NULL AND warehouse_id IS NOT NULL
 AND source=3 AND source_doc_type=''PREPLAN_STOCK_BALANCE'' AND source_doc_id IS NOT NULL
 AND supply_type=''STOCK_BALANCE'' AND supply_id=source_doc_id AND idempotency_key IS NOT NULL))',definition);
END $physical_owner$;

CREATE FUNCTION fn_guard_preplan_physical_stock_reservation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE material production_material_analysis_materials%ROWTYPE; analysis production_material_analyses%ROWTYPE;
 free_qty numeric; main_free_qty numeric; increase numeric;
BEGIN
 IF TG_OP='UPDATE' AND OLD.source_doc_type='PREPLAN_STOCK_BALANCE' AND
  (OLD.id,OLD.owner_type,OLD.owner_id,OLD.purpose,OLD.goods_id,OLD.color_id,OLD.warehouse_id,OLD.qty,
   OLD.source,OLD.source_doc_type,OLD.source_doc_id,OLD.supply_type,OLD.supply_id,OLD.idempotency_key)
  IS DISTINCT FROM
  (NEW.id,NEW.owner_type,NEW.owner_id,NEW.purpose,NEW.goods_id,NEW.color_id,NEW.warehouse_id,NEW.qty,
   NEW.source,NEW.source_doc_type,NEW.source_doc_id,NEW.supply_type,NEW.supply_id,NEW.idempotency_key) THEN
  RAISE EXCEPTION 'public physical adoption identity is immutable' USING ERRCODE='23514';
 END IF;
 IF NEW.source_doc_type IS DISTINCT FROM 'PREPLAN_STOCK_BALANCE' THEN RETURN NEW; END IF;
 SELECT * INTO STRICT material FROM production_material_analysis_materials WHERE id=NEW.supply_id;
 SELECT * INTO STRICT analysis FROM production_material_analyses WHERE id=material.analysis_id;
 IF NEW.owner_type<>'PREPLAN_ANALYSIS' OR NEW.owner_id<>material.analysis_id OR NEW.purpose<>'PREPLAN_MATERIAL'
  OR NEW.source<>3 OR NEW.source_doc_id<>material.id OR NEW.supply_type<>'STOCK_BALANCE'
  OR NEW.goods_id<>material.goods_id OR NEW.color_id IS DISTINCT FROM material.color_id
  OR material.node_role='ROOT_SUPPLY' OR NOT fn_warehouse_is_good_stock_leaf(NEW.warehouse_id)
  OR NOT fn_warehouse_same_main(NEW.warehouse_id,analysis.warehouse_id) THEN
  RAISE EXCEPTION 'public physical adoption requires its exact material and good-stock leaf' USING ERRCODE='23514';
 END IF;
 increase:=CASE WHEN NEW.is_deleted OR NEW.status<>0 THEN 0 ELSE NEW.qty-NEW.consumed_qty-NEW.released_qty END;
 IF TG_OP='UPDATE' THEN increase:=increase-CASE WHEN OLD.is_deleted OR OLD.status<>0 THEN 0 ELSE OLD.qty-OLD.consumed_qty-OLD.released_qty END; END IF;
 IF increase>0 THEN
  IF analysis.is_deleted OR analysis.status NOT IN('ACTIVE','PARTIALLY_PLANNED') OR NOT material.active THEN
   RAISE EXCEPTION 'public physical adoption source is inactive' USING ERRCODE='23514';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.goods_id::text||':'||COALESCE(NEW.color_id,'00000000-0000-0000-0000-000000000000'::uuid)::text,6148615593807138892));
  SELECT GREATEST(COALESCE(stock.qty,0)
    -COALESCE((SELECT SUM(r.qty-r.consumed_qty-r.released_qty) FROM stock_reservations r
      WHERE r.goods_id=NEW.goods_id AND r.color_id IS NOT DISTINCT FROM NEW.color_id
        AND r.warehouse_id=NEW.warehouse_id
        AND r.status=0 AND NOT r.is_deleted AND r.id<>NEW.id),0),0) INTO free_qty
  FROM goods LEFT JOIN v_stock_operable_balances stock ON stock.goods_id=goods.id
    AND stock.color_id IS NOT DISTINCT FROM NEW.color_id AND stock.warehouse_id=NEW.warehouse_id
  WHERE goods.id=NEW.goods_id;
  SELECT GREATEST(COALESCE((SELECT SUM(GREATEST(stock.qty-COALESCE((
    SELECT SUM(r.qty-r.consumed_qty-r.released_qty) FROM stock_reservations r
    WHERE r.goods_id=NEW.goods_id AND r.color_id IS NOT DISTINCT FROM NEW.color_id
      AND r.warehouse_id=stock.warehouse_id AND r.status=0 AND NOT r.is_deleted AND r.id<>NEW.id),0),0))
    FROM v_stock_operable_balances stock WHERE stock.goods_id=NEW.goods_id
      AND stock.color_id IS NOT DISTINCT FROM NEW.color_id
      AND fn_warehouse_same_main(stock.warehouse_id,analysis.warehouse_id)
      AND fn_warehouse_is_good_stock_leaf(stock.warehouse_id)),0)
    -GREATEST(COALESCE(goods.min_qty,0),0)-COALESCE((SELECT SUM(r.qty-r.consumed_qty-r.released_qty)
      FROM stock_reservations r WHERE r.goods_id=NEW.goods_id AND r.color_id IS NOT DISTINCT FROM NEW.color_id
        AND r.warehouse_id IS NULL AND r.status=0 AND NOT r.is_deleted),0),0) INTO main_free_qty
  FROM goods WHERE goods.id=NEW.goods_id;
  IF NEW.qty-NEW.consumed_qty-NEW.released_qty>LEAST(COALESCE(free_qty,0),COALESCE(main_free_qty,0)) THEN
   RAISE EXCEPTION 'public physical adoption exceeds unreserved stock above safety' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_preplan_physical_stock_reservation BEFORE INSERT ON stock_reservations
 FOR EACH ROW WHEN(NEW.source_doc_type='PREPLAN_STOCK_BALANCE')
 EXECUTE FUNCTION fn_guard_preplan_physical_stock_reservation();
CREATE TRIGGER trg_guard_preplan_physical_stock_reservation_upd BEFORE UPDATE ON stock_reservations
 FOR EACH ROW WHEN(NEW.source_doc_type='PREPLAN_STOCK_BALANCE' OR OLD.source_doc_type='PREPLAN_STOCK_BALANCE')
 EXECUTE FUNCTION fn_guard_preplan_physical_stock_reservation();

CREATE FUNCTION fn_check_preplan_physical_claim_proof() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM preplan_physical_stock_claim_allocations allocation
  JOIN preplan_physical_stock_claim_commands command ON command.id=allocation.command_id
  WHERE allocation.stock_reservation_id=NEW.id AND allocation.material_id=NEW.supply_id
    AND allocation.qty=NEW.qty AND command.analysis_id=NEW.owner_id) THEN
  RAISE EXCEPTION 'public physical adoption lacks its original command allocation' USING ERRCODE='23514';
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_check_preplan_physical_claim_proof AFTER INSERT ON stock_reservations
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(NEW.source_doc_type='PREPLAN_STOCK_BALANCE')
 EXECUTE FUNCTION fn_check_preplan_physical_claim_proof();

CREATE FUNCTION fn_guard_preplan_physical_claim_ledger() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'physical adoption commands and allocations are append-only' USING ERRCODE='23514'; END IF;
 IF TG_TABLE_NAME='preplan_physical_stock_claim_allocations' THEN
 IF NOT EXISTS(
  SELECT 1 FROM stock_reservations r JOIN preplan_physical_stock_claim_commands c ON c.id=NEW.command_id
  WHERE r.id=NEW.stock_reservation_id AND r.source_doc_type='PREPLAN_STOCK_BALANCE'
    AND r.owner_id=c.analysis_id AND r.supply_id=NEW.material_id AND r.qty=NEW.qty) THEN
  RAISE EXCEPTION 'physical adoption allocation differs from its original source' USING ERRCODE='23514';
 END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_preplan_physical_claim_commands BEFORE INSERT OR UPDATE OR DELETE
 ON preplan_physical_stock_claim_commands FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_physical_claim_ledger();
CREATE TRIGGER trg_guard_preplan_physical_claim_allocations BEFORE INSERT OR UPDATE OR DELETE
 ON preplan_physical_stock_claim_allocations FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_physical_claim_ledger();

CREATE FUNCTION fn_guard_preplan_physical_stock_formalization() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source stock_reservations%ROWTYPE; target stock_reservations%ROWTYPE; plan production_plans%ROWTYPE;
 used numeric;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'physical stock formalization lineage cannot be deleted' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' THEN
  IF OLD.restored_at IS NOT NULL OR NEW.restored_at IS NULL OR NEW.restored_by IS NULL
    OR (to_jsonb(OLD)-'restored_at'-'restored_by') IS DISTINCT FROM (to_jsonb(NEW)-'restored_at'-'restored_by') THEN
   RAISE EXCEPTION 'physical stock formalization only permits one restoration' USING ERRCODE='23514';
  END IF;
 END IF;
 SELECT * INTO STRICT source FROM stock_reservations WHERE id=NEW.source_reservation_id FOR UPDATE;
 SELECT * INTO STRICT target FROM stock_reservations WHERE id=NEW.target_reservation_id FOR UPDATE;
 SELECT p.* INTO STRICT plan FROM production_material_demands demand JOIN production_plans p ON p.id=demand.plan_id WHERE demand.id=NEW.demand_id;
 IF source.source_doc_type<>'PREPLAN_STOCK_BALANCE' OR source.owner_id<>NEW.source_analysis_id
  OR source.supply_id<>NEW.source_material_id OR source.source_doc_id<>NEW.source_material_id
  OR target.owner_type<>'PRODUCTION_MATERIAL_DEMAND' OR target.demand_id<>NEW.demand_id
  OR target.goods_id<>source.goods_id OR target.color_id IS DISTINCT FROM source.color_id
  OR target.warehouse_id IS DISTINCT FROM source.warehouse_id
  OR plan.material_analysis_id IS DISTINCT FROM NEW.source_analysis_id
  OR fn_analysis_plan_material_matches(plan.material_analysis_item_id,NEW.source_material_id) IS NOT TRUE
  OR NOT EXISTS(SELECT 1 FROM production_material_demands demand WHERE demand.id=NEW.demand_id
    AND demand.package_id=NEW.package_id AND demand.plan_id=plan.id) THEN
  RAISE EXCEPTION 'physical stock formalization requires one unchanged material lineage' USING ERRCODE='23514';
 END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.restored_at IS NOT NULL OR NEW.restored_by IS NOT NULL THEN
   RAISE EXCEPTION 'physical stock handoff must begin active' USING ERRCODE='23514';
  END IF;
  SELECT COALESCE(SUM(qty),0) INTO used FROM preplan_physical_stock_formalizations
   WHERE source_reservation_id=source.id AND restored_at IS NULL;
  IF used+NEW.qty>source.released_qty OR source.release_reason<>'TRANSFERRED_TO_PLAN' THEN
   RAISE EXCEPTION 'physical stock handoff exceeds its released source' USING ERRCODE='23514';
  END IF;
  SELECT COALESCE(SUM(qty),0) INTO used FROM preplan_physical_stock_formalizations
   WHERE target_reservation_id=target.id AND restored_at IS NULL;
  IF used+NEW.qty>target.qty-target.released_qty THEN
   RAISE EXCEPTION 'physical stock handoff exceeds its formal target' USING ERRCODE='23514';
  END IF;
 ELSIF target.consumed_qty<>0 OR target.released_qty<target.qty THEN
  RAISE EXCEPTION 'physical stock cannot restore before its unconsumed formal target is released' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_preplan_physical_stock_formalization BEFORE INSERT OR UPDATE OR DELETE
 ON preplan_physical_stock_formalizations FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_physical_stock_formalization();
CREATE TRIGGER trg_audit_preplan_physical_stock_claim_commands AFTER INSERT OR UPDATE OR DELETE ON preplan_physical_stock_claim_commands
 FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_physical_stock_claim_allocations AFTER INSERT OR UPDATE OR DELETE ON preplan_physical_stock_claim_allocations
 FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_physical_stock_formalizations AFTER INSERT OR UPDATE OR DELETE ON preplan_physical_stock_formalizations
 FOR EACH ROW EXECUTE FUNCTION fn_audit();
