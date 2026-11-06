-- Unchanged receipt/payment clones retain their actual source policy. The
-- first transaction must copy the complete source; later edits are new work.
ALTER TABLE finance_payment_lines ADD COLUMN unapproval_source_item_id uuid;
ALTER TABLE finance_receipt_lines ADD COLUMN unapproval_source_item_id uuid;

CREATE FUNCTION fn_financial_unapproval_owner(p_table text,p_family text DEFAULT NULL)
RETURNS TABLE(item_table text,family text,header_table text,parent_column text)
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog,public AS $$
 SELECT * FROM (VALUES
  ('finance_payment_lines','financePayment','finance_payments','payment_id'),
  ('finance_receipt_lines','financeReceipt','finance_receipts','receipt_id')
 ) owner(item_table,family,header_table,parent_column)
 WHERE (p_table IS NULL OR owner.item_table=p_table) AND (p_family IS NULL OR owner.family=p_family)
$$;

CREATE FUNCTION fn_financial_unapproval_generated_line_columns() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
 SELECT ARRAY['id','legacy_id','payment_id','receipt_id','bill_no','created_at','updated_at','created_by','updated_by',
  'business_precision_policy','unapproval_source_item_id','balance_before_original','balance_after_original',
  'book_balance_before_local','book_balance_after_local']
$$;

CREATE FUNCTION fn_unapproval_financial_headers_match(p_table text,old_header jsonb,new_header jsonb,
 p_original uuid,p_complete boolean DEFAULT false) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog,public AS $$
DECLARE header_fields text[];field text;
BEGIN
 IF p_table='finance_payment_lines' THEN
  header_fields:=ARRAY['bill_date','supplier_id','account_id','counterpart_account_id','currency_id','exchange_rate',
   'amount_original','amount_local','account_currency_id','account_exchange_rate','account_amount','account_amount_local',
   'bank_fee_account_amount','bank_fee_local','bank_reference','bank_booked_at','gl_account_style_id','gl_ap_style_id',
   'gl_fx_style_id','gl_bank_fee_style_id','payment_method_id','payment_method_legacy_id','invoice_no','operator_name',
   'operator_id','maker_id','source_remark','remark'];
 ELSIF p_table='finance_receipt_lines' THEN
  header_fields:=ARRAY['bill_date','client_id','receipt_kind','sales_order_id','order_selection_version','account_id',
   'counterpart_account_id','currency_id','exchange_rate','amount_original','amount_local','bank_fee','other_fee',
   'other_fee_style_id','receipt_method_id','receipt_method_legacy_id','invoice_no','operator_id','maker_id','source_remark',
   'remark','settlement_authority_version','settlement_channel','settlement_agent_supplier_id',
   'settlement_agent_name_snapshot','settlement_rate_quote_direction','exchange_rate_source','exchange_rate_effective_at',
   'bank_booked_at','bank_reference','agent_statement_no','account_currency_id','account_exchange_rate',
   'account_exchange_rate_source','account_amount','account_amount_local','bank_fee_account_amount','other_fee_account_amount',
   'fee_settlement_mode','fee_bearer','fee_payment_account_id','fee_account_currency_id','fee_account_exchange_rate',
   'gl_account_style_id','gl_counter_style_id','gl_bank_fee_style_id','gl_fx_style_id','gl_fee_payment_style_id'];
 ELSE RETURN false; END IF;

 IF old_header->>'status' IS DISTINCT FROM '-1' OR new_header->>'status' IS DISTINCT FROM '0'
  OR new_header->>'created_by' IS DISTINCT FROM old_header->>'created_by'
  OR new_header->>'create_request_hash' IS DISTINCT FROM COALESCE(old_header->>'create_request_hash',
      encode(digest(p_original::text,'sha256'),'hex'))
  OR p_complete AND p_table='finance_payment_lines'
     AND old_header->'amount_authority_version' IS DISTINCT FROM new_header->'amount_authority_version' THEN RETURN false; END IF;
 FOREACH field IN ARRAY header_fields LOOP
  IF old_header->field IS DISTINCT FROM new_header->field THEN RETURN false; END IF;
 END LOOP;
 RETURN true;
END $$;

