-- Forward-only extension of the committed authorization event ledger. V935-V937 remain unchanged.
ALTER TABLE read_scope_domains DROP CONSTRAINT read_scope_domains_domain_check;
ALTER TABLE read_scope_domains ADD CONSTRAINT read_scope_domains_domain_check CHECK (domain IN (
    'sales','purchase','subcontract','production','stock','finance','client','supplier',
    'master_goods','master_account','master_currency','master_color','master_unit','master_mould','master_warehouse','master_settlement_method'));
INSERT INTO read_scope_domains(domain) VALUES
    ('master_goods'),('master_account'),('master_currency'),('master_color'),
    ('master_unit'),('master_mould'),('master_warehouse'),('master_settlement_method');

-- The immutable domain catalog is the single allow-list. Equality markers only
-- deduplicate one transaction; the version remains COUNT of all committed events.
CREATE OR REPLACE FUNCTION fn_record_read_scope_change(p_domain text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE marker text:=txid_current()::text;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.read_scope_domains WHERE domain=p_domain) THEN
        RAISE EXCEPTION 'Unknown read scope domain' USING ERRCODE='22023';
    END IF;
    IF current_setting('uten.read_scope_'||p_domain,true)=marker THEN RETURN; END IF;
    INSERT INTO public.read_scope_change_events(domain,change_txid)
      VALUES(p_domain,txid_current()) ON CONFLICT DO NOTHING;
    PERFORM set_config('uten.read_scope_'||p_domain,marker,true);
END $$;
REVOKE ALL ON FUNCTION fn_record_read_scope_change(text) FROM PUBLIC;

CREATE TRIGGER trg_read_scope_goods_owner AFTER UPDATE OF owner_employee_id ON goods
FOR EACH ROW WHEN (OLD.owner_employee_id IS DISTINCT FROM NEW.owner_employee_id)
EXECUTE FUNCTION fn_mark_read_scope_domains('master_goods');
ALTER TABLE goods ENABLE ALWAYS TRIGGER trg_read_scope_goods_owner;

-- These are feature-wide directories, not warehouse-task/keeper or purchasing-owner scopes.
DO $$ DECLARE pair text[]; BEGIN
    FOREACH pair SLICE 1 IN ARRAY ARRAY[
        ['goods','master_goods'],['accounts','master_account'],['currencies','master_currency'],
        ['colors','master_color'],['units','master_unit'],['moulds','master_mould'],['warehouses','master_warehouse'],['settlement_methods','master_settlement_method']]
    LOOP
        EXECUTE format('CREATE TRIGGER trg_read_scope_master_qualification AFTER UPDATE OF is_deleted ON public.%I FOR EACH ROW WHEN (OLD.is_deleted IS DISTINCT FROM NEW.is_deleted) EXECUTE FUNCTION public.fn_mark_read_scope_domains(%L)',pair[1],pair[2]);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_read_scope_master_qualification',pair[1]);
    END LOOP;
END $$;

CREATE FUNCTION fn_mark_master_goods_grants() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
        n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
BEGIN
    IF TG_TABLE_SCHEMA<>'public' OR TG_TABLE_NAME<>'user_data_scopes' THEN
        RAISE EXCEPTION 'Invalid master scope source' USING ERRCODE='55000';
    END IF;
    IF TG_OP='UPDATE' AND ROW(o->>'user_id',o->>'scope',o->>'owner_employee_id',o->>'owner_employment_generation')
        IS NOT DISTINCT FROM ROW(n->>'user_id',n->>'scope',n->>'owner_employee_id',n->>'owner_employment_generation') THEN RETURN NULL; END IF;
    IF o->>'scope'='goods' OR n->>'scope'='goods' THEN
        PERFORM public.fn_record_read_scope_change('master_goods');
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_read_scope_master_goods_grants AFTER INSERT OR UPDATE OR DELETE ON user_data_scopes
FOR EACH ROW EXECUTE FUNCTION fn_mark_master_goods_grants();
ALTER TABLE user_data_scopes ENABLE ALWAYS TRIGGER trg_read_scope_master_goods_grants;
CREATE TRIGGER trg_read_scope_master_goods_grants_truncate AFTER TRUNCATE ON user_data_scopes
FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_read_scope_domains('master_goods');
ALTER TABLE user_data_scopes ENABLE ALWAYS TRIGGER trg_read_scope_master_goods_grants_truncate;

