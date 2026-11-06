-- A real marker already visible in this transaction proves the original
-- ON CONFLICT no-op. Read that durable key before scheduling another writer;
-- no session flag/cache, domain lock, source-row or authorization shortcut.
CREATE FUNCTION fn_summary_read_domains_marked(p_domains text[]) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT p_domains IS NOT NULL AND cardinality(p_domains)>0 AND NOT EXISTS(
  SELECT 1 FROM unnest(p_domains) requested(domain)
  WHERE requested.domain IS NULL OR NOT EXISTS(
   SELECT 1 FROM public.summary_read_markers marker
   WHERE marker.domain=requested.domain AND marker.transaction_id=txid_current_if_assigned()))
$$;
COMMENT ON FUNCTION fn_summary_read_domains_marked(text[]) IS
 'Metadata-only proof of this transaction''s actual markers for every requested domain; never source payload or authorization.';

-- A partial domain set still invokes the sole writer. Do not attempt an INSERT
-- (and its owner guard) for domains already proved by their actual marker.
CREATE OR REPLACE FUNCTION fn_mark_summary_read_domain() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE domain_name text;
BEGIN
 IF TG_OP IN ('INSERT','UPDATE') THEN
  IF NOT EXISTS(SELECT 1 FROM summary_new_rows) THEN RETURN NULL; END IF;
 ELSIF TG_OP='DELETE' THEN
  IF NOT EXISTS(SELECT 1 FROM summary_old_rows) THEN RETURN NULL; END IF;
 END IF;
 FOREACH domain_name IN ARRAY TG_ARGV LOOP
  INSERT INTO public.summary_read_markers(domain,transaction_id)
  SELECT domain_name,txid_current()
  WHERE NOT EXISTS(SELECT 1 FROM public.summary_read_markers marker
   WHERE marker.domain=domain_name AND marker.transaction_id=txid_current())
  ON CONFLICT DO NOTHING;
 END LOOP;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION fn_mark_summary_read_domain() FROM PUBLIC;

-- The canonical migration-owner entry for newly installed statement triggers.
-- Existing caller predicates remain intact. All currently unqualified native
-- triggers share this gate, preserving arguments, transition tables and mode.
CREATE FUNCTION fn_refresh_summary_read_marker_gates() RETURNS integer
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE item record; arguments text[]; argument_start integer; offset_index integer;
 definition text; anchor text:=' FOR EACH STATEMENT EXECUTE FUNCTION '; changed integer:=0;
BEGIN
 FOR item IN
  SELECT trigger_row.*,namespace.nspname,relation.relname,
   pg_get_triggerdef(trigger_row.oid,true) original_definition,
   obj_description(trigger_row.oid,'pg_trigger') original_comment
  FROM pg_trigger trigger_row JOIN pg_class relation ON relation.oid=trigger_row.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND NOT trigger_row.tgisinternal
   AND trigger_row.tgfoid='public.fn_mark_summary_read_domain()'::regprocedure
   AND (trigger_row.tgtype & 1)=0 AND trigger_row.tgqual IS NULL
  ORDER BY relation.relname,trigger_row.tgname
 LOOP
  arguments:=ARRAY[]::text[];argument_start:=0;
  FOR offset_index IN 0..octet_length(item.tgargs)-1 LOOP
   IF get_byte(item.tgargs,offset_index)=0 THEN
    arguments:=array_append(arguments,convert_from(substring(item.tgargs FROM argument_start+1 FOR offset_index-argument_start),'UTF8'));
    argument_start:=offset_index+1;
   END IF;
  END LOOP;
  IF cardinality(arguments)<>item.tgnargs OR item.tgnargs=0 OR argument_start<>octet_length(item.tgargs) THEN
   RAISE EXCEPTION 'Summary marker trigger arguments differ from their catalog boundary';
  END IF;
  definition:=item.original_definition;
  IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
   RAISE EXCEPTION 'Summary marker statement boundary differs';
  END IF;
  definition:=replace(definition,anchor,' FOR EACH STATEMENT WHEN (NOT public.fn_summary_read_domains_marked('
   ||format('%L::text[]',arguments)||')) EXECUTE FUNCTION ');
  EXECUTE format('DROP TRIGGER %I ON %I.%I',item.tgname,item.nspname,item.relname);
  EXECUTE definition;
  EXECUTE format('ALTER TABLE %I.%I %s TRIGGER %I',item.nspname,item.relname,
   CASE item.tgenabled WHEN 'A' THEN 'ENABLE ALWAYS' WHEN 'R' THEN 'ENABLE REPLICA'
    WHEN 'D' THEN 'DISABLE' WHEN 'O' THEN 'ENABLE' ELSE NULL END,item.tgname);
  IF item.original_comment IS NOT NULL THEN
   EXECUTE format('COMMENT ON TRIGGER %I ON %I.%I IS %L',item.tgname,item.nspname,item.relname,item.original_comment);
  END IF;
  changed:=changed+1;
 END LOOP;
 RETURN changed;
END $$;
REVOKE ALL ON FUNCTION fn_refresh_summary_read_marker_gates() FROM PUBLIC;
SELECT fn_refresh_summary_read_marker_gates();
