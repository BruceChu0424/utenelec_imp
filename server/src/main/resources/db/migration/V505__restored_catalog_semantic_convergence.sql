-- The V476 live-server readback and a same-head fresh+restored baseline proved
-- these differences. Converge definitions forward; never rewrite applied SQL,
-- accepted business events, audit rows, or historical monetary snapshots.
DO $ledger_modes$
DECLARE entry RECORD; matches INTEGER;
BEGIN
    FOR entry IN SELECT * FROM (VALUES
        ('production_material_stock_events','trg_00_reject_production_material_stock_event_mutation','fn_reject_production_material_ledger_mutation'),
        ('production_material_stock_postings','trg_00_reject_production_material_stock_posting_mutation','fn_reject_production_material_ledger_mutation'),
        ('production_material_settlement_events','trg_00_reject_production_material_settlement_event_mutation','fn_reject_production_material_ledger_mutation'),
        ('production_material_settlement_postings','trg_00_reject_production_material_settlement_posting_mutation','fn_reject_production_material_ledger_mutation'),
        ('sales_shipment_warehouse_events','trg_00_reject_sales_shipment_warehouse_event_mutation','fn_reject_sales_shipment_warehouse_event_mutation'),
        ('sales_return_quality_events','trg_00_reject_sales_return_quality_event_mutation','fn_reject_sales_return_quality_event_mutation'),
        ('sales_return_disposition_events','trg_00_reject_sales_return_disposition_event_mutation','fn_reject_sales_return_disposition_event_mutation'),
        ('procurement_inspection_events','trg_00_reject_procurement_inspection_event_mutation','fn_reject_procurement_inspection_event_mutation')
    ) AS expected(table_name,trigger_name,function_name) LOOP
        SELECT count(*) INTO matches
        FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE t.tgrelid=to_regclass(format('public.%I',entry.table_name))
          AND t.tgname=entry.trigger_name AND NOT t.tgisinternal
          AND t.tgtype=27 AND t.tgnargs=0 AND t.tgqual IS NULL
          AND n.nspname='public' AND p.proname=entry.function_name;
        IF matches<>1 THEN
            RAISE EXCEPTION 'V505 unrecognized append-only guard: %.%',entry.table_name,entry.trigger_name;
        END IF;
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',entry.table_name,entry.trigger_name);
    END LOOP;
END;
$ledger_modes$;

-- V169 originally attached this counter trigger; V183 onward excludes counters
-- from row audit. Remove only the known redundant trigger, not custom audit.
DO $counter_audit$
DECLARE matches INTEGER;
BEGIN
    IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.master_code_sequences'::regclass
              AND tgname='trg_audit_master_code_sequences') THEN
        SELECT count(*) INTO matches
        FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE t.tgrelid='public.master_code_sequences'::regclass
          AND t.tgname='trg_audit_master_code_sequences' AND NOT t.tgisinternal
          AND t.tgtype=29 AND t.tgnargs=0 AND t.tgqual IS NULL
          AND n.nspname='public' AND p.proname IN ('fn_audit','fn_audit_redacted');
        IF matches<>1 THEN RAISE EXCEPTION 'V505 refuses to remove an unrecognized counter audit trigger'; END IF;
        DROP TRIGGER trg_audit_master_code_sequences ON public.master_code_sequences;
    END IF;
END;
$counter_audit$;

-- Missing actual cost is unknown, not a confirmed zero. Existing NULL/zero and
-- positive historical values are untouched; only future omitted defaults align.
ALTER TABLE sales_other_shipment_items
    ALTER COLUMN material_price DROP DEFAULT,
    ALTER COLUMN die_cast_price DROP DEFAULT,
    ALTER COLUMN machining_price DROP DEFAULT;

-- V171 CREATE TABLE IF NOT EXISTS ... LIKE INCLUDING INDEXES only copied these
-- indexes on fresh catalogs. Explicit definitions make restored catalogs equal.
CREATE INDEX IF NOT EXISTS audit_log_archive_event_category_created_at_idx
    ON audit_log_archive(event_category,created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_archive_request_id_idx
    ON audit_log_archive(request_id) WHERE request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS audit_log_archive_risk_level_created_at_idx
    ON audit_log_archive(risk_level,created_at DESC);

DO $archive_indexes$
DECLARE entry RECORD;
BEGIN
    FOR entry IN SELECT * FROM (VALUES
        ('audit_log_archive_event_category_created_at_idx','CREATE INDEX audit_log_archive_event_category_created_at_idx ON public.audit_log_archive USING btree (event_category, created_at DESC)'),
        ('audit_log_archive_request_id_idx','CREATE INDEX audit_log_archive_request_id_idx ON public.audit_log_archive USING btree (request_id) WHERE (request_id IS NOT NULL)'),
        ('audit_log_archive_risk_level_created_at_idx','CREATE INDEX audit_log_archive_risk_level_created_at_idx ON public.audit_log_archive USING btree (risk_level, created_at DESC)')
    ) AS expected(index_name,definition) LOOP
        IF NOT EXISTS(SELECT 1 FROM pg_index i WHERE i.indexrelid=to_regclass(format('public.%I',entry.index_name))
                      AND i.indrelid='public.audit_log_archive'::regclass AND i.indisvalid
                      AND pg_get_indexdef(i.indexrelid)=entry.definition) THEN
            RAISE EXCEPTION 'V505 unrecognized archive index: %',entry.index_name;
        END IF;
    END LOOP;
END;
$archive_indexes$;
