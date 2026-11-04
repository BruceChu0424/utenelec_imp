-- V990_1 起迁移目录出现点分版本号（flyway_schema_history.version 如 '990.1'、'999.13'），
-- V964 安装的 fn_employee_merge_database_identity 里 max(version::int) 在此类库上执行即抛
-- invalid input syntax for type integer，人员合并/别名维护的数据库身份核对全部被阻断。
-- V964 已应用不可回改（Flyway checksum 校验），此处按 V977 编号封条前移的同一受控模式：
-- 先用现有目录封条证明库处于已审核状态，再仅把该函数的版本聚合 int 改为 numeric
-- （migration_max 只进合并清单作标识，numeric 对点分版本最忠实；全整数字号库上
-- jsonb 输出与旧定义逐字节一致，既有已审核计划不受影响），最后对
-- employee_identity_merge_installation 做有界 catalog_sha256 CAS，
-- payload/其余目录字段/不可变触发器全部原样保留。
DO $employee_merge_database_identity_dotted_versions$
DECLARE
 original_search_path text := current_setting('search_path');
 catalog_query constant text := $merge_catalog$SELECT jsonb_build_object(
        'tables',(SELECT jsonb_agg(jsonb_build_array(c.relname,pg_get_userbyid(c.relowner),c.relacl::text) ORDER BY c.relname)
          FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
            AND c.relname IN('employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation')),
        'columns',(SELECT jsonb_agg(jsonb_build_array(c.relname,a.attname,a.atttypid::regtype::text,a.atttypmod,a.attnotnull,a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid)) ORDER BY c.relname,a.attnum)
          FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
          LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
          WHERE n.nspname='public' AND c.relname IN('employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation')),
        'functions',(SELECT jsonb_agg(jsonb_build_array(pg_get_functiondef(p.oid),pg_get_userbyid(p.proowner),p.proacl::text) ORDER BY p.proname,p.oid::regprocedure::text)
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND
            (p.proname LIKE 'fn_employee_merge_%' OR p.proname IN('fn_merge_employee_identity','fn_employee_identity_from_legacy_worker'))),
        'constraints',(SELECT jsonb_agg(jsonb_build_array(c.relname,k.conname,k.convalidated,pg_get_constraintdef(k.oid)) ORDER BY c.relname,k.conname)
          FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND c.relname IN('employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation','employee_identity_aliases')),
        'indexes',(SELECT jsonb_agg(pg_get_indexdef(i.indexrelid) ORDER BY c.relname,i.indexrelid::regclass::text)
          FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
            AND c.relname IN('employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation')),
        'legacy_roles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY source_table,uuid_column) FROM public.employee_identity_legacy_roles r),
        'triggers',(SELECT jsonb_agg(jsonb_build_array(c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid)) ORDER BY c.relname,t.tgname)
          FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgname LIKE 'trg_employee_merge_%')
      )$merge_catalog$;
 installed jsonb;
 before_catalog jsonb;
 after_catalog jsonb;
 expected_catalog jsonb;
 definition_index integer;
 definition_count integer;
 immutable_enabled "char";
 new_catalog_sha text;
 affected integer;
