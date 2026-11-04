-- The original balance and its full source journals form one reviewed continuation.
ALTER TABLE finance_accounting_import_batches ADD COLUMN kind text NOT NULL DEFAULT 'VOUCHERS'
    CHECK(kind IN('VOUCHERS','BALANCE'));
ALTER TABLE finance_accounting_import_batches ADD COLUMN paired_import_id uuid REFERENCES finance_accounting_import_batches(id);
ALTER TABLE finance_accounting_import_batches ADD COLUMN reason text;
ALTER TABLE finance_accounting_import_batches ADD COLUMN reversed_at timestamptz;
ALTER TABLE finance_accounting_import_batches ADD COLUMN reversed_by uuid REFERENCES users(id);
ALTER TABLE finance_accounting_import_batches ADD COLUMN reversal_result jsonb;
ALTER TABLE finance_gl_auxiliary_opening_evidence ADD COLUMN opening_original numeric CHECK(fn_financial_amount_is_exact(opening_original));
ALTER TABLE finance_gl_auxiliary_opening_evidence ADD COLUMN exchange_rate numeric CHECK(exchange_rate IS NULL OR exchange_rate>0 AND fn_financial_amount_is_exact(exchange_rate));
ALTER TABLE finance_gl_auxiliary_opening_evidence ADD COLUMN source_reference text;
ALTER TABLE finance_gl_auxiliary_opening_evidence ADD CONSTRAINT finance_gl_aux_opening_original_unit CHECK(opening_original IS NULL OR original_currency_id IS NOT NULL);
CREATE TABLE finance_accounting_review_operations (
    request_id uuid PRIMARY KEY,actor_id uuid NOT NULL REFERENCES users(id),import_id uuid NOT NULL REFERENCES finance_accounting_import_batches(id),
    action text NOT NULL CHECK(action IN('APPROVE','REJECT','WITHDRAW')),
    fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_finance_accounting_review_operation_immutable BEFORE UPDATE OR DELETE ON finance_accounting_review_operations
    FOR EACH ROW EXECUTE FUNCTION fn_reject_update_or_delete();
CREATE TABLE finance_gl_opening_baselines (
    effective_from date PRIMARY KEY,
    import_batch_id uuid NOT NULL UNIQUE REFERENCES finance_accounting_import_batches(id),
    source_sha256 text NOT NULL CHECK(source_sha256~'^[0-9a-f]{64}$'),
    verified_by uuid NOT NULL REFERENCES users(id),verified_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION fn_finance_balance_asof_complete(p_date date)
RETURNS boolean LANGUAGE sql STABLE STRICT AS $$
    WITH baseline AS (
        SELECT b.effective_from FROM finance_gl_opening_baselines b
        JOIN finance_accounting_import_batches batch ON batch.id=b.import_batch_id
        WHERE b.effective_from<=p_date+1 AND batch.status='POSTED' AND batch.reversed_at IS NULL
          AND NOT EXISTS(SELECT 1 FROM gl_entries e LEFT JOIN finance_gl_voucher_evidence proof ON proof.voucher_id=e.voucher_id
              WHERE NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(e.voucher_id) AND e.entry_date<b.effective_from AND proof.import_batch_id IS DISTINCT FROM b.import_batch_id)
        ORDER BY b.effective_from DESC LIMIT 1
    )
    SELECT EXISTS(SELECT 1 FROM baseline) AND NOT EXISTS(
        SELECT 1 FROM baseline b,
        generate_series(date_trunc('month',b.effective_from)::date,date_trunc('month',p_date)::date,interval '1 month') month
        LEFT JOIN finance_gl_period_versions v ON v.period=to_char(month,'YYYY-MM')
        LEFT JOIN finance_accounting_period_coverage c ON c.period=v.period
        WHERE c.period IS NULL OR c.entries_revision<>v.revision
    );
$$;
-- A verified zero is available to asset continuation without inventing a zero GL entry.
CREATE OR REPLACE FUNCTION fn_finance_style_balance_asof(p_style uuid,p_date date)
RETURNS numeric LANGUAGE sql STABLE STRICT AS $$
    SELECT CASE WHEN fn_finance_balance_asof_complete(p_date)
        AND EXISTS(SELECT 1 FROM payment_styles WHERE id=p_style AND NOT is_deleted)
        THEN COALESCE((SELECT sum(direction*amount) FROM gl_entries
            WHERE style_id=p_style AND NOT is_deleted AND fn_finance_gl_voucher_is_booked(voucher_id) AND entry_date<=p_date),0) END;
$$;
CREATE OR REPLACE FUNCTION fn_finance_style_balance_evidence_fingerprint(p_style uuid,p_date date)
RETURNS text LANGUAGE sql STABLE STRICT AS $$
    WITH baseline AS (
        SELECT b.* FROM finance_gl_opening_baselines b
        JOIN finance_accounting_import_batches batch ON batch.id=b.import_batch_id
        WHERE b.effective_from<=p_date+1 AND batch.status='POSTED' AND batch.reversed_at IS NULL
        ORDER BY b.effective_from DESC LIMIT 1
    ), versions AS (
        SELECT string_agg(concat_ws(':',v.period,v.revision,c.entries_revision,c.source_sha256,c.verified_by,c.verified_at),',' ORDER BY v.period) AS proof
        FROM baseline b,
        generate_series(date_trunc('month',b.effective_from)::date,date_trunc('month',p_date)::date,interval '1 month') month
        JOIN finance_gl_period_versions v ON v.period=to_char(month,'YYYY-MM')
        JOIN finance_accounting_period_coverage c ON c.period=v.period
    )
    SELECT CASE WHEN fn_finance_style_balance_asof(p_style,p_date) IS NOT NULL THEN
        encode(digest(concat_ws('|',p_style,p_date,b.import_batch_id,b.effective_from,b.source_sha256,b.verified_by,b.verified_at,v.proof),'sha256'),'hex') END
    FROM baseline b CROSS JOIN versions v;
$$;
CREATE TRIGGER trg_finance_gl_baseline_immutable BEFORE UPDATE OR DELETE ON finance_gl_opening_baselines
    FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_evidence_immutable();
CREATE TRIGGER trg_audit_finance_accounting_batch AFTER INSERT OR UPDATE OR DELETE ON finance_accounting_import_batches
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_gl_baseline AFTER INSERT ON finance_gl_opening_baselines
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_accounting_import_batches ENABLE ALWAYS TRIGGER trg_audit_finance_accounting_batch;
ALTER TABLE finance_gl_opening_baselines ENABLE ALWAYS TRIGGER trg_audit_finance_gl_baseline;

CREATE OR REPLACE FUNCTION fn_finance_accounting_source_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'Original accounting source files and reviews are retained' USING ERRCODE='23514';
    END IF;
    IF (NEW.actor_id,NEW.kind,NEW.source_name,NEW.source_system,NEW.sha256,NEW.storage_provider,NEW.storage_key,
        NEW.storage_version,NEW.storage_size,NEW.preview,NEW.created_at)
        IS DISTINCT FROM (OLD.actor_id,OLD.kind,OLD.source_name,OLD.source_system,OLD.sha256,OLD.storage_provider,OLD.storage_key,
        OLD.storage_version,OLD.storage_size,OLD.preview,OLD.created_at) THEN
        RAISE EXCEPTION 'Original accounting source identity and literal preview are immutable' USING ERRCODE='23514';
    END IF;
    IF OLD.status='POSTED' AND (NEW.status,NEW.result,NEW.reviewed_input,NEW.approved_by,NEW.approved_at,NEW.submitted_by,NEW.submitted_at,NEW.paired_import_id)
        IS DISTINCT FROM (OLD.status,OLD.result,OLD.reviewed_input,OLD.approved_by,OLD.approved_at,OLD.submitted_by,OLD.submitted_at,OLD.paired_import_id) THEN
        RAISE EXCEPTION 'Posted accounting source review is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_finance_accounting_source_immutable BEFORE UPDATE OR DELETE ON finance_accounting_import_batches
    FOR EACH ROW EXECUTE FUNCTION fn_finance_accounting_source_immutable();
-- Register one metadata-only trail. Private source rows, amounts and review
-- payloads remain available only through their financial source permissions.
DROP TRIGGER IF EXISTS trg_audit_finance_chart_codes ON finance_chart_codes;
DROP TRIGGER IF EXISTS trg_audit_finance_chart_code_styles ON finance_chart_code_styles;
DROP TRIGGER IF EXISTS trg_audit_finance_gl_voucher_evidence ON finance_gl_voucher_evidence;
DROP TRIGGER IF EXISTS trg_audit_finance_gl_entry_allocations ON finance_gl_entry_allocations;
DROP TRIGGER IF EXISTS trg_audit_finance_gl_aux_opening ON finance_gl_auxiliary_opening_evidence;
DROP TRIGGER IF EXISTS trg_audit_finance_accounting_batch ON finance_accounting_import_batches;
DROP TRIGGER IF EXISTS trg_audit_finance_gl_baseline ON finance_gl_opening_baselines;
DO $financial_source_audit$ DECLARE target text; metadata text[]; BEGIN
    FOREACH target IN ARRAY ARRAY['finance_chart_imports','finance_chart_manual_operations','finance_chart_codes',
        'finance_chart_code_styles','finance_chart_owned_bindings','finance_accounting_import_batches',
        'finance_accounting_review_operations','finance_gl_voucher_evidence','finance_gl_entry_allocations',
        'finance_gl_auxiliary_opening_evidence','finance_gl_opening_baselines','finance_accounting_period_coverage'] LOOP
        SELECT array_agg(a.attname::text ORDER BY a.attnum) INTO metadata FROM pg_attribute a
        WHERE a.attrelid=to_regclass('public.'||target) AND a.attnum>0 AND NOT a.attisdropped
          AND (a.atttypid IN('uuid'::regtype,'timestamptz'::regtype,'timestamp'::regtype,'date'::regtype)
            OR a.attname=ANY(ARRAY['code','account_code','line_key','period','status','kind','source_kind','classification',
                'row_version','entries_revision','revision','source_sha256','sha256','fingerprint','payload_hash']));
        PERFORM fn_audit_track_table(target,'COLUMN_SCOPED','data_change',false,metadata,true,NULL);
    END LOOP;
END; $financial_source_audit$;
DO $$ DECLARE definition text; BEGIN
    SELECT pg_get_viewdef('v_private_document_storage_references'::regclass,true) INTO definition;
    definition:=regexp_replace(definition,';[[:space:]]*$','');
    EXECUTE 'CREATE OR REPLACE VIEW v_private_document_storage_references AS '||definition||
        ' UNION SELECT storage_provider,storage_key,storage_version FROM finance_chart_imports'||
        ' UNION SELECT storage_provider,storage_key,storage_version FROM finance_accounting_import_batches';
END $$;
