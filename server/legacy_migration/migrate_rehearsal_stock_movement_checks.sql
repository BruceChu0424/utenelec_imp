-- Source-derived physical event acceptance, before stock staging cleanup.
-- No business quantity, amount, UUID relation or balance is written here.
DO $stock_movement_check_preconditions$
BEGIN
    IF to_regclass('pg_temp.item_stage') IS NULL OR to_regclass('pg_temp.doc_stage') IS NULL
       OR to_regclass('pg_temp.warehouse_target_stage') IS NULL
       OR to_regclass('pg_temp.bootstrap_warehouse_exclusions') IS NULL THEN
        RAISE EXCEPTION 'stock movement checks require the original typed stock staging';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM legacy_migration_runs
        WHERE run_id=NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid
          AND status='RUNNING' AND migration_mode='BOOTSTRAP') THEN
        RAISE EXCEPTION 'stock movement checks require the current running bootstrap claim';
    END IF;
    -- These TEMP stages were filled in this transaction; autovacuum cannot
    -- provide statistics. Cold EXISTS anti-joins otherwise favor nested scans.
    ANALYZE doc_stage;
    ANALYZE item_stage;
    IF EXISTS(SELECT 1 FROM doc_stage GROUP BY doc_type,legacy_id HAVING count(*)>1)
       OR EXISTS(SELECT 1 FROM item_stage GROUP BY doc_type,legacy_id HAVING count(*)>1)
       OR EXISTS(SELECT 1 FROM stock_documents GROUP BY doc_type,legacy_id HAVING count(*)>1)
       OR EXISTS(SELECT 1 FROM stock_document_items GROUP BY bill_type,legacy_id HAVING count(*)>1)
       OR EXISTS(SELECT 1 FROM warehouse_target_stage GROUP BY legacy_id HAVING count(*)>1) THEN
        RAISE EXCEPTION 'stock movement source/target contains duplicate type-scoped identities';
    END IF;
    IF EXISTS(SELECT 1 FROM item_stage i WHERE NOT EXISTS(
        SELECT 1 FROM doc_stage d WHERE d.doc_type=i.doc_type AND d.legacy_id=i.bill_legacy_id)) THEN
        RAISE EXCEPTION 'stock movement item has no exact original source header';
    END IF;
END;
$stock_movement_check_preconditions$;

