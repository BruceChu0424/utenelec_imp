-- Party removal is a visibility decision, not the end of historical business identity.
-- Keep is_deleted/status/UUID and all FK links unchanged so old orders and balances survive.
ALTER TABLE clients ADD COLUMN is_hidden boolean NOT NULL DEFAULT false;
ALTER TABLE clients ADD COLUMN hidden_at timestamptz;
ALTER TABLE suppliers ADD COLUMN is_hidden boolean NOT NULL DEFAULT false;
ALTER TABLE suppliers ADD COLUMN hidden_at timestamptz;
COMMENT ON COLUMN clients.is_hidden IS 'Hidden from master lists and new-document candidates; existing business references remain valid.';
COMMENT ON COLUMN suppliers.is_hidden IS 'Hidden from master lists and new-document candidates; existing business references remain valid.';

-- The existing snapshot capture records every changed column. Allow hide/restore to use
-- the same actor-owned undo/CAS path, without replacing any financial/owner allowlist.
DO $$ DECLARE definition text; anchor text := '''is_deleted'',''deleted_at'']'; BEGIN
 SELECT pg_get_functiondef('public.fn_master_history_unsupported(text,jsonb,jsonb)'::regprocedure) INTO definition;
 IF strpos(definition, anchor)=0 THEN RAISE EXCEPTION 'Cannot extend party hide history allowlist'; END IF;
 -- Only the two party branches receive these fields; all other master guard rules remain exact.
 definition := replace(definition,
  'WHEN ''clients'' THEN ARRAY[', 'WHEN ''clients'' THEN ARRAY[''is_hidden'',''hidden_at'',');
 definition := replace(definition,
  'WHEN ''suppliers'' THEN ARRAY[', 'WHEN ''suppliers'' THEN ARRAY[''is_hidden'',''hidden_at'',');
 EXECUTE definition;
END $$;

-- V885 retains complete row snapshots. Earlier party snapshots predate these
-- two columns. Supply only their exact schema defaults in read/replay views;
-- never rewrite the original before/after evidence or ignore any other key.
CREATE FUNCTION fn_party_master_history_schema(p_row jsonb,p_table text) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN p_row IS NULL THEN NULL
  WHEN p_table IN ('clients','suppliers') AND jsonb_typeof(p_row)='object'
   THEN jsonb_build_object('is_hidden',false,'hidden_at',NULL)||p_row
  ELSE p_row END
$$;

DO $history$
DECLARE definition text; anchors text[]; replacements text[]; i integer;
BEGIN
 definition:=replace(pg_get_functiondef('fn_replay_master_operation(uuid,uuid,bigint,boolean,uuid)'::regprocedure),chr(13),'');
 anchors:=ARRAY[
  'IF actual IS DISTINCT FROM r.expected_row THEN',
  'token:=CASE WHEN p_undo THEN r.before_token ELSE r.after_token END;',
  'target:=CASE WHEN p_undo THEN r.before_row ELSE r.after_row END;',
  'expected_row=token','before_token=token','after_token=token'
 ];
 replacements:=ARRAY[
  'IF actual IS DISTINCT FROM fn_party_master_history_schema(r.expected_row,r.table_name) THEN',
  'token:=fn_party_master_history_schema(CASE WHEN p_undo THEN r.before_token ELSE r.after_token END,r.table_name);',
  'target:=fn_party_master_history_schema(CASE WHEN p_undo THEN r.before_row ELSE r.after_row END,r.table_name);',
  'fn_party_master_history_schema(expected_row,table_name)=token',
  'fn_party_master_history_schema(before_token,table_name)=token',
  'fn_party_master_history_schema(after_token,table_name)=token'
 ];
 FOR i IN 1..cardinality(anchors) LOOP
  IF position(anchors[i] IN definition)=0 THEN
   RAISE EXCEPTION 'V995 party history schema anchor % changed',i;
  END IF;
  definition:=replace(definition,anchors[i],replacements[i]);
 END LOOP;
 EXECUTE definition;
END
$history$;
