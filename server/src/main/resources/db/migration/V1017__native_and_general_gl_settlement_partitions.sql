-- One GL remains authoritative. These predicates allocate ownership of its
-- existing source facts; they do not add another amount balance or hide GL.
-- A later, explicitly reviewed legacy binding may own only part of an opening
-- allocation. Keep this read contract empty until that owner registers proof.
CREATE VIEW v_finance_native_partial_gl_allocations AS
 SELECT entry_id,allocation_no,amount_local,amount_original FROM finance_gl_entry_allocations WHERE false;
CREATE FUNCTION fn_finance_gl_settlement_general_local(p_entry uuid,p_allocation integer)RETURNS numeric
 LANGUAGE sql STABLE AS $$
 SELECT allocation.amount_local-COALESCE(assigned.amount_local,0)
 FROM finance_gl_entry_allocations allocation LEFT JOIN v_finance_native_partial_gl_allocations assigned
  ON assigned.entry_id=allocation.entry_id AND assigned.allocation_no=allocation.allocation_no
 WHERE allocation.entry_id=p_entry AND allocation.allocation_no=p_allocation
$$;
CREATE FUNCTION fn_finance_gl_settlement_general_original(p_entry uuid,p_allocation integer)RETURNS numeric
 LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN assigned.entry_id IS NOT NULL AND assigned.amount_original IS NULL THEN NULL
  ELSE allocation.amount_original-COALESCE(assigned.amount_original,0) END
 FROM finance_gl_entry_allocations allocation LEFT JOIN v_finance_native_partial_gl_allocations assigned
  ON assigned.entry_id=allocation.entry_id AND assigned.allocation_no=allocation.allocation_no
 WHERE allocation.entry_id=p_entry AND allocation.allocation_no=p_allocation
$$;
CREATE FUNCTION fn_finance_gl_settlement_native_prepayment_owner(p_kind text)RETURNS boolean
 LANGUAGE sql IMMUTABLE AS $$
 SELECT COALESCE(p_kind IN('SUPPLIER_ADVANCE_APPLICATION','SUPPLIER_ADVANCE_REFUND'),false)
$$;
CREATE FUNCTION fn_finance_gl_settlement_allocation_eligible(p_entry uuid,p_allocation integer,p_native_prepayment boolean)RETURNS boolean
 LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN p_native_prepayment THEN EXISTS(
   SELECT 1 FROM v_finance_native_prepayment_gl_allocations source WHERE source.entry_id=p_entry AND source.allocation_no=p_allocation)
 ELSE NOT EXISTS(
   SELECT 1 FROM v_finance_native_managed_gl_allocations source WHERE source.entry_id=p_entry AND source.allocation_no=p_allocation)
 END
$$;