-- Resolve source dimensions independently of the loader's item warehouse/base
-- fields. Typed source quantities/rates/amounts are the comparison authority.
CREATE TEMP TABLE rehearsal_stock_movement_candidates ON COMMIT DROP AS
WITH resolved AS (
SELECT s.doc_type,s.legacy_id AS item_legacy_id,s.bill_legacy_id AS document_legacy_id,
       'stock_'||lower(s.doc_type)||'_i.csv' AS source_file,
       encode(digest((to_jsonb(s)-'doc_type')::text,'sha256'),'hex') AS source_row_sha256,
       sd.bill_date,sd.status,sd.stock_legacy_id,sd.to_stock_legacy_id,
       source_side.warehouse_id AS source_warehouse_id,target_side.warehouse_id AS target_warehouse_id,
       source_side.action AS source_action,target_side.action AS target_action,s.goods_legacy_id,
       CASE WHEN source_side.action='SPLIT' OR target_side.action='SPLIT' THEN
         COALESCE((SELECT opening.bin_warehouse_id FROM workshop_stock_location_crosswalk_stage reviewed
                   JOIN workshop_stock_location_authority_stage authority ON authority.authority_sha256=reviewed.authority_sha256
                   JOIN workshop_bins opening ON opening.workshop_department_id=authority.workshop_department_id
                     AND opening.bin_warehouse_id=reviewed.bin_warehouse_id
                   WHERE reviewed.goods_legacy_id=s.goods_legacy_id AND reviewed.goods_code=g.code AND reviewed.goods_name=g.name
                     AND encode(sha256(convert_to(to_jsonb(opening)::text,'UTF8')),'hex')=authority.bin_row_sha256),
            CASE WHEN fn_warehouse_is_good_stock_leaf(g.owning_warehouse_id) THEN g.owning_warehouse_id END,
            (SELECT w.id FROM warehouses w WHERE w.code=NULLIF(current_setting('uten.legacy_unassigned_warehouse_code',true),'') AND NOT w.is_deleted))
       END AS expected_item_warehouse_id,
       g.id AS goods_id,c.id AS color_id,u.id AS unit_id,
       s.qty AS source_qty,s.unit_rate AS source_unit_rate,COALESCE(s.unit_rate,1) AS effective_unit_rate,
       round(COALESCE(s.qty,0)*COALESCE(s.unit_rate,1),4) AS expected_base_qty,
       s.amount AS source_amount,s.surplus_qty,
       d.id AS document_id,i.id AS item_id
FROM item_stage s JOIN doc_stage sd ON sd.doc_type=s.doc_type AND sd.legacy_id=s.bill_legacy_id
LEFT JOIN warehouse_target_stage source_side ON source_side.legacy_id=sd.stock_legacy_id
LEFT JOIN warehouse_target_stage target_side ON target_side.legacy_id=NULLIF(sd.to_stock_legacy_id,0)
LEFT JOIN goods g ON g.legacy_id=s.goods_legacy_id
LEFT JOIN colors c ON c.legacy_id=NULLIF(s.color_legacy_id,0)
LEFT JOIN units u ON u.legacy_id=NULLIF(s.unit_legacy_id,0)
LEFT JOIN stock_documents d ON d.doc_type=s.doc_type AND d.legacy_id=s.bill_legacy_id
LEFT JOIN stock_document_items i ON i.doc_id=d.id AND i.bill_type=s.doc_type AND i.legacy_id=s.legacy_id)
SELECT resolved.*,
       CASE WHEN source_action='DROP' OR target_action='DROP' THEN 'DROPPED_WAREHOUSE_DOCUMENT'
            WHEN (source_action='SPLIT' OR target_action='SPLIT') AND expected_item_warehouse_id IS NULL
                THEN 'UNASSIGNED_OWNING_WAREHOUSE' END AS expected_exclusion_reason,
       CASE WHEN source_action='DROP' THEN stock_legacy_id WHEN target_action='DROP' THEN to_stock_legacy_id
            WHEN source_action='SPLIT' THEN stock_legacy_id ELSE to_stock_legacy_id END AS exclusion_warehouse_legacy_id
FROM resolved;
ANALYZE rehearsal_stock_movement_candidates;

DO $stock_movement_exclusion_facts$
BEGIN
    IF EXISTS((SELECT source_file,item_legacy_id::text,exclusion_warehouse_legacy_id,expected_exclusion_reason,
                      goods_legacy_id,source_qty,source_amount
               FROM rehearsal_stock_movement_candidates WHERE expected_exclusion_reason IS NOT NULL
               EXCEPT ALL
               SELECT source_file,source_row_id,legacy_warehouse_id,reason,goods_legacy_id,qty,amount
               FROM bootstrap_warehouse_exclusions WHERE source_file IN(
                   'stock_transfer_i.csv','stock_other_in_i.csv','stock_other_out_i.csv','stock_draw_i.csv',
                   'stock_wdraw_i.csv','stock_finished_in_i.csv','stock_finished_out_i.csv','stock_check_i.csv'))
        UNION ALL
              (SELECT source_file,source_row_id,legacy_warehouse_id,reason,goods_legacy_id,qty,amount
               FROM bootstrap_warehouse_exclusions WHERE source_file IN(
                   'stock_transfer_i.csv','stock_other_in_i.csv','stock_other_out_i.csv','stock_draw_i.csv',
                   'stock_wdraw_i.csv','stock_finished_in_i.csv','stock_finished_out_i.csv','stock_check_i.csv')
               EXCEPT ALL
               SELECT source_file,item_legacy_id::text,exclusion_warehouse_legacy_id,expected_exclusion_reason,
                      goods_legacy_id,source_qty,source_amount
               FROM rehearsal_stock_movement_candidates WHERE expected_exclusion_reason IS NOT NULL)) THEN
        RAISE EXCEPTION 'stock document exclusions differ from independently resolved original warehouse/source facts';
    END IF;
