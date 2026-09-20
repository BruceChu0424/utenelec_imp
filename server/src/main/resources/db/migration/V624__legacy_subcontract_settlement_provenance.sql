-- E_Order did not record contractual settlement. Preserve that unknown only
-- for an exact, privileged, transaction-bound bootstrap source; never infer it.
CREATE TABLE legacy_subcontract_order_import_sources (
    run_id uuid NOT NULL REFERENCES legacy_migration_runs(run_id) ON DELETE RESTRICT,
    source_legacy_id integer NOT NULL CHECK (source_legacy_id > 0),
    order_id uuid NOT NULL UNIQUE,
    source_row_sha256 char(64) NOT NULL CHECK (source_row_sha256 ~ '^[0-9a-f]{64}$'),
    source_file_sha256 char(64) NOT NULL CHECK (source_file_sha256 ~ '^[0-9a-f]{64}$'),
    expected_header_sha256 char(64) NOT NULL CHECK (expected_header_sha256 ~ '^[0-9a-f]{64}$'),
    issued_txid bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (run_id, source_legacy_id),
    UNIQUE (run_id, source_legacy_id, order_id)
);
COMMENT ON TABLE legacy_subcontract_order_import_sources IS
    'PRESERVE: immutable E_Order bootstrap evidence; hashes and IDs only, no source plaintext or credentials';

ALTER TABLE subcontract_orders ADD COLUMN legacy_import_run_id uuid;
ALTER TABLE subcontract_orders ADD CONSTRAINT subcontract_order_legacy_import_source_fk
    FOREIGN KEY (legacy_import_run_id,legacy_id,id)
    REFERENCES legacy_subcontract_order_import_sources(run_id,source_legacy_id,order_id) ON DELETE RESTRICT;
COMMENT ON COLUMN subcontract_orders.legacy_import_run_id IS
    'Privileged first-import provenance only; historical unknown settlement remains NULL and blocks new receipts pending evidenced reconciliation';