CREATE TRIGGER trg_read_scope_goods_employee_deleted AFTER UPDATE OF is_deleted ON employees
FOR EACH ROW WHEN (OLD.is_deleted IS DISTINCT FROM NEW.is_deleted)
EXECUTE FUNCTION fn_mark_read_scope_domains('master_goods');
ALTER TABLE employees ENABLE ALWAYS TRIGGER trg_read_scope_goods_employee_deleted;

CREATE FUNCTION fn_mark_master_goods_rehire() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
        n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
BEGIN
    IF TG_TABLE_SCHEMA<>'public' OR TG_TABLE_NAME<>'employment_history' THEN
        RAISE EXCEPTION 'Invalid master scope source' USING ERRCODE='55000';
    END IF;
    IF (o->>'event_type'='rehire' OR n->>'event_type'='rehire')
       AND (TG_OP<>'UPDATE' OR ROW(o->>'employee_id',o->>'event_type') IS DISTINCT FROM ROW(n->>'employee_id',n->>'event_type')) THEN
        PERFORM public.fn_record_read_scope_change('master_goods');
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_read_scope_master_goods_rehire AFTER INSERT OR UPDATE OR DELETE ON employment_history
FOR EACH ROW EXECUTE FUNCTION fn_mark_master_goods_rehire();
ALTER TABLE employment_history ENABLE ALWAYS TRIGGER trg_read_scope_master_goods_rehire;

CREATE FUNCTION fn_mark_master_goods_handover() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
        n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
BEGIN
    IF TG_TABLE_SCHEMA<>'public' OR TG_TABLE_NAME NOT IN ('employee_data_handovers','employee_data_handover_scopes') THEN
        RAISE EXCEPTION 'Invalid master scope source' USING ERRCODE='55000';
    END IF;
    IF TG_TABLE_NAME='employee_data_handovers' THEN
        IF NOT (COALESCE(o->>'status'='COMPLETED',false) OR COALESCE(n->>'status'='COMPLETED',false)) THEN RETURN NULL; END IF;
        IF TG_OP='UPDATE' AND ROW(o->>'status',o->>'source_employee_id',o->>'target_employee_id',o->>'source_employment_generation',o->>'target_employment_generation')
            IS NOT DISTINCT FROM ROW(n->>'status',n->>'source_employee_id',n->>'target_employee_id',n->>'source_employment_generation',n->>'target_employment_generation') THEN RETURN NULL; END IF;
        IF EXISTS(SELECT 1 FROM public.employee_data_handover_scopes WHERE scope='goods'
                  AND handover_id=COALESCE((n->>'id')::uuid,(o->>'id')::uuid)) THEN
            PERFORM public.fn_record_read_scope_change('master_goods');
        END IF;
    ELSE
        IF TG_OP='UPDATE' AND ROW(o->>'handover_id',o->>'scope') IS NOT DISTINCT FROM ROW(n->>'handover_id',n->>'scope') THEN RETURN NULL; END IF;
        -- A deleted child can be in an FK cascade after its parent disappeared;
        -- conservatively retain the goods event instead of losing that revocation.
        IF (TG_OP='DELETE' AND o->>'scope'='goods') OR EXISTS(
            SELECT 1 FROM (VALUES((o->>'handover_id')::uuid,o->>'scope'),((n->>'handover_id')::uuid,n->>'scope')) pair(id,scope)
            JOIN public.employee_data_handovers h ON h.id=pair.id AND h.status='COMPLETED' WHERE pair.scope='goods') THEN
            PERFORM public.fn_record_read_scope_change('master_goods');
        END IF;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_read_scope_master_goods_handover AFTER INSERT OR UPDATE OR DELETE ON employee_data_handovers
FOR EACH ROW EXECUTE FUNCTION fn_mark_master_goods_handover();
CREATE TRIGGER trg_read_scope_master_goods_handover_scopes AFTER INSERT OR UPDATE OR DELETE ON employee_data_handover_scopes
FOR EACH ROW EXECUTE FUNCTION fn_mark_master_goods_handover();
ALTER TABLE employee_data_handovers ENABLE ALWAYS TRIGGER trg_read_scope_master_goods_handover;
ALTER TABLE employee_data_handover_scopes ENABLE ALWAYS TRIGGER trg_read_scope_master_goods_handover_scopes;