END;
$stock_movement_exclusion_facts$;

CREATE TEMP TABLE rehearsal_stock_movement_source ON COMMIT DROP AS
SELECT * FROM rehearsal_stock_movement_candidates WHERE expected_exclusion_reason IS NULL;
-- Refresh each derived relation before its independent full-set validation.
ANALYZE rehearsal_stock_movement_source;

DO $stock_movement_source_facts$
BEGIN
    IF EXISTS(SELECT 1 FROM rehearsal_stock_movement_source s
        LEFT JOIN stock_documents d ON d.id=s.document_id LEFT JOIN stock_document_items i ON i.id=s.item_id
        WHERE d.id IS NULL OR i.id IS NULL OR s.goods_id IS NULL
           OR d.status IS DISTINCT FROM s.status OR d.bill_date IS DISTINCT FROM s.bill_date
           OR d.warehouse_id IS DISTINCT FROM s.source_warehouse_id
           OR d.to_warehouse_id IS DISTINCT FROM s.target_warehouse_id
           OR i.goods_id IS DISTINCT FROM s.goods_id OR i.color_id IS DISTINCT FROM s.color_id OR i.unit_id IS DISTINCT FROM s.unit_id
           OR i.warehouse_id IS DISTINCT FROM s.expected_item_warehouse_id
           OR i.qty IS DISTINCT FROM s.source_qty OR i.unit_rate IS DISTINCT FROM s.effective_unit_rate
           OR i.base_qty IS DISTINCT FROM s.expected_base_qty
           OR i.amount_original IS DISTINCT FROM s.source_amount OR i.amount_local IS DISTINCT FROM s.source_amount) THEN
        RAISE EXCEPTION 'stock source item quantity/rate/amount/identity/warehouse facts changed or disappeared';
    END IF;
    IF EXISTS(SELECT 1 FROM stock_document_items i WHERE NOT EXISTS(
        SELECT 1 FROM rehearsal_stock_movement_source s WHERE s.item_id=i.id)) THEN
        RAISE EXCEPTION 'stock target item lacks an exact retained original source';
    END IF;
    IF EXISTS(SELECT 1 FROM rehearsal_stock_movement_source s WHERE s.status=1 AND s.expected_base_qty<0
        AND ((s.doc_type IN('OTHER_IN','OTHER_OUT','DRAW','WDRAW','FINISHED_IN','FINISHED_OUT') AND s.source_warehouse_id IS NOT NULL)
          OR(s.doc_type='TRANSFER' AND(s.source_warehouse_id IS NOT NULL OR s.target_warehouse_id IS NOT NULL)))) THEN
        RAISE EXCEPTION 'negative original base quantity cannot be reinterpreted as a positive stock movement'
            USING ERRCODE='23514',CONSTRAINT='legacy_stock_movement_source_quantity_guard';
    END IF;
END;
$stock_movement_source_facts$;

CREATE TEMP TABLE rehearsal_stock_movement_expected ON COMMIT DROP AS
SELECT s.bill_date::timestamptz AS transaction_date,
       CASE s.doc_type WHEN 'OTHER_IN' THEN 11 WHEN 'OTHER_OUT' THEN 12 WHEN 'DRAW' THEN 5
          WHEN 'WDRAW' THEN 6 WHEN 'FINISHED_IN' THEN 13 WHEN 'FINISHED_OUT' THEN 14 END::smallint AS movement_type,
       'STOCK_DOC'::text AS source_doc_type,s.document_id AS source_doc_id,s.item_id AS source_item_id,
       s.goods_id,s.color_id,COALESCE(s.expected_item_warehouse_id,s.source_warehouse_id) AS warehouse_id,
       CASE WHEN s.doc_type IN('OTHER_IN','WDRAW','FINISHED_IN') THEN 1 ELSE -1 END::smallint AS direction,
       s.expected_base_qty AS qty,s.unit_id,s.effective_unit_rate AS unit_rate,s.source_amount AS amount_local