CREATE FUNCTION fn_require_legacy_subcontract_bootstrap(p_run_id uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE
    run public.legacy_migration_runs%ROWTYPE;
    lock_key bigint := hashtextextended('uten:legacy-bootstrap:'||current_database(),0);
    trusted boolean;
BEGIN
    -- Check the authenticated login, not an impersonated role or user-set GUC.
    SELECT rolsuper OR (rolname='uten_migrator' AND rolcanlogin) INTO trusted
      FROM pg_catalog.pg_roles WHERE rolname=session_user;
    IF NOT COALESCE(trusted,false) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy subcontract evidence requires the dedicated migration identity';
    END IF;
    IF p_run_id IS NULL OR current_setting('uten.bootstrap_run_id',true) IS DISTINCT FROM p_run_id::text
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_locks WHERE locktype='advisory' AND pid=pg_backend_pid()
           AND granted AND mode='ExclusiveLock' AND objsubid=1
           AND classid=((lock_key>>32)&4294967295)::oid AND objid=(lock_key&4294967295)::oid) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy subcontract evidence requires the active bootstrap lock and run';
    END IF;
    SELECT * INTO run FROM public.legacy_migration_runs WHERE run_id=p_run_id FOR UPDATE;
    IF NOT FOUND OR run.status<>'RUNNING' OR run.target<>'--bootstrap-all' OR run.migration_mode<>'BOOTSTRAP'
       OR run.database_user<>session_user OR run.finished_at IS NOT NULL
       OR run.reconciliation_summary->>'importAtomicity' IS DISTINCT FROM 'single-transaction-v1'
       OR run.reconciliation_summary->>'targetDatabase' IS DISTINCT FROM current_database()
       OR run.reconciliation_summary->>'targetSystemIdentifier' IS DISTINCT FROM
           (SELECT system_identifier::text FROM pg_control_system())
       OR run.mapping_version IS DISTINCT FROM current_setting('uten.bootstrap_mapping_version',true)
       OR run.migration_repository_commit IS DISTINCT FROM current_setting('uten.bootstrap_repository_commit',true)
       OR run.export_manifest_sha256::text IS DISTINCT FROM current_setting('uten.bootstrap_manifest_sha',true)
       OR COALESCE(run.mapping_version !~ '^bootstrap-v[1-9][0-9]*$',true)
       OR COALESCE(run.migration_repository_commit !~ '^[0-9a-f]{40,64}$',true)
       OR run.export_manifest_sha256 IS NULL OR run.checksum_manifest_sha256 IS NULL
       OR run.migration_script_sha256 IS NULL OR run.source_backup_sha256 IS NULL
       OR run.export_approval_reference IS NULL
       OR COALESCE(run.reconciliation_summary->>'targetApprovalReference' !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$',true)
       OR NOT EXISTS (SELECT 1 FROM public.legacy_migration_run_files
           WHERE run_id=p_run_id AND file_name='subcontract_order_m.csv' AND byte_size>0) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy subcontract bootstrap provenance does not match this database and candidate';
    END IF;
END; $$;

CREATE FUNCTION fn_legacy_subcontract_header_snapshot(p public.subcontract_orders) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public AS $$
    SELECT jsonb_build_object('legacy_id',p.legacy_id,'bill_no',p.bill_no,'bill_date',p.bill_date,
        'supplier_id',p.supplier_id,'currency_id',p.currency_id,'exchange_rate',trim_scale(p.exchange_rate),
        'tax_rate',trim_scale(p.tax_rate),'deliver_date',p.deliver_date,'remark',p.remark,
        'total_original',trim_scale(p.total_original),'total_local',trim_scale(p.total_local),'status',p.status,
        'fulfill',p.fulfill,'is_closed',p.is_closed)
$$;

CREATE FUNCTION fn_guard_legacy_subcontract_source_evidence() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy subcontract source evidence is immutable';
    END IF;
    PERFORM public.fn_require_legacy_subcontract_bootstrap(NEW.run_id);
    IF NEW.issued_txid<>txid_current() OR NEW.source_file_sha256 IS DISTINCT FROM
        (SELECT sha256 FROM public.legacy_migration_run_files
         WHERE run_id=NEW.run_id AND file_name='subcontract_order_m.csv') THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy subcontract source evidence belongs to another input or transaction';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_legacy_subcontract_source_evidence
    BEFORE INSERT OR UPDATE OR DELETE ON legacy_subcontract_order_import_sources
    FOR EACH ROW EXECUTE FUNCTION fn_guard_legacy_subcontract_source_evidence();
ALTER TABLE legacy_subcontract_order_import_sources ENABLE ALWAYS TRIGGER trg_guard_legacy_subcontract_source_evidence;
CREATE TRIGGER trg_audit_legacy_subcontract_order_import_sources
    AFTER INSERT OR UPDATE OR DELETE ON legacy_subcontract_order_import_sources
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE legacy_subcontract_order_import_sources ENABLE ALWAYS TRIGGER trg_audit_legacy_subcontract_order_import_sources;

CREATE FUNCTION fn_register_legacy_subcontract_order_source(p_run_id uuid,p_source jsonb) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE
    expected public.subcontract_orders%ROWTYPE;
    result uuid := gen_random_uuid();
    keys text[];
BEGIN
    PERFORM public.fn_require_legacy_subcontract_bootstrap(p_run_id);
    IF jsonb_typeof(p_source) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='E_Order source must be the complete typed source row';
    END IF;
    SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_source) key;
    IF keys IS DISTINCT FROM ARRAY['approver_legacy','bill_date','bill_no','cancel_bit','currency_legacy_id',
        'deliver_date','exchange_rate','fulfill_bit','legacy_id','maker_legacy','remark','send_legacy',
        'status','stop_bit','supplier_legacy_id','tax_rate','total_original']::text[]
       OR (p_source->>'status')::smallint IS DISTINCT FROM 1::smallint
       OR (p_source->>'legacy_id')::integer IS NULL OR (p_source->>'legacy_id')::integer<=0 THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='E_Order evidence has an unsupported source shape or state';
    END IF;
    expected.legacy_id := (p_source->>'legacy_id')::integer;
    expected.bill_no := p_source->>'bill_no';
    expected.bill_date := (p_source->>'bill_date')::date;
    expected.supplier_id := (SELECT id FROM public.suppliers WHERE legacy_id=(p_source->>'supplier_legacy_id')::integer);
    expected.currency_id := (SELECT id FROM public.currencies WHERE legacy_id=(p_source->>'currency_legacy_id')::integer);
    expected.exchange_rate := COALESCE((p_source->>'exchange_rate')::numeric,1);
    expected.tax_rate := (p_source->>'tax_rate')::numeric;
    expected.deliver_date := (p_source->>'deliver_date')::date;
    expected.remark := p_source->>'remark';
    expected.total_original := (p_source->>'total_original')::numeric;
    expected.total_local := expected.total_original;
    expected.status := 1;
    expected.fulfill := COALESCE((p_source->>'fulfill_bit')::boolean,false);
    expected.is_closed := expected.fulfill;
    INSERT INTO public.legacy_subcontract_order_import_sources(run_id,source_legacy_id,order_id,
        source_row_sha256,source_file_sha256,expected_header_sha256,issued_txid)
    SELECT p_run_id,expected.legacy_id,result,encode(public.digest(p_source::text,'sha256'),'hex'),sha256,
        encode(public.digest(public.fn_legacy_subcontract_header_snapshot(expected)::text,'sha256'),'hex'),txid_current()
    FROM public.legacy_migration_run_files WHERE run_id=p_run_id AND file_name='subcontract_order_m.csv';
    RETURN result;
