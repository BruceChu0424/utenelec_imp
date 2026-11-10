-- Reuse the canonical append-only first-use proof. Existing historical source
-- rows also count as use; absence of old audit data never becomes a usage fact.
-- No lifecycle/nonuse proof is created for imported/older goods.
DO $backfill_existing_goods_use$
DECLARE source record; candidate uuid; source_query text;
BEGIN
  FOR source IN SELECT * FROM fn_goods_code_usage_columns() ORDER BY table_name,column_name LOOP
    IF source.kind='U' THEN
      source_query:=format('SELECT DISTINCT src.%I AS goods_id FROM public.%I src WHERE src.%I IS NOT NULL',
        source.column_name,source.table_name,source.column_name);
    ELSE
      source_query:=format($query$
        SELECT DISTINCT matched[1]::uuid AS goods_id
        FROM public.%I src CROSS JOIN LATERAL regexp_matches(src.%I::text,
          '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})','g') matched
        WHERE src.%I IS NOT NULL
        $query$,source.table_name,source.column_name,source.column_name);
    END IF;
    FOR candidate IN EXECUTE 'SELECT refs.goods_id FROM ('||source_query||') refs '
      ||'JOIN public.goods g ON g.id=refs.goods_id '
      ||'WHERE NOT EXISTS(SELECT 1 FROM public.goods_code_usage_facts f WHERE f.goods_id=refs.goods_id)'
    LOOP
      PERFORM fn_note_goods_code_use(candidate,source.table_name||'.'||source.column_name);
    END LOOP;
  END LOOP;
END $backfill_existing_goods_use$;

CREATE FUNCTION fn_guard_used_goods_soft_delete() RETURNS trigger
LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
BEGIN
  -- Updating only is_deleted normally takes NO KEY UPDATE, which does not
  -- conflict with the canonical first-use writer's KEY SHARE. Upgrade before
  -- checking the fact so an uncommitted first use cannot race past this guard.
  PERFORM 1 FROM public.goods g WHERE g.id=NEW.id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM public.goods_code_usage_facts f WHERE f.goods_id=NEW.id) THEN
    RAISE EXCEPTION USING ERRCODE='23514', CONSTRAINT='goods_used_identity_soft_delete',
      MESSAGE='货品已用于业务或库存记录，不能删除；请改用停用并保留历史身份';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_goods_guard_used_identity_soft_delete
  BEFORE UPDATE OF is_deleted ON goods FOR EACH ROW
  WHEN (NEW.is_deleted AND NOT OLD.is_deleted)
  EXECUTE FUNCTION fn_guard_used_goods_soft_delete();

COMMENT ON FUNCTION fn_guard_used_goods_soft_delete() IS
  'Used goods retain their UUID and history permanently; unused new goods remain deletable under normal authority/version/reference guards.';
