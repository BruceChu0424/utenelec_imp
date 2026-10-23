-- qtfymc is an original M_Style identity (View_M_Get joins it explicitly).
-- An old INCOME node cannot become a current typed EXPENSE by coincidence.
-- Preserve its original ID and fee amount without guessing a replacement.
ALTER TABLE public.finance_receipts ADD COLUMN other_fee_style_legacy_id integer
    CHECK(other_fee_style_legacy_id IS NULL OR other_fee_style_legacy_id>0);
COMMENT ON COLUMN public.finance_receipts.other_fee_style_legacy_id IS
    'Immutable original positive M_Get.qtfymc / M_Style.ID from a complete same-transaction source proof. Not a current expense authority. A non-expense/missing original node leaves other_fee_style_id NULL for review.';

-- V626 stays applied byte-for-byte. The original complete typed source and its
-- row/file SHA are unchanged. Its registrar includes this new payload field in
-- target_fields and target_snapshot_sha256 automatically.
DO $projection$
DECLARE definition text; anchor text; replacement text;
BEGIN
    definition:=replace(pg_get_functiondef('public.fn_legacy_finance_cash_projection(text,jsonb,integer)'::regprocedure),E'\r\n',E'\n');
    anchor:=E'        IF p_kind=''RECEIPT'' THEN\n            payload:=payload||jsonb_build_object(''receipt_kind'',''LEGACY_UNCLASSIFIED'',''settlement_authority_version'',0,';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V912 original receipt projection entry anchor differs';
    END IF;
    replacement:=E'        IF p_kind=''RECEIPT'' THEN\n'
        ||E'            IF (s->>''qtfymc'')::integer<0 THEN\n'
        ||E'                RAISE EXCEPTION ''negative original other-fee style identity requires source review'' USING ERRCODE=''23514'';\n'
        ||E'            END IF;\n'
        ||E'            payload:=payload||jsonb_build_object(''receipt_kind'',''LEGACY_UNCLASSIFIED'',''settlement_authority_version'',0,';
    definition:=replace(definition,anchor,replacement);
    anchor:='''other_fee_style_id'',(SELECT id FROM public.payment_styles WHERE legacy_id=NULLIF((s->>''qtfymc'')::integer,0)));';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V912 original other-fee style projection anchor differs';
    END IF;
    replacement:='''other_fee_style_legacy_id'',CASE WHEN (s->>''qtfymc'')::integer>0 THEN (s->>''qtfymc'')::integer ELSE NULL END,'
        ||E'\n                ''other_fee_style_id'',(SELECT id FROM public.payment_styles WHERE legacy_id=NULLIF((s->>''qtfymc'')::integer,0) AND category=''EXPENSE''));';
    EXECUTE replace(definition,anchor,replacement);
END;
$projection$;

-- This is a historical source identity, not an online selection. Old proofs
-- without the new field keep NULL; no original row is retroactively rewritten.
CREATE FUNCTION public.fn_guard_legacy_receipt_other_fee_style_snapshot() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE proof public.legacy_finance_import_sources%ROWTYPE; original_expense_ids uuid[];
BEGIN
    IF TG_OP='UPDATE' THEN
        IF NEW.other_fee_style_legacy_id IS DISTINCT FROM OLD.other_fee_style_legacy_id THEN
            RAISE EXCEPTION 'original other-fee style identity cannot be added, changed or cleared'
                USING ERRCODE='23514',CONSTRAINT=TG_NAME;
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.other_fee_style_legacy_id IS NULL THEN RETURN NEW; END IF;
    IF NEW.other_fee_style_legacy_id<=0 OR NEW.legacy_import_run_id IS NULL OR NEW.legacy_id IS NULL
       OR NEW.receipt_kind IS DISTINCT FROM 'LEGACY_UNCLASSIFIED' OR NEW.settlement_authority_version IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'original other-fee style identity requires complete original receipt evidence'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    EXECUTE 'SELECT * FROM public.legacy_finance_import_sources '
        'WHERE run_id=$1 AND target_id=$2 AND target_table=''finance_receipts'' AND source_legacy_id=$3'
        INTO proof USING NEW.legacy_import_run_id,NEW.id,NEW.legacy_id;
    IF proof.id IS NULL OR proof.source_kind IS DISTINCT FROM 'RECEIPT' OR proof.source_file IS DISTINCT FROM 'm_get.csv'
       OR proof.issued_txid<>txid_current()
       OR NOT ('other_fee_style_legacy_id'=ANY(proof.target_fields)) OR NOT ('other_fee_style_id'=ANY(proof.target_fields))
       OR proof.source_file_sha256 IS DISTINCT FROM (SELECT sha256 FROM public.legacy_migration_run_files
            WHERE run_id=proof.run_id AND file_name=proof.source_file) THEN
        RAISE EXCEPTION 'original other-fee style identity has no exact new-field proof for this source and transaction'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    PERFORM public.fn_assert_legacy_finance_import('finance_receipts',to_jsonb(NEW));
    -- Match the existing historical lane: identity and category are mandatory;
    -- current active/leaf selection rules remain the ordinary runtime guard's
    -- concern. Do not replace a historical EXPENSE with a different live leaf.
    SELECT array_agg(id) INTO original_expense_ids FROM public.payment_styles
        WHERE legacy_id=NEW.other_fee_style_legacy_id AND category='EXPENSE';
    IF COALESCE(cardinality(original_expense_ids),0)>1 OR NEW.other_fee_style_id IS DISTINCT FROM original_expense_ids[1] THEN
        RAISE EXCEPTION 'original other-fee style must resolve only to its exact expense identity or remain unclassified'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_zy_legacy_receipt_other_fee_style_snapshot BEFORE INSERT OR UPDATE
    ON public.finance_receipts FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_receipt_other_fee_style_snapshot();
ALTER TABLE public.finance_receipts ENABLE ALWAYS TRIGGER trg_zy_legacy_receipt_other_fee_style_snapshot;

-- A derived review queue joins these original IDs to the existing immutable
-- run/row/file proof. It does not create expenses, approvals, GL or cash flows.
CREATE INDEX ix_finance_receipt_original_other_fee_style_gap
    ON public.finance_receipts(legacy_import_run_id,other_fee_style_legacy_id)
    WHERE other_fee_style_legacy_id IS NOT NULL AND other_fee_style_id IS NULL;