CREATE FUNCTION fn_unapproval_financial_line_policy(p_table text,p_new jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE profile record;source_row jsonb;old_header jsonb;new_header jsonb;
 lineage document_unapprovals%ROWTYPE;ignored text[]:=fn_financial_unapproval_generated_line_columns();
BEGIN
 SELECT * INTO profile FROM fn_financial_unapproval_owner(p_table);
 IF p_table IS NULL OR NOT FOUND THEN RAISE EXCEPTION 'unsupported financial unapproval owner' USING ERRCODE='55000'; END IF;
 lineage:=fn_unapproval_lineage_source(profile.family,(p_new->>profile.parent_column)::uuid,
  (p_new->>'unapproval_source_item_id')::uuid,(p_new->>'id')::uuid,(p_new->>'updated_by')::uuid,true);
 EXECUTE format('SELECT to_jsonb(line) FROM public.%I line WHERE id=$1 AND %I=$2 AND NOT is_deleted',p_table,profile.parent_column)
  INTO source_row USING (p_new->>'unapproval_source_item_id')::uuid,lineage.original_id;
 EXECUTE format('SELECT to_jsonb(header) FROM public.%I header WHERE id=$1 AND NOT is_deleted',profile.header_table)
  INTO old_header USING lineage.original_id;
 EXECUTE format('SELECT to_jsonb(header) FROM public.%I header WHERE id=$1 AND NOT is_deleted',profile.header_table)
  INTO new_header USING lineage.draft_id;
 IF source_row IS NULL OR NOT fn_unapproval_financial_headers_match(p_table,old_header,new_header,lineage.original_id)
   OR fn_imported_business_document(profile.header_table,lineage.original_id)
   OR (p_new-ignored) IS DISTINCT FROM (source_row-ignored)
   OR p_new->>'legacy_id' IS NOT NULL
   OR p_new->>'balance_before_original' IS NOT NULL OR p_new->>'balance_after_original' IS NOT NULL
   OR p_new->>'book_balance_before_local' IS NOT NULL OR p_new->>'book_balance_after_local' IS NOT NULL
   OR p_new->>'created_by' IS DISTINCT FROM source_row->>'created_by'
   OR p_new->>'bill_no' IS DISTINCT FROM new_header->>'bill_no' THEN
  RAISE EXCEPTION 'financial clone differs from its frozen original line or header' USING ERRCODE='55000'; END IF;
 IF p_new->>'business_precision_policy' IS NOT NULL
   AND p_new->'business_precision_policy' IS DISTINCT FROM source_row->'business_precision_policy' THEN
  RAISE EXCEPTION 'financial clone cannot replace its source precision policy' USING ERRCODE='55000'; END IF;
 -- Historical NULL keeps its original v1 proof semantics.
 RETURN NULLIF(source_row->'business_precision_policy','null'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION fn_guard_business_precision_policy() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE changed boolean;
BEGIN
 IF TG_OP='INSERT' THEN
  IF TG_TABLE_NAME IN('finance_payment_lines','finance_receipt_lines')
    AND to_jsonb(NEW)->>'unapproval_source_item_id' IS NOT NULL THEN
   NEW.business_precision_policy:=fn_unapproval_financial_line_policy(TG_TABLE_NAME,to_jsonb(NEW));
   RETURN NEW;
  END IF;
  IF NEW.business_precision_policy IS NOT NULL
    AND NEW.business_precision_policy<>fn_business_precision_snapshot() THEN
   RAISE EXCEPTION 'precision policy must come from the current business operation' USING ERRCODE='23514';END IF;
  NEW.business_precision_policy:=fn_business_precision_snapshot();
 ELSE
  IF NEW.business_precision_policy IS DISTINCT FROM OLD.business_precision_policy THEN
   RAISE EXCEPTION 'frozen precision policy cannot be independently edited' USING ERRCODE='55000';END IF;
  SELECT EXISTS(SELECT 1 FROM pg_attribute a WHERE a.attrelid=TG_RELID
    AND a.attnum>0 AND NOT a.attisdropped AND a.atttypid='numeric'::regtype
    AND (to_jsonb(NEW)->a.attname) IS DISTINCT FROM (to_jsonb(OLD)->a.attname)) INTO changed;
  IF changed THEN NEW.business_precision_policy:=fn_business_precision_snapshot();END IF;
 END IF;
 RETURN NEW;
END $$;

CREATE FUNCTION fn_guard_financial_unapproval_source_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF NEW.unapproval_source_item_id IS DISTINCT FROM OLD.unapproval_source_item_id THEN
  RAISE EXCEPTION 'financial unapproval source identity is immutable' USING ERRCODE='55000'; END IF;
 RETURN NEW;
END $$;
DO $financial_source_identity$ DECLARE target text; BEGIN
 FOREACH target IN ARRAY ARRAY['finance_payment_lines','finance_receipt_lines'] LOOP
  EXECUTE format('CREATE TRIGGER trg_00_financial_unapproval_source_identity BEFORE UPDATE OF unapproval_source_item_id ON public.%I FOR EACH ROW EXECUTE FUNCTION fn_guard_financial_unapproval_source_identity()',target);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_00_financial_unapproval_source_identity',target);
 END LOOP;
END $financial_source_identity$;


CREATE FUNCTION fn_assert_financial_unapproval_complete() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE profile record;source_count bigint;draft_count bigint;map_count bigint;invalid_line boolean;
 old_header jsonb;new_header jsonb;
BEGIN
 SELECT * INTO profile FROM fn_financial_unapproval_owner(NULL,NEW.family);
 IF NOT FOUND THEN RETURN NEW; END IF;
 IF NEW.created_txid IS DISTINCT FROM txid_current() OR NEW.created_by IS NULL THEN
  RAISE EXCEPTION 'financial clone completion requires its actual creation transaction' USING ERRCODE='55000'; END IF;
 EXECUTE format('SELECT to_jsonb(header) FROM public.%I header WHERE id=$1 AND NOT is_deleted',profile.header_table)
  INTO old_header USING NEW.original_id;
 EXECUTE format('SELECT to_jsonb(header) FROM public.%I header WHERE id=$1 AND NOT is_deleted',profile.header_table)
  INTO new_header USING NEW.draft_id;
 IF NOT fn_unapproval_financial_headers_match(profile.item_table,old_header,new_header,NEW.original_id,true)
   OR fn_imported_business_document(profile.header_table,NEW.original_id)
   OR new_header->>'bill_no' IS DISTINCT FROM NEW.draft_bill_no
   OR new_header->>'updated_by' IS DISTINCT FROM NEW.created_by::text THEN
  RAISE EXCEPTION 'financial clone completion differs from its actual original header' USING ERRCODE='55000'; END IF;
 EXECUTE format('SELECT count(*) FROM public.%I WHERE %I=$1 AND NOT is_deleted',profile.item_table,profile.parent_column)
  INTO source_count USING NEW.original_id;
 EXECUTE format('SELECT count(*) FROM public.%I WHERE %I=$1 AND NOT is_deleted',profile.item_table,profile.parent_column)
  INTO draft_count USING NEW.draft_id;
 SELECT count(*) INTO map_count FROM jsonb_each(NEW.line_id_map);
 -- Native customer/supplier advances may legitimately have no applied lines.
 -- Equal empty maps retain that header-only business; a nonempty source can
 -- never become an empty or partial successor. Header/state/authority proof
 -- above still applies to all of them.
 IF source_count<>draft_count OR source_count<>map_count THEN
  RAISE EXCEPTION 'financial clone has an incomplete original line map' USING ERRCODE='23514'; END IF;
 -- One indexed set join verifies all original identities and facts. No per-row
 -- provenance walk, reverse JSON scan, or newly selected rounding is involved.
 EXECUTE format($query$
  SELECT EXISTS(SELECT 1 FROM public.%1$I source LEFT JOIN public.%1$I draft
   ON draft.id=($3->>source.id::text)::uuid AND draft.%2$I=$2
   WHERE source.%2$I=$1 AND NOT source.is_deleted AND (
    draft.id IS NULL OR draft.is_deleted OR draft.unapproval_source_item_id IS DISTINCT FROM source.id
    OR draft.created_by IS DISTINCT FROM source.created_by OR draft.updated_by IS DISTINCT FROM $4
    OR draft.bill_no IS DISTINCT FROM $5 OR draft.legacy_id IS NOT NULL
    OR draft.balance_before_original IS NOT NULL OR draft.balance_after_original IS NOT NULL
    OR draft.book_balance_before_local IS NOT NULL OR draft.book_balance_after_local IS NOT NULL
    OR (to_jsonb(draft)-fn_financial_unapproval_generated_line_columns())
       IS DISTINCT FROM (to_jsonb(source)-fn_financial_unapproval_generated_line_columns())
    OR draft.business_precision_policy IS DISTINCT FROM source.business_precision_policy))
 $query$,profile.item_table,profile.parent_column)
 INTO invalid_line USING NEW.original_id,NEW.draft_id,NEW.line_id_map,NEW.created_by,NEW.draft_bill_no;
 IF invalid_line THEN RAISE EXCEPTION 'financial clone line identities or frozen inputs are incomplete'
  USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER document_unapproval_financial_source_complete
 AFTER INSERT ON document_unapprovals DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 EXECUTE FUNCTION fn_assert_financial_unapproval_complete();
ALTER TABLE document_unapprovals ENABLE ALWAYS TRIGGER document_unapproval_financial_source_complete;
