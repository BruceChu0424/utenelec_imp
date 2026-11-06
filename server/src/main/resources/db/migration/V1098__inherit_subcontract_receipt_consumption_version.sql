-- Reversal creates a fresh draft UUID through the established, database-owned
-- document_unapprovals lineage. An unchanged successor inherits the historical
-- consumption rule; an unrelated new actual receipt always starts at version 2.
DO $$ DECLARE definition TEXT; anchor TEXT; BEGIN
  definition:=pg_get_functiondef('fn_unapproval_frozen_fields(text,jsonb)'::regprocedure);
  anchor:=' RETURN result;';
  IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
    RAISE EXCEPTION 'V1098 unapproval frozen-field return anchor differs';
  END IF;
  definition:=replace(definition,anchor,E' IF p_table=''subcontract_receipt_items'' THEN\n'
    ||E'  IF (p_source->>''material_consumption_version'')::integer IS NULL\n'
    ||E'    OR (p_source->>''material_consumption_version'')::integer NOT IN(1,2) THEN\n'
    ||E'   RAISE EXCEPTION ''original subcontract consumption rule is unavailable'' USING ERRCODE=''55000''; END IF;\n'
    ||E'  result:=result||jsonb_build_object(''material_consumption_version'',p_source->''material_consumption_version'');\n'
    ||E' END IF;\n'||anchor);
  EXECUTE definition;
END $$;

CREATE OR REPLACE FUNCTION fn_guard_subcontract_receipt_consumption_version()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original JSONB;
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.unapproval_source_item_id IS NOT NULL THEN
      -- Reuse the exact source/header/input/actor/transaction/line-map proof.
      -- The earlier trg_000_unapproval_source_item has already copied the frozen fields.
      original:=fn_unapproval_source_item(TG_TABLE_NAME,to_jsonb(NEW));
      IF original IS NULL OR NEW.material_consumption_version IS DISTINCT FROM
            (original->>'material_consumption_version')::smallint THEN
        RAISE EXCEPTION 'subcontract successor must retain its proven original consumption rule'
          USING ERRCODE='23514';
      END IF;
    ELSIF NEW.material_consumption_version<>2 THEN
      RAISE EXCEPTION 'new subcontract receipts must use actual base material consumption' USING ERRCODE='23514';
    END IF;
  ELSIF NEW.material_consumption_version IS DISTINCT FROM OLD.material_consumption_version THEN
    RAISE EXCEPTION 'subcontract receipt material consumption version is immutable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