FROM rehearsal_stock_movement_source s
WHERE s.status=1 AND s.doc_type IN('OTHER_IN','OTHER_OUT','DRAW','WDRAW','FINISHED_IN','FINISHED_OUT')
  AND s.source_warehouse_id IS NOT NULL AND s.expected_base_qty>0
UNION ALL
SELECT s.bill_date::timestamptz,8::smallint,'STOCK_DOC',s.document_id,s.item_id,s.goods_id,s.color_id,
       CASE WHEN s.source_warehouse_id=fn_warehouse_root_id() THEN s.expected_item_warehouse_id ELSE s.source_warehouse_id END,
       (-1)::smallint,s.expected_base_qty,s.unit_id,s.effective_unit_rate,NULL::numeric
FROM rehearsal_stock_movement_source s
WHERE s.status=1 AND s.doc_type='TRANSFER' AND s.source_warehouse_id IS NOT NULL AND s.expected_base_qty>0
UNION ALL
SELECT s.bill_date::timestamptz,7::smallint,'STOCK_DOC',s.document_id,s.item_id,s.goods_id,s.color_id,
       CASE WHEN s.target_warehouse_id=fn_warehouse_root_id() THEN s.expected_item_warehouse_id ELSE s.target_warehouse_id END,
       1::smallint,s.expected_base_qty,s.unit_id,s.effective_unit_rate,NULL::numeric
FROM rehearsal_stock_movement_source s
WHERE s.status=1 AND s.doc_type='TRANSFER' AND s.target_warehouse_id IS NOT NULL AND s.expected_base_qty>0
UNION ALL
SELECT s.bill_date::timestamptz,CASE WHEN s.surplus_qty>0 THEN 9 ELSE 10 END::smallint,'STOCK_DOC',s.document_id,s.item_id,
       s.goods_id,s.color_id,COALESCE(s.expected_item_warehouse_id,s.source_warehouse_id),
       CASE WHEN s.surplus_qty>0 THEN 1 ELSE -1 END::smallint,abs(s.surplus_qty),s.unit_id,s.effective_unit_rate,NULL::numeric
FROM rehearsal_stock_movement_source s
WHERE s.status=1 AND s.doc_type='CHECK' AND s.source_warehouse_id IS NOT NULL AND s.surplus_qty IS NOT NULL AND s.surplus_qty<>0;

CREATE TEMP TABLE rehearsal_stock_movement_actual ON COMMIT DROP AS
SELECT transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,goods_id,color_id,warehouse_id,
       direction,qty,unit_id,unit_rate,amount_local
FROM stock_movements WHERE source_doc_type='STOCK_DOC';
ANALYZE rehearsal_stock_movement_expected;
ANALYZE rehearsal_stock_movement_actual;

CREATE TEMP TABLE bootstrap_stock_movement_nonposting (
    run_id uuid NOT NULL,source_file text NOT NULL,source_file_sha256 char(64) NOT NULL,source_row_sha256 char(64) NOT NULL,
    doc_type text NOT NULL,document_legacy_id integer NOT NULL,item_legacy_id integer NOT NULL,
    document_id uuid NOT NULL,item_id uuid NOT NULL,qty numeric,unit_rate numeric,base_qty numeric NOT NULL,
    amount_original numeric,amount_local numeric,reason text NOT NULL,
    PRIMARY KEY(source_file,item_legacy_id)) ON COMMIT DROP;
INSERT INTO bootstrap_stock_movement_nonposting
SELECT current_setting('uten.bootstrap_run_id')::uuid,s.source_file,f.sha256,s.source_row_sha256,
       s.doc_type,s.document_legacy_id,s.item_legacy_id,s.document_id,s.item_id,s.source_qty,s.source_unit_rate,
       s.expected_base_qty,s.source_amount,s.source_amount,'NONPOSTING_ZERO_QUANTITY'
