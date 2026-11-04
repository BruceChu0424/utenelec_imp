-- Explicit worksheet identity preserves all original bytes and permits separate
-- attachments in one workbook. Empty selection keeps the original auto mode.
ALTER TABLE finance_template_sources ADD COLUMN source_selection text NOT NULL DEFAULT ''
 CHECK(length(source_selection)<=500 AND(source_selection='' OR length(btrim(source_selection))>0));
DO $$ DECLARE original_name text;matches integer;BEGIN
 SELECT count(*),min(c.conname) INTO matches,original_name FROM pg_constraint c
 WHERE c.conrelid='finance_template_sources'::regclass AND c.contype='u'
 AND (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM unnest(c.conkey) key(attnum)
      JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=key.attnum)=ARRAY['actor_id','period','sha256','template_key'];
 IF matches<>1 THEN RAISE EXCEPTION 'Review financial source identity before extending worksheet selection';END IF;
 EXECUTE format('ALTER TABLE finance_template_sources DROP CONSTRAINT %I',original_name);
END $$;
ALTER TABLE finance_template_sources ADD CONSTRAINT finance_template_source_selection_unique
 UNIQUE(actor_id,template_key,period,sha256,source_selection);
SELECT fn_audit_track_table('finance_template_sources','COLUMN_SCOPED','data_change',false,
 ARRAY['id','actor_id','template_key','period','sha256','source_selection'],true,NULL);