BEGIN
 PERFORM set_config('search_path','pg_catalog,public,pg_temp',true);
 LOCK TABLE public.employee_identity_merge_installation IN ACCESS EXCLUSIVE MODE;
 SELECT to_jsonb(receipt) INTO STRICT installed
 FROM public.employee_identity_merge_installation receipt WHERE version='v1';
 EXECUTE catalog_query INTO before_catalog;
 -- 先证明当前目录仍与安装封条一致：任何未审核漂移都拒绝前移，绝不盲目覆盖。
 IF installed->>'catalog_sha256' IS DISTINCT FROM
    encode(public.digest(before_catalog::text,'sha256'),'hex') THEN
   RAISE EXCEPTION 'Employee merge catalog differs from the sealed installation; dotted-version redefinition refused';
 END IF;
 SELECT count(*),min(position-1)::integer INTO definition_count,definition_index
 FROM jsonb_array_elements(before_catalog->'functions') WITH ORDINALITY AS entry(value,position)
 WHERE entry.value->>0 ~ '^CREATE OR REPLACE FUNCTION public\.fn_employee_merge_database_identity\(\)';
 IF definition_count<>1
    OR position('max(version::int) FROM flyway_schema_history' IN before_catalog->'functions'->definition_index->>0)=0 THEN
   RAISE EXCEPTION 'Sealed fn_employee_merge_database_identity definition is not the reviewed V964 shape';
 END IF;
 SELECT tgenabled INTO STRICT immutable_enabled FROM pg_trigger
 WHERE tgrelid='public.employee_identity_merge_installation'::regclass
   AND tgname='trg_employee_merge_immutable' AND NOT tgisinternal;
 IF immutable_enabled NOT IN ('O','A') THEN
   RAISE EXCEPTION 'Employee merge installation immutable guard is not in its reviewed enabled state';
 END IF;
 -- 仅改版本聚合的目标类型：int -> numeric，其余函数体与 SECURITY DEFINER/STABLE/
 -- search_path 属性与 V964 安装定义逐字一致。
 EXECUTE $definition$
    CREATE OR REPLACE FUNCTION public.fn_employee_merge_database_identity() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
      SELECT jsonb_build_object('database',current_database(),'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
        'dataset_id',business_dataset_id::text,'generation',business_reset_generation,
        'migration_max',(SELECT max(version::numeric) FROM flyway_schema_history WHERE success),
        'migration_sha256',(SELECT encode(public.digest(COALESCE(jsonb_agg(jsonb_build_array(version,checksum) ORDER BY installed_rank)::text,'[]'),'sha256'),'hex') FROM flyway_schema_history WHERE success))
      FROM authorization_state WHERE singleton_id=1
    $body$
  $definition$;
 EXECUTE catalog_query INTO after_catalog;
 expected_catalog:=jsonb_set(before_catalog,
    ARRAY['functions',definition_index::text,'0'],
    to_jsonb(pg_get_functiondef('public.fn_employee_merge_database_identity()'::regprocedure)));
 IF after_catalog IS DISTINCT FROM expected_catalog
    OR position('max(version::numeric) FROM flyway_schema_history' IN
        after_catalog->'functions'->definition_index->>0)=0 THEN
   RAISE EXCEPTION 'Dotted-version redefinition changed an unreviewed employee merge catalog field';
 END IF;
 new_catalog_sha:=encode(public.digest(after_catalog::text,'sha256'),'hex');
 -- 只有迁移属主能做这次有界封条 CAS；不禁用其他证据防护，也不用 session_replication_role。
 ALTER TABLE public.employee_identity_merge_installation DISABLE TRIGGER trg_employee_merge_immutable;
 UPDATE public.employee_identity_merge_installation SET catalog_sha256=new_catalog_sha
 WHERE version='v1' AND to_jsonb(employee_identity_merge_installation)=installed;
 GET DIAGNOSTICS affected=ROW_COUNT;
 IF immutable_enabled='A' THEN
   ALTER TABLE public.employee_identity_merge_installation ENABLE ALWAYS TRIGGER trg_employee_merge_immutable;
 ELSE
   ALTER TABLE public.employee_identity_merge_installation ENABLE TRIGGER trg_employee_merge_immutable;
 END IF;
 EXECUTE catalog_query INTO after_catalog;
 IF affected<>1 OR after_catalog IS DISTINCT FROM expected_catalog
    OR new_catalog_sha IS DISTINCT FROM public.fn_employee_merge_catalog_sha()
    OR NOT EXISTS(SELECT 1 FROM public.employee_identity_merge_installation receipt
       WHERE to_jsonb(receipt)-'catalog_sha256'=installed-'catalog_sha256'
         AND receipt.catalog_sha256=new_catalog_sha) THEN
   RAISE EXCEPTION 'Employee merge dotted-version catalog receipt CAS or immutable-guard restoration failed';
 END IF;
 PERFORM set_config('search_path',original_search_path,true);
END;
$employee_merge_database_identity_dotted_versions$;