FROM rehearsal_stock_movement_source s
LEFT JOIN legacy_migration_run_files f ON f.run_id=current_setting('uten.bootstrap_run_id')::uuid AND f.file_name=s.source_file
WHERE s.status=1 AND s.expected_base_qty=0
  AND ((s.doc_type IN('OTHER_IN','OTHER_OUT','DRAW','WDRAW','FINISHED_IN','FINISHED_OUT') AND s.source_warehouse_id IS NOT NULL)
    OR(s.doc_type='TRANSFER' AND(s.source_warehouse_id IS NOT NULL OR s.target_warehouse_id IS NOT NULL)));
ANALYZE bootstrap_stock_movement_nonposting;
-- The target movement table is still cold inside this atomic import. Keep
-- the original existence guard bounded with an index on its small TEMP side.
CREATE INDEX rehearsal_stock_nonposting_item_lookup
    ON bootstrap_stock_movement_nonposting(item_id);

DO $stock_movement_ledger_checks$
BEGIN
    IF EXISTS((SELECT * FROM rehearsal_stock_movement_expected EXCEPT ALL SELECT * FROM rehearsal_stock_movement_actual)
        UNION ALL(SELECT * FROM rehearsal_stock_movement_actual EXCEPT ALL SELECT * FROM rehearsal_stock_movement_expected)) THEN
        RAISE EXCEPTION 'stock movement ledger differs from original per-item/date/direction/warehouse/unit/amount facts';
    END IF;
    IF EXISTS(SELECT 1 FROM bootstrap_stock_movement_nonposting p JOIN stock_movements m
        ON m.source_doc_type='STOCK_DOC' AND m.source_item_id=p.item_id) THEN
        RAISE EXCEPTION 'zero base-quantity source item produced a stock movement';
    END IF;
END;
$stock_movement_ledger_checks$;

DO $stock_movement_record_results$
DECLARE result jsonb; changed integer;
BEGIN
    SELECT jsonb_build_object('passed',true,'validationVersion','stock-source-movements-v1',
      'retainedSourceItems',(SELECT count(*) FROM rehearsal_stock_movement_source),
      'expectedMovements',(SELECT count(*) FROM rehearsal_stock_movement_expected),
      'matchedMovements',(SELECT count(*) FROM rehearsal_stock_movement_actual),
      'exactPerItemIdentityQuantityDirectionWarehouseAmount',true,'zeroQuantityMovementCount',0,
      'nonpostingItems',(SELECT count(*) FROM bootstrap_stock_movement_nonposting),
      'nonpostingNonzeroAmountItems',(SELECT count(*) FROM bootstrap_stock_movement_nonposting WHERE COALESCE(amount_original,0)<>0 OR COALESCE(amount_local,0)<>0),
      'nonpostingFactsSha256',(SELECT encode(digest(COALESCE(jsonb_agg(to_jsonb(p) ORDER BY source_file,item_legacy_id),'[]'::jsonb)::text,'sha256'),'hex') FROM bootstrap_stock_movement_nonposting p),
      'entriesPersisted',false,'nonpostingPolicy','keep original source items and amounts; zero physical quantity does not create a stock event; no fake quantity',
      'checkQuantityPolicy','CHECK movements use signed surplus direction and ABS(surplus), independently of line base quantity') INTO result;
    UPDATE legacy_migration_runs SET reconciliation_summary=COALESCE(reconciliation_summary,'{}'::jsonb)||jsonb_build_object('stockMovementChecks',result)
    WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid AND status='RUNNING' AND migration_mode='BOOTSTRAP';
    GET DIAGNOSTICS changed=ROW_COUNT;
    IF changed<>1 THEN RAISE EXCEPTION 'stock movement result requires one running bootstrap claim'; END IF;
END;
$stock_movement_record_results$;
