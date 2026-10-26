-- Read authorization has independent data-scope changes; never advance the role epoch
-- (manager delegations bind that epoch). No shared database is altered by local tests.
CREATE TABLE read_scope_domains (
    domain text PRIMARY KEY CHECK (domain IN ('sales','purchase','subcontract','production','stock','finance','client','supplier'))
);
INSERT INTO read_scope_domains(domain) VALUES
    ('sales'),('purchase'),('subcontract'),('production'),('stock'),('finance'),('client'),('supplier');

-- An append per domain/transaction avoids a global counter row after business locks.
-- COUNT includes every committed event, including a transaction that commits late.
-- change_txid is ONLY an equality deduplication key, never a high-water mark.
CREATE TABLE read_scope_change_events (
    domain text NOT NULL REFERENCES read_scope_domains(domain),
    change_txid bigint NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(domain,change_txid)
);
CREATE VIEW read_scope_generations AS
SELECT d.domain,(SELECT count(*) FROM read_scope_change_events e WHERE e.domain=d.domain) AS generation
FROM read_scope_domains d;

CREATE FUNCTION fn_guard_read_scope_event_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF pg_trigger_depth()<2 OR NEW.change_txid<>txid_current() THEN
        RAISE EXCEPTION 'Read scope events are recorded only by authorization source triggers' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_read_scope_event_insert BEFORE INSERT ON read_scope_change_events
FOR EACH ROW EXECUTE FUNCTION fn_guard_read_scope_event_insert();
CREATE TRIGGER trg_read_scope_event_immutable BEFORE UPDATE OR DELETE ON read_scope_change_events
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_read_scope_event_no_truncate BEFORE TRUNCATE ON read_scope_change_events
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_read_scope_domains_immutable BEFORE UPDATE OR DELETE ON read_scope_domains
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_read_scope_domains_no_truncate BEFORE TRUNCATE ON read_scope_domains
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE read_scope_change_events ENABLE ALWAYS TRIGGER trg_read_scope_event_insert;
ALTER TABLE read_scope_change_events ENABLE ALWAYS TRIGGER trg_read_scope_event_immutable;
ALTER TABLE read_scope_change_events ENABLE ALWAYS TRIGGER trg_read_scope_event_no_truncate;
ALTER TABLE read_scope_domains ENABLE ALWAYS TRIGGER trg_read_scope_domains_immutable;
ALTER TABLE read_scope_domains ENABLE ALWAYS TRIGGER trg_read_scope_domains_no_truncate;

