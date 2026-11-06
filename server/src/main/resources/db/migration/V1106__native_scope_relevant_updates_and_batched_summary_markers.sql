-- Preserve the V942 authority columns as the sole dependency declaration.
-- Quantity/progress-only updates do not change any of those column values.
-- INSERT and DELETE keep their original callbacks and all trigger modes survive.
CREATE FUNCTION fn_refresh_native_scope_update_gates() RETURNS integer
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE item record; args text[]; begin_at integer; at_byte integer; field text;
 arguments text; predicate text; definition text; write_events text; changed integer:=0;
BEGIN
 FOR item IN
  SELECT t.*,n.nspname,c.relname,obj_description(t.oid,'pg_trigger') original_comment
  FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND NOT t.tgisinternal
   AND t.tgfoid='public.fn_mark_native_scope_columns()'::regprocedure
   AND (t.tgtype & 16)<>0 AND t.tgqual IS NULL
  ORDER BY c.relname,t.tgname
 LOOP
  IF (item.tgtype & 3)<>1 OR item.tgnargs<2 THEN
   RAISE EXCEPTION 'Unexpected native authorization trigger boundary';
  END IF;
  args:=ARRAY[]::text[];begin_at:=0;
  FOR at_byte IN 0..octet_length(item.tgargs)-1 LOOP
   IF get_byte(item.tgargs,at_byte)=0 THEN
    args:=array_append(args,convert_from(substring(item.tgargs FROM begin_at+1 FOR at_byte-begin_at),'UTF8'));
    begin_at:=at_byte+1;
   END IF;
  END LOOP;
  IF cardinality(args)<>item.tgnargs OR begin_at<>octet_length(item.tgargs) THEN
   RAISE EXCEPTION 'Native authorization trigger arguments differ from their catalog boundary';
  END IF;
  arguments:='';predicate:='';
  FOR at_byte IN 1..cardinality(args) LOOP
   arguments:=arguments||CASE WHEN at_byte=1 THEN '' ELSE ',' END||quote_literal(args[at_byte]);
   IF at_byte>1 THEN
    field:=args[at_byte];
    IF NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=item.tgrelid AND attname=field AND attnum>0 AND NOT attisdropped) THEN
     RAISE EXCEPTION 'Missing native authorization source %.%',item.relname,field;
    END IF;
    predicate:=predicate||CASE WHEN at_byte=2 THEN '' ELSE ' OR ' END
     ||format('OLD.%I IS DISTINCT FROM NEW.%I',field,field);
   END IF;
  END LOOP;
  EXECUTE format('DROP TRIGGER %I ON %I.%I',item.tgname,item.nspname,item.relname);
  -- Mixed-event triggers retain their original name for INSERT/DELETE. The
  -- new UPDATE event compares exactly the same catalog-declared attributes.
  write_events:=concat_ws(' OR ',CASE WHEN (item.tgtype & 4)<>0 THEN 'INSERT' END,
    CASE WHEN (item.tgtype & 8)<>0 THEN 'DELETE' END);
  IF write_events<>'' THEN
   EXECUTE format('CREATE TRIGGER %I AFTER %s ON %I.%I FOR EACH ROW EXECUTE FUNCTION public.fn_mark_native_scope_columns(%s)',
    item.tgname,write_events,item.nspname,item.relname,arguments);
  END IF;
  field:=item.tgname||CASE WHEN write_events='' THEN '' ELSE '_upd' END;
  EXECUTE format('CREATE TRIGGER %I AFTER UPDATE ON %I.%I FOR EACH ROW WHEN (%s) EXECUTE FUNCTION public.fn_mark_native_scope_columns(%s)',
   field,item.nspname,item.relname,predicate,arguments);
  FOREACH field IN ARRAY CASE WHEN write_events='' THEN ARRAY[item.tgname::text]
   ELSE ARRAY[item.tgname::text,item.tgname||'_upd'] END LOOP
   EXECUTE format('ALTER TABLE %I.%I %s TRIGGER %I',item.nspname,item.relname,
    CASE item.tgenabled WHEN 'A' THEN 'ENABLE ALWAYS' WHEN 'R' THEN 'ENABLE REPLICA'
     WHEN 'D' THEN 'DISABLE' WHEN 'O' THEN 'ENABLE' ELSE NULL END,field);
   IF item.original_comment IS NOT NULL THEN
    EXECUTE format('COMMENT ON TRIGGER %I ON %I.%I IS %L',field,item.nspname,item.relname,item.original_comment);
   END IF;
  END LOOP;
  changed:=changed+1;
 END LOOP;
 RETURN changed;
END $$;
REVOKE ALL ON FUNCTION fn_refresh_native_scope_update_gates() FROM PUBLIC;
SELECT fn_refresh_native_scope_update_gates();

-- Metadata ownership is a statement authority, independent of row values.
-- Keep the same rejecting trigger function before every write (including an
-- empty UPDATE/DELETE), rather than repeating the identical owner check per row.
DROP TRIGGER trg_summary_metadata_write ON summary_read_domains;
DROP TRIGGER trg_summary_metadata_write ON summary_read_markers;
CREATE TRIGGER trg_summary_metadata_write BEFORE INSERT OR UPDATE OR DELETE ON summary_read_domains
 FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_summary_read_metadata();
CREATE TRIGGER trg_summary_metadata_write BEFORE INSERT OR UPDATE OR DELETE ON summary_read_markers
 FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_summary_read_metadata();

-- Publish the exact missing current-transaction domain keys in one statement.
-- Durable markers remain the only proof: rollback/savepoint/compaction cannot
-- leave a session flag that suppresses the next real source publication.
CREATE OR REPLACE FUNCTION fn_mark_summary_read_domain() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF TG_OP IN ('INSERT','UPDATE') THEN
  IF NOT EXISTS(SELECT 1 FROM summary_new_rows) THEN RETURN NULL; END IF;
 ELSIF TG_OP='DELETE' THEN
  IF NOT EXISTS(SELECT 1 FROM summary_old_rows) THEN RETURN NULL; END IF;
 END IF;
 INSERT INTO public.summary_read_markers(domain,transaction_id)
 SELECT requested.domain,txid_current() FROM unnest(TG_ARGV) requested(domain)
 WHERE NOT EXISTS(SELECT 1 FROM public.summary_read_markers marker
  WHERE marker.domain=requested.domain AND marker.transaction_id=txid_current())
 ON CONFLICT DO NOTHING;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION fn_mark_summary_read_domain() FROM PUBLIC;
