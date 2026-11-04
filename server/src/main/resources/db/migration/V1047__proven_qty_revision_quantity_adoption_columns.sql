-- V1033's adoption trigger (trg_00_document_quantity_adoption, BEFORE UPDATE,
-- fires before trg_guard_*_order_commercial_items) rewrites the derived charged/
-- gift base quantities and freezes the operation's precision evidence whenever
-- qty changes. The sanctioned finance-reviewed quantity revision therefore now
-- also changes those trigger-maintained columns; the proven-revision predicate
-- must whitelist exactly those columns and verify their deterministic adoption
-- instead of rejecting the whole guarded update as independently frozen facts.
DO $proven_qty_adoption$
DECLARE definition text;needle text;
BEGIN
 SELECT pg_get_functiondef('fn_is_proven_procurement_qty_revision(text,jsonb,jsonb)'::regprocedure) INTO definition;

 needle:='''qty'',''amount_original'',''amount_local'',''total_amount_input'',''updated_at'',''updated_by''';
 IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>2 THEN
  RAISE EXCEPTION 'V1047 quantity revision whitelist anchor differs';END IF;
 definition:=replace(definition,needle,
  '''qty'',''amount_original'',''amount_local'',''total_amount_input'',''charged_base_qty'',''gift_base_qty'',''quantity_precision_policy'',''quantity_adoption_version'',''updated_at'',''updated_by''');

 needle:='DECLARE prefix TEXT; kind TEXT; exchange NUMERIC; expected_original NUMERIC; expected_local NUMERIC;';
 IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
  RAISE EXCEPTION 'V1047 quantity revision declaration anchor differs';END IF;
 definition:=replace(definition,needle,
  'DECLARE prefix TEXT; kind TEXT; exchange NUMERIC; expected_original NUMERIC; expected_local NUMERIC; expected_charged NUMERIC; expected_gift_base NUMERIC;');

 -- Dividing by one adopts the exact original product (fn_document_quantity_to_base),
 -- so the derived bases are deterministic functions of the new qty, the unchanged
 -- unit rate, semantics and gift operand. Only purchase items carry these columns.
 needle:='RETURN expected_original IS NOT NULL AND expected_original=(p_new->>''amount_original'')::numeric';
 IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
  RAISE EXCEPTION 'V1047 quantity revision return anchor differs';END IF;
 definition:=replace(definition,needle,
  'IF prefix=''purchase'' THEN
    IF (p_new->>''quantity_adoption_version'')<>''2'' OR p_new->''quantity_precision_policy'' IS NULL THEN RETURN FALSE; END IF;
    expected_charged:=(p_new->>''qty'')::numeric*(p_old->>''unit_rate'')::numeric;
    expected_gift_base:=((p_new->>''qty'')::numeric+CASE WHEN p_old->>''quantity_semantics''=''CHARGED_PLUS_GIFT_V1'' THEN (p_old->>''gift_qty'')::numeric ELSE 0 END)*(p_old->>''unit_rate'')::numeric-expected_charged;
    IF (p_new->>''charged_base_qty'')::numeric IS DISTINCT FROM expected_charged
        OR (p_new->>''gift_base_qty'')::numeric IS DISTINCT FROM expected_gift_base THEN RETURN FALSE; END IF;
  END IF;
  RETURN expected_original IS NOT NULL AND expected_original=(p_new->>''amount_original'')::numeric');

 EXECUTE definition;
END $proven_qty_adoption$;
