-- Final module, after every typed source proof has been registered. Keep the
-- large complete nonposting array out of the hot bootstrap run until then.
DO $stock_movement_summary_finalize$
DECLARE entries jsonb; checksum text; claim uuid:=NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid;
    previous jsonb; changed integer;
BEGIN
    IF to_regclass('pg_temp.bootstrap_stock_movement_nonposting') IS NULL THEN
        RAISE EXCEPTION 'stock nonposting source facts were not preserved until finalization';
    END IF;
    SELECT reconciliation_summary->'stockMovementChecks' INTO previous FROM legacy_migration_runs
    WHERE run_id=claim AND status='RUNNING' AND migration_mode='BOOTSTRAP';
    IF previous->>'passed' IS DISTINCT FROM 'true'
       OR previous->>'validationVersion' IS DISTINCT FROM 'stock-source-movements-v1'
       OR previous->>'entriesPersisted' IS DISTINCT FROM 'false' THEN
        RAISE EXCEPTION 'stock movement summary does not belong to one validated pending bootstrap run';
    END IF;
    IF EXISTS(SELECT 1 FROM bootstrap_stock_movement_nonposting p
        LEFT JOIN stock_document_items i ON i.id=p.item_id LEFT JOIN stock_documents d ON d.id=p.document_id
        LEFT JOIN legacy_migration_run_files f ON f.run_id=claim AND f.file_name=p.source_file
        WHERE p.run_id IS DISTINCT FROM claim OR p.reason IS DISTINCT FROM 'NONPOSTING_ZERO_QUANTITY'
           OR p.base_qty IS DISTINCT FROM 0::numeric OR p.source_file_sha256 IS DISTINCT FROM f.sha256
           OR p.source_row_sha256 !~ '^[0-9a-f]{64}$'
           OR i.id IS NULL OR d.id IS NULL OR i.doc_id IS DISTINCT FROM d.id
           OR i.legacy_id IS DISTINCT FROM p.item_legacy_id OR i.bill_type IS DISTINCT FROM p.doc_type
           OR d.doc_type IS DISTINCT FROM p.doc_type OR d.legacy_id IS DISTINCT FROM p.document_legacy_id
           OR i.qty IS DISTINCT FROM p.qty OR i.unit_rate IS DISTINCT FROM COALESCE(p.unit_rate,1)
           OR i.base_qty IS DISTINCT FROM 0::numeric
           OR i.amount_original IS DISTINCT FROM p.amount_original OR i.amount_local IS DISTINCT FROM p.amount_local
           OR EXISTS(SELECT 1 FROM stock_movements m WHERE m.source_doc_type='STOCK_DOC' AND m.source_item_id=p.item_id)) THEN
        RAISE EXCEPTION 'stock nonposting source facts changed, disappeared or produced a stock event';
    END IF;
    SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY source_file,item_legacy_id),'[]'::jsonb)
    INTO entries FROM bootstrap_stock_movement_nonposting p;
    checksum:=encode(digest(entries::text,'sha256'),'hex');
    IF jsonb_array_length(entries) IS DISTINCT FROM (previous->>'nonpostingItems')::bigint
       OR checksum IS DISTINCT FROM previous->>'nonpostingFactsSha256'
       OR (SELECT count(*) FROM stock_movements WHERE source_doc_type='STOCK_DOC') IS DISTINCT FROM (previous->>'matchedMovements')::bigint THEN
        RAISE EXCEPTION 'stock movement source summary or event count changed before finalization';
    END IF;
    UPDATE legacy_migration_runs SET reconciliation_summary=jsonb_set(reconciliation_summary,'{stockMovementChecks}',
        previous||jsonb_build_object('entriesPersisted',true,'entries',entries))
    WHERE run_id=claim AND status='RUNNING' AND migration_mode='BOOTSTRAP';
    GET DIAGNOSTICS changed=ROW_COUNT;
    IF changed<>1 THEN RAISE EXCEPTION 'stock movement summary requires one running bootstrap claim'; END IF;
END;
$stock_movement_summary_finalize$;