CREATE FUNCTION fn_record_read_scope_change(p_domain text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE marker text:=txid_current()::text;
BEGIN
    IF p_domain NOT IN ('sales','purchase','subcontract','production','stock','finance','client','supplier') THEN
        RAISE EXCEPTION 'Unknown read scope domain' USING ERRCODE='22023';
    END IF;
    IF current_setting('uten.read_scope_'||p_domain,true)=marker THEN RETURN; END IF;
    INSERT INTO public.read_scope_change_events(domain,change_txid)
      VALUES(p_domain,txid_current()) ON CONFLICT DO NOTHING;
    PERFORM set_config('uten.read_scope_'||p_domain,marker,true);
END $$;
REVOKE ALL ON FUNCTION fn_record_read_scope_change(text) FROM PUBLIC;

-- Generic ownership watchers are attached only to the columns actually consumed
-- by current OwnerVisibility policies. New documents and amount/status edits do not fire.
CREATE FUNCTION fn_mark_read_scope_domains() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE domain text;
BEGIN
    IF TG_TABLE_SCHEMA<>'public' THEN RAISE EXCEPTION 'Invalid read scope source' USING ERRCODE='55000'; END IF;
    FOREACH domain IN ARRAY TG_ARGV LOOP PERFORM public.fn_record_read_scope_change(domain); END LOOP;
    RETURN NULL;
END $$;

DO $$ DECLARE relation text; BEGIN
    FOREACH relation IN ARRAY ARRAY['sales_orders','sales_shipments','sales_returns','sales_other_shipments'] LOOP
      EXECUTE format('CREATE TRIGGER trg_read_scope_owner AFTER UPDATE OF owner_employee_id ON public.%I FOR EACH ROW WHEN (OLD.owner_employee_id IS DISTINCT FROM NEW.owner_employee_id) EXECUTE FUNCTION public.fn_mark_read_scope_domains(''sales'')',relation);
      EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_read_scope_owner',relation);
    END LOOP;
    FOREACH relation IN ARRAY ARRAY['finance_receipts','finance_payments','finance_expenses','finance_other_incomes'] LOOP
      EXECUTE format('CREATE TRIGGER trg_read_scope_maker AFTER UPDATE OF maker_id ON public.%I FOR EACH ROW WHEN (OLD.maker_id IS DISTINCT FROM NEW.maker_id) EXECUTE FUNCTION public.fn_mark_read_scope_domains(''finance'')',relation);
      EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_read_scope_maker',relation);
    END LOOP;
END $$;
CREATE TRIGGER trg_read_scope_client_owner AFTER UPDATE OF owner_employee_id ON clients
FOR EACH ROW WHEN (OLD.owner_employee_id IS DISTINCT FROM NEW.owner_employee_id)
EXECUTE FUNCTION fn_mark_read_scope_domains('client');
ALTER TABLE clients ENABLE ALWAYS TRIGGER trg_read_scope_client_owner;

CREATE FUNCTION fn_mark_read_scope_grants() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
        n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
        value text;
BEGIN
    IF TG_TABLE_SCHEMA<>'public' THEN RAISE EXCEPTION 'Invalid read scope source' USING ERRCODE='55000'; END IF;
    IF TG_TABLE_NAME='user_data_scopes' THEN
      IF TG_OP='UPDATE' AND ROW(o->>'user_id',o->>'scope',o->>'owner_employee_id',o->>'owner_employment_generation')
          IS NOT DISTINCT FROM ROW(n->>'user_id',n->>'scope',n->>'owner_employee_id',n->>'owner_employment_generation') THEN RETURN NULL; END IF;
      FOR value IN SELECT DISTINCT x FROM unnest(ARRAY[o->>'scope',n->>'scope']) x WHERE x IN ('sales','finance','client') LOOP
        PERFORM public.fn_record_read_scope_change(value);
      END LOOP;
    ELSIF TG_TABLE_NAME='client_visibility_grants' THEN
      IF NOT (COALESCE((o->>'active')::boolean,false) OR COALESCE((n->>'active')::boolean,false)) THEN RETURN NULL; END IF;
      IF TG_OP='UPDATE' AND ROW(o->>'client_id',o->>'grantee_employee_id',o->>'active')
          IS NOT DISTINCT FROM ROW(n->>'client_id',n->>'grantee_employee_id',n->>'active') THEN RETURN NULL; END IF;
      PERFORM public.fn_record_read_scope_change('client');
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_read_scope_grants AFTER INSERT OR UPDATE OR DELETE ON user_data_scopes
FOR EACH ROW EXECUTE FUNCTION fn_mark_read_scope_grants();
CREATE TRIGGER trg_read_scope_client_grants AFTER INSERT OR UPDATE OR DELETE ON client_visibility_grants
FOR EACH ROW EXECUTE FUNCTION fn_mark_read_scope_grants();
ALTER TABLE user_data_scopes ENABLE ALWAYS TRIGGER trg_read_scope_grants;
ALTER TABLE client_visibility_grants ENABLE ALWAYS TRIGGER trg_read_scope_client_grants;

-- Lifecycle identity changes affect the existing handover graph/generation checks.
CREATE TRIGGER trg_read_scope_employee_deleted AFTER UPDATE OF is_deleted ON employees
FOR EACH ROW WHEN (OLD.is_deleted IS DISTINCT FROM NEW.is_deleted)
EXECUTE FUNCTION fn_mark_read_scope_domains('sales','finance','client');
ALTER TABLE employees ENABLE ALWAYS TRIGGER trg_read_scope_employee_deleted;
CREATE FUNCTION fn_mark_read_scope_rehire() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
        n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
BEGIN
    IF TG_TABLE_SCHEMA<>'public' THEN RAISE EXCEPTION 'Invalid read scope source' USING ERRCODE='55000'; END IF;
    IF (o->>'event_type'='rehire' OR n->>'event_type'='rehire')
       AND (TG_OP<>'UPDATE' OR ROW(o->>'employee_id',o->>'event_type') IS DISTINCT FROM ROW(n->>'employee_id',n->>'event_type')) THEN
      PERFORM public.fn_record_read_scope_change('sales'); PERFORM public.fn_record_read_scope_change('finance');
      PERFORM public.fn_record_read_scope_change('client');
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_read_scope_rehire AFTER INSERT OR UPDATE OR DELETE ON employment_history
FOR EACH ROW EXECUTE FUNCTION fn_mark_read_scope_rehire();
ALTER TABLE employment_history ENABLE ALWAYS TRIGGER trg_read_scope_rehire;

CREATE FUNCTION fn_mark_read_scope_handover() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
        n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
        value text;
BEGIN
    IF TG_TABLE_SCHEMA<>'public' THEN RAISE EXCEPTION 'Invalid read scope source' USING ERRCODE='55000'; END IF;
    IF TG_TABLE_NAME='employee_data_handovers' THEN
      IF NOT (COALESCE(o->>'status'='COMPLETED',false) OR COALESCE(n->>'status'='COMPLETED',false)) THEN RETURN NULL; END IF;
      IF TG_OP='UPDATE' AND ROW(o->>'status',o->>'source_employee_id',o->>'target_employee_id',o->>'source_employment_generation',o->>'target_employment_generation')
          IS NOT DISTINCT FROM ROW(n->>'status',n->>'source_employee_id',n->>'target_employee_id',n->>'source_employment_generation',n->>'target_employment_generation') THEN RETURN NULL; END IF;
      FOR value IN SELECT DISTINCT scope FROM public.employee_data_handover_scopes
          WHERE handover_id=COALESCE((n->>'id')::uuid,(o->>'id')::uuid) AND scope IN ('sales','finance','client') LOOP
        PERFORM public.fn_record_read_scope_change(value);
      END LOOP;
    ELSE
      IF TG_OP='UPDATE' AND ROW(o->>'handover_id',o->>'scope') IS NOT DISTINCT FROM ROW(n->>'handover_id',n->>'scope') THEN RETURN NULL; END IF;
      FOR value IN SELECT DISTINCT pair.scope FROM (VALUES((o->>'handover_id')::uuid,o->>'scope'),((n->>'handover_id')::uuid,n->>'scope')) pair(id,scope)
        JOIN public.employee_data_handovers h ON h.id=pair.id AND h.status='COMPLETED'
        WHERE pair.scope IN ('sales','finance','client') LOOP
        PERFORM public.fn_record_read_scope_change(value);
      END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_read_scope_handover AFTER INSERT OR UPDATE OR DELETE ON employee_data_handovers
FOR EACH ROW EXECUTE FUNCTION fn_mark_read_scope_handover();
CREATE TRIGGER trg_read_scope_handover_scopes AFTER INSERT OR UPDATE OR DELETE ON employee_data_handover_scopes
FOR EACH ROW EXECUTE FUNCTION fn_mark_read_scope_handover();
ALTER TABLE employee_data_handovers ENABLE ALWAYS TRIGGER trg_read_scope_handover;
ALTER TABLE employee_data_handover_scopes ENABLE ALWAYS TRIGGER trg_read_scope_handover_scopes;

-- Dictionary qualification is independent of report access. Disabled suppliers
-- remain readable; supplier status/default terms are not report revocation events.
CREATE TRIGGER trg_read_scope_supplier_qualification AFTER UPDATE OF is_deleted,is_internal_workshop ON suppliers
FOR EACH ROW WHEN (ROW(OLD.is_deleted,OLD.is_internal_workshop) IS DISTINCT FROM ROW(NEW.is_deleted,NEW.is_internal_workshop))
EXECUTE FUNCTION fn_mark_read_scope_domains('supplier');
CREATE TRIGGER trg_read_scope_client_qualification AFTER UPDATE OF is_deleted ON clients
FOR EACH ROW WHEN (OLD.is_deleted IS DISTINCT FROM NEW.is_deleted) EXECUTE FUNCTION fn_mark_read_scope_domains('client');
ALTER TABLE suppliers ENABLE ALWAYS TRIGGER trg_read_scope_supplier_qualification;
ALTER TABLE clients ENABLE ALWAYS TRIGGER trg_read_scope_client_qualification;

-- These administrative clear operations are normally already prohibited/retained;
-- if permitted explicitly, an old scope token must still never revive after restore.
CREATE TRIGGER trg_read_scope_grants_truncate AFTER TRUNCATE ON user_data_scopes
FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_read_scope_domains('sales','finance','client');
CREATE TRIGGER trg_read_scope_client_grants_truncate AFTER TRUNCATE ON client_visibility_grants
FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_read_scope_domains('client');
ALTER TABLE user_data_scopes ENABLE ALWAYS TRIGGER trg_read_scope_grants_truncate;
ALTER TABLE client_visibility_grants ENABLE ALWAYS TRIGGER trg_read_scope_client_grants_truncate;

-- Old V935 tasks keep a null stamp and must be explicitly recreated. Never
-- backfill today's permission boundary into a previously submitted request.
ALTER TABLE report_export_jobs ADD COLUMN access_stamp text;
ALTER TABLE report_export_jobs ADD CONSTRAINT report_export_access_stamp_shape
CHECK (access_stamp IS NULL OR access_stamp ~ '^[0-9a-f]{64}$');
CREATE FUNCTION fn_guard_report_export_access_stamp() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' AND NEW.access_stamp IS NULL THEN
      RAISE EXCEPTION 'New exports require a read authorization stamp' USING ERRCODE='23514';
    END IF;
    IF TG_OP='UPDATE' AND OLD.access_stamp IS DISTINCT FROM NEW.access_stamp THEN
      RAISE EXCEPTION 'Export read authorization stamps are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_report_export_access_stamp BEFORE INSERT OR UPDATE OF access_stamp ON report_export_jobs
FOR EACH ROW EXECUTE FUNCTION fn_guard_report_export_access_stamp();
ALTER TABLE report_export_jobs ENABLE ALWAYS TRIGGER trg_guard_report_export_access_stamp;
COMMENT ON VIEW read_scope_generations IS 'Authorization version only; not a business fact freshness watermark';
COMMENT ON TABLE read_scope_change_events IS 'Permanent committed access-change transaction identities; no MAX id/time watermark';