-- Keep the existing lock, real GL and every dated reservation boundary. Split
-- the floor by the exact source predicate also used by the Java preview.
DO $partition_existing_gl_floor$
DECLARE definition text;anchor text;
BEGIN
 SELECT replace(pg_get_functiondef('fn_finance_gl_settlement_floor()'::regprocedure),E'\r\n',E'\n') INTO definition;
 anchor:='styles uuid[];scope_ids uuid[];style uuid;dirty record;';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed GL floor declarations';END IF;
 definition:=replace(definition,anchor,anchor||'native_policy boolean;');
 anchor:='ELSIF TG_TABLE_NAME=''finance_gl_entry_allocations'' THEN';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed GL floor allocation dispatch';END IF;
 definition:=replace(definition,anchor,'ELSIF TG_TABLE_NAME=''finance_native_legacy_opening_parts'' THEN SELECT array_agg(DISTINCT style_id) INTO styles FROM gl_entries WHERE id IN((to_jsonb(OLD)->>''entry_id'')::uuid,(to_jsonb(NEW)->>''entry_id'')::uuid);'||E'\n '||anchor);
 anchor:='PERFORM fn_finance_gl_settlement_scope_lock(s.id);';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed GL floor scope locking';END IF;
 definition:=replace(definition,anchor,anchor||E'\n  FOR native_policy IN SELECT policy FROM(VALUES(false),(true)) policies(policy) LOOP\n   IF NOT EXISTS(SELECT 1 FROM finance_gl_settlement_reservations reservation WHERE reservation.scope_id=s.id AND reservation.status=''RESERVED'' AND fn_finance_gl_settlement_native_prepayment_owner(reservation.owner_kind)=native_policy) THEN CONTINUE;END IF;');
 anchor:='SELECT COALESCE(sum(e.direction*a.amount_local*s.natural_direction),0),COALESCE(sum(e.direction*a.amount_original*s.natural_direction),0)';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed GL floor amount projection';END IF;
 definition:=replace(definition,anchor,'SELECT COALESCE(sum(e.direction*(CASE WHEN native_policy THEN a.amount_local ELSE fn_finance_gl_settlement_general_local(e.id,a.allocation_no) END)*s.natural_direction),0),COALESCE(sum(e.direction*(CASE WHEN native_policy THEN a.amount_original ELSE fn_finance_gl_settlement_general_original(e.id,a.allocation_no) END)*s.natural_direction),0)');
 anchor:='OR (a.auxiliary_id IS NOT DISTINCT FROM s.auxiliary_id AND a.currency_id=s.accounting_currency_id';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed GL floor unknown facts';END IF;
 definition:=replace(definition,anchor,'OR (NOT native_policy AND a.auxiliary_id IS NOT DISTINCT FROM s.auxiliary_id AND a.currency_id=s.accounting_currency_id AND a.original_currency_id=s.original_currency_id AND fn_finance_gl_settlement_allocation_eligible(e.id,a.allocation_no,false) AND(fn_finance_gl_settlement_general_local(e.id,a.allocation_no) IS NULL OR fn_finance_gl_settlement_general_original(e.id,a.allocation_no) IS NULL)) '||anchor);
 anchor:='AND fn_finance_gl_voucher_is_booked(v.id) AND e.entry_date<=boundary.as_of;';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed GL floor actual source query';END IF;
 definition:=replace(definition,anchor,'AND fn_finance_gl_voucher_is_booked(v.id) AND e.entry_date<=boundary.as_of AND fn_finance_gl_settlement_allocation_eligible(e.id,a.allocation_no,native_policy);');
 anchor:='FROM finance_gl_settlement_reservations WHERE scope_id=s.id AND status=''RESERVED'' AND as_of<=boundary.as_of;';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed GL floor reservation query';END IF;
 definition:=replace(definition,anchor,'FROM finance_gl_settlement_reservations WHERE scope_id=s.id AND status=''RESERVED'' AND as_of<=boundary.as_of AND fn_finance_gl_settlement_native_prepayment_owner(owner_kind)=native_policy;');
 anchor:=E'  END LOOP;\n  UPDATE pg_temp.finance_gl_settlement_dirty';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed GL floor loop boundary';END IF;
 definition:=replace(definition,anchor,E'  END LOOP;\n  END LOOP;\n  UPDATE pg_temp.finance_gl_settlement_dirty');
 EXECUTE definition;
END; $partition_existing_gl_floor$;

CREATE FUNCTION fn_guard_finance_gl_settlement_partition()RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE reservation finance_gl_settlement_reservations%ROWTYPE;native_policy boolean;source_entry uuid;source_allocation integer;
BEGIN
 SELECT * INTO reservation FROM finance_gl_settlement_reservations WHERE id=NEW.reservation_id;
 native_policy:=fn_finance_gl_settlement_native_prepayment_owner(reservation.owner_kind);
 IF native_policy AND reservation.mode<>'EXPLICIT_GL_SOURCE' THEN
  RAISE EXCEPTION '原生预付须按真实资产原GL分录逐源清偿，不能使用通用余额池' USING ERRCODE='23514';END IF;
 IF TG_TABLE_NAME='finance_gl_settlement_source_parts' THEN source_entry:=NEW.entry_id;source_allocation:=NEW.allocation_no;
 ELSE source_entry:=NEW.source_entry_id;source_allocation:=NEW.source_allocation_no;END IF;
 IF source_entry IS NOT NULL AND NOT fn_finance_gl_settlement_allocation_eligible(source_entry,source_allocation,native_policy) THEN
  RAISE EXCEPTION '该GL来源由原业务管理，不能在另一清偿通道重复认领' USING ERRCODE='23514';END IF;
 IF TG_TABLE_NAME='finance_gl_settlement_clearings' THEN
  IF native_policy THEN
   IF NOT EXISTS(SELECT 1 FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id
     WHERE entry.id=NEW.entry_id AND voucher.source='AUTO' AND voucher.source_type=reservation.owner_kind
       AND entry.source_doc_type=reservation.owner_kind AND entry.source_doc_id=reservation.owner_id) THEN
    RAISE EXCEPTION '原生预付实际清偿须属于该应用或退款自己的真实凭证' USING ERRCODE='23514';END IF;
  ELSIF NOT fn_finance_gl_settlement_allocation_eligible(NEW.entry_id,NEW.allocation_no,false) THEN
   RAISE EXCEPTION '原生往来或现金分录不能再次用于通用清偿' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER finance_gl_settlement_source_partition AFTER INSERT ON finance_gl_settlement_source_parts
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_gl_settlement_partition();
CREATE CONSTRAINT TRIGGER finance_gl_settlement_clearing_partition AFTER INSERT ON finance_gl_settlement_clearings
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_gl_settlement_partition();