END; $$;

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V624 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''legacy_subcontract_order_import_sources'', ''PRESERVE'')');
END;
$reset_policy$;

CREATE FUNCTION fn_guard_subcontract_legacy_import_provenance() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE proof public.legacy_subcontract_order_import_sources%ROWTYPE;
BEGIN
    IF TG_OP='UPDATE' THEN
        IF NEW.legacy_import_run_id IS DISTINCT FROM OLD.legacy_import_run_id THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy subcontract provenance cannot be added, rebound or cleared';
        END IF;
        IF OLD.legacy_import_run_id IS NOT NULL AND
           (to_jsonb(NEW)-ARRAY['updated_at','updated_by','version','settlement_method_id','fulfill','is_closed','status']) IS DISTINCT FROM
           (to_jsonb(OLD)-ARRAY['updated_at','updated_by','version','settlement_method_id','fulfill','is_closed','status']) THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='imported subcontract source facts are immutable';
        END IF;
        IF OLD.legacy_import_run_id IS NOT NULL AND NEW.status IS DISTINCT FROM OLD.status
           AND NOT (OLD.status=1 AND NEW.status=-1) THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='imported subcontract source cannot become a new draft or approval';
        END IF;
        IF OLD.legacy_import_run_id IS NOT NULL AND OLD.settlement_method_id IS NOT NULL
           AND NEW.settlement_method_id IS NULL THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='verified legacy subcontract settlement cannot become unknown again';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.legacy_import_run_id IS NULL THEN RETURN NEW; END IF;
    PERFORM public.fn_require_legacy_subcontract_bootstrap(NEW.legacy_import_run_id);
    SELECT * INTO proof FROM public.legacy_subcontract_order_import_sources
      WHERE run_id=NEW.legacy_import_run_id AND source_legacy_id=NEW.legacy_id AND order_id=NEW.id;
    IF NOT FOUND OR proof.issued_txid<>txid_current() OR NEW.settlement_method_id IS NOT NULL
       OR NEW.warehouse_id IS NOT NULL OR NEW.purchaser_id IS NOT NULL OR NEW.maker_id IS NOT NULL
       OR NEW.approver_id IS NOT NULL OR NEW.source_doc_no IS NOT NULL OR NEW.is_deleted OR NEW.deleted_at IS NOT NULL
       OR proof.expected_header_sha256 IS DISTINCT FROM
           encode(public.digest(public.fn_legacy_subcontract_header_snapshot(NEW)::text,'sha256'),'hex') THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='subcontract header does not match its exact E_Order bootstrap source';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_subcontract_legacy_import_provenance
    BEFORE INSERT OR UPDATE ON subcontract_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_legacy_import_provenance();
ALTER TABLE subcontract_orders ENABLE ALWAYS TRIGGER trg_guard_subcontract_legacy_import_provenance;

-- Legacy approved orders have no online finance-approval case. V438 alone
-- therefore cannot freeze their original lines. Keep actual receipt/return
-- progress writable while preventing an imported header from becoming a shell
-- for newly inserted or commercially rewritten approved items.
CREATE FUNCTION fn_guard_legacy_subcontract_details() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE order_key uuid; run_key uuid; issued bigint; old_value jsonb; new_value jsonb;
BEGIN
    old_value := CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END;
    new_value := CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END;
    FOR order_key IN SELECT DISTINCT value FROM unnest(ARRAY[
        (old_value->>'order_id')::uuid,(new_value->>'order_id')::uuid]) value WHERE value IS NOT NULL LOOP
        SELECT header.legacy_import_run_id,proof.issued_txid INTO run_key,issued
        FROM public.subcontract_orders header
        LEFT JOIN public.legacy_subcontract_order_import_sources proof
          ON proof.run_id=header.legacy_import_run_id AND proof.order_id=header.id
        WHERE header.id=order_key;
        IF run_key IS NULL THEN CONTINUE; END IF;
        IF issued=txid_current() AND current_setting('uten.bootstrap_run_id',true)=run_key::text THEN
            PERFORM public.fn_require_legacy_subcontract_bootstrap(run_key);
            CONTINUE;
        END IF;
        IF TG_OP<>'UPDATE' OR
           (new_value-ARRAY['updated_at','updated_by','version','received_qty','returned_qty','issued_qty','material_returned_qty','arrival_overage_posted_qty'])
           IS DISTINCT FROM
           (old_value-ARRAY['updated_at','updated_by','version','received_qty','returned_qty','issued_qty','material_returned_qty','arrival_overage_posted_qty']) THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='imported subcontract item commercial source facts are immutable';
        END IF;
    END LOOP;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_legacy_subcontract_items BEFORE INSERT OR UPDATE OR DELETE
    ON subcontract_order_items FOR EACH ROW EXECUTE FUNCTION fn_guard_legacy_subcontract_details();
ALTER TABLE subcontract_order_items ENABLE ALWAYS TRIGGER trg_guard_legacy_subcontract_items;
CREATE TRIGGER trg_guard_legacy_subcontract_cost_items BEFORE INSERT OR UPDATE OR DELETE
    ON subcontract_order_cost_items FOR EACH ROW EXECUTE FUNCTION fn_guard_legacy_subcontract_details();
ALTER TABLE subcontract_order_cost_items ENABLE ALWAYS TRIGGER trg_guard_legacy_subcontract_cost_items;

ALTER TABLE subcontract_orders DROP CONSTRAINT subcontract_orders_approved_settlement_chk;
ALTER TABLE subcontract_orders ADD CONSTRAINT subcontract_orders_approved_settlement_chk
    CHECK(status<>1 OR settlement_method_id IS NOT NULL OR legacy_import_run_id IS NOT NULL) NOT VALID;

REVOKE ALL ON legacy_subcontract_order_import_sources FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_register_legacy_subcontract_order_source(uuid,jsonb) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON legacy_subcontract_order_import_sources FROM uten;
        GRANT SELECT ON legacy_subcontract_order_import_sources TO uten;
        REVOKE ALL ON FUNCTION fn_register_legacy_subcontract_order_source(uuid,jsonb) FROM uten;
    END IF;
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten_migrator') THEN
        GRANT SELECT,INSERT ON legacy_subcontract_order_import_sources TO uten_migrator;
        GRANT EXECUTE ON FUNCTION fn_register_legacy_subcontract_order_source(uuid,jsonb) TO uten_migrator;
    END IF;
END; $$;
