-- psql -X -v ON_ERROR_STOP=1 -v expected_database=... -v expected_dataset_id=...
--   -v expected_system_identifier=... -v expected_database_oid=... -f this-file.sql
-- No connection settings, secrets, decryption keys, plaintext phone/document,
-- ciphertext, lookup HMAC or credentials are emitted. Every statement is read-only.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset pager off
\if :{?expected_database}
\else
\echo 'Missing expected_database; audit refused'
\quit 3
\endif
\if :{?expected_dataset_id}
\else
\echo 'Missing expected_dataset_id; audit refused'
\quit 3
\endif
\if :{?expected_system_identifier}
\else
\echo 'Missing expected_system_identifier; audit refused'
\quit 3
\endif
\if :{?expected_database_oid}
\else
\echo 'Missing expected_database_oid; audit refused'
\quit 3
\endif

BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
SELECT current_database()=:'expected_database'
   AND (SELECT business_dataset_id::text FROM authorization_state WHERE singleton_id=1)=:'expected_dataset_id'
   AND (SELECT system_identifier::text FROM pg_control_system())=:'expected_system_identifier'
   AND (SELECT oid::text FROM pg_database WHERE datname=current_database())=:'expected_database_oid'
   AND to_regclass('public.employee_identity_aliases') IS NOT NULL
   AND EXISTS(SELECT 1 FROM flyway_schema_history WHERE version='947' AND success) AS target_matches \gset
\if :target_matches
\else
ROLLBACK;
\echo 'Physical database/dataset identity or identity-alias schema mismatch; audit refused'
\quit 3
\endif

SELECT jsonb_build_object('section','database_identity','captured_at',clock_timestamp(),
 'database',current_database(),'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
 'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
 'dataset_id',a.business_dataset_id,'generation',a.business_reset_generation,
 'migration_max',(SELECT max(version::int) FROM flyway_schema_history WHERE success),
 'migration_sha256',(SELECT encode(digest(COALESCE(jsonb_agg(jsonb_build_array(version,checksum) ORDER BY installed_rank)::text,'[]'),'sha256'),'hex') FROM flyway_schema_history WHERE success),
 'read_only',current_setting('transaction_read_only'),'isolation',current_setting('transaction_isolation'))
FROM authorization_state a WHERE singleton_id=1;

WITH facts AS (
 SELECT e.*,s.id_card_hash,s.phone_hash,s.id_card_enc,s.id_card_check,s.id_card_last4,
        COALESCE(a.canonical_employee_id,e.id) AS canonical_id
 FROM employees e LEFT JOIN employee_sensitive s ON s.employee_id=e.id
 LEFT JOIN employee_identity_aliases a ON a.alias_employee_id=e.id
), signals AS (
 SELECT 'SAME_NAME_REVIEW_ONLY' AS kind,array_agg(id ORDER BY id) AS ids
 FROM facts WHERE btrim(full_name)<>'' GROUP BY btrim(full_name) HAVING count(*)>1
 UNION ALL SELECT 'SAME_DOCUMENT_HMAC',array_agg(id ORDER BY id) FROM facts
 WHERE id_card_hash IS NOT NULL GROUP BY id_card_hash HAVING count(*)>1
 UNION ALL SELECT 'SAME_PRIMARY_PHONE_HMAC_REVIEW_ONLY',array_agg(id ORDER BY id) FROM facts
 WHERE phone_hash IS NOT NULL GROUP BY phone_hash HAVING count(*)>1
 UNION ALL SELECT 'IDENTICAL_CIPHERTEXT_REQUIRES_CONTENT_CHECK',array_agg(id ORDER BY id) FROM facts
 WHERE length(id_card_enc)>80 GROUP BY id_card_enc HAVING count(*)>1
), groups AS (
 SELECT kind,md5(kind||ids::text) AS group_id,
   (SELECT count(DISTINCT canonical_id) FROM facts WHERE id=ANY(ids)) AS canonical_count,
   (SELECT jsonb_agg(jsonb_build_object('employee_id',f.id,'code',f.code,'name',f.full_name,
       'canonical_employee_id',f.canonical_id,'deleted',f.is_deleted,'status',f.status,'version',f.version,
       'department_id',f.department_id,'hire_date',f.hire_date,'legacy_id',f.legacy_id,'legacy_category',f.legacy_category,
       'document_type',f.id_type,'document_check',f.id_card_check,'document_last4',right(f.id_card_last4,4),
       'document_hmac_present',f.id_card_hash IS NOT NULL,'phone_hmac_present',f.phone_hash IS NOT NULL,
       'accounts',(SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id',u.id,'status',u.status,
           'deleted',u.is_deleted,'version',u.version,'auth_version',u.auth_version,
           'super_admin',u.is_super_admin,'login_suffix',right(u.login_account,4))), '[]'::jsonb) FROM users u WHERE u.employee_id=f.id),
       'employment_history',(SELECT COALESCE(jsonb_agg(jsonb_build_object('event_id',h.id,'type',h.event_type,
           'date',h.event_date,'from_department',h.from_dept_id,'to_department',h.to_dept_id) ORDER BY h.event_date,h.id),'[]'::jsonb)
           FROM employment_history h WHERE h.employee_id=f.id)) ORDER BY f.code)
      FROM facts f WHERE f.id=ANY(signals.ids)) AS members
 FROM signals
)
SELECT jsonb_build_object('section','candidate_groups','groups',COALESCE(jsonb_agg(to_jsonb(groups) ORDER BY kind,group_id),'[]'::jsonb),
 'automatic_identity_conclusions',0,'name_phone_or_timeline_alone_is_not_identity_proof',true) FROM groups;

SELECT jsonb_build_object('section','archived_without_verified_alias',
 'records',COALESCE(jsonb_agg(jsonb_build_object('employee_id',e.id,'code',e.code,'name',e.full_name,
   'version',e.version,'status',e.status,'hire_date',e.hire_date) ORDER BY e.code),'[]'::jsonb))
FROM employees e WHERE e.is_deleted AND NOT EXISTS(SELECT 1 FROM employee_identity_aliases a WHERE a.alias_employee_id=e.id);

SELECT jsonb_build_object('section','verified_aliases','records',COALESCE(jsonb_agg(jsonb_build_object(
 'alias_employee_id',a.alias_employee_id,'canonical_employee_id',a.canonical_employee_id,
 'evidence_present',length(btrim(a.evidence_reference))>0,'created_at',a.created_at)),'[]'::jsonb)) FROM employee_identity_aliases a;

-- Include cross-name exact identifiers as well as every archived identity.
WITH candidate AS (
 SELECT e.id FROM employees e LEFT JOIN employee_sensitive s ON s.employee_id=e.id
 WHERE e.is_deleted OR EXISTS(SELECT 1 FROM employees other WHERE other.id<>e.id AND btrim(other.full_name)=btrim(e.full_name))
   OR EXISTS(SELECT 1 FROM employee_sensitive other WHERE other.employee_id<>e.id AND (
       (s.id_card_hash IS NOT NULL AND other.id_card_hash=s.id_card_hash)
       OR (s.phone_hash IS NOT NULL AND other.phone_hash=s.phone_hash)
       OR (length(s.id_card_enc)>80 AND other.id_card_enc=s.id_card_enc)))
)
SELECT COALESCE(array_agg(id),'{}'::uuid[]) AS candidate_ids FROM candidate \gset
SELECT COALESCE(array_agg(id),'{}'::uuid[]) AS reference_ids FROM (
 SELECT unnest(:'candidate_ids'::uuid[]) AS id UNION SELECT id FROM users WHERE employee_id=ANY(:'candidate_ids'::uuid[])
) ids \gset

SELECT jsonb_build_object('section','primary_and_alternate_phone_links','groups',COALESCE(jsonb_agg(to_jsonb(g)),'[]'::jsonb))
FROM (
 SELECT md5(string_agg(employee_id::text,',' ORDER BY employee_id)) AS group_id,
   jsonb_agg(jsonb_build_object('employee_id',employee_id,'source',source,'label',label)) AS members
 FROM (SELECT employee_id,phone_hash,'PRIMARY'::text AS source,'主手机号'::text AS label FROM employee_sensitive WHERE phone_hash IS NOT NULL
       UNION ALL SELECT employee_id,phone_hash,'ALTERNATE',label FROM employee_phones WHERE phone_hash IS NOT NULL) p
 GROUP BY phone_hash HAVING count(DISTINCT employee_id)>1
) g;

-- Each generated statement returns scoped counts only, never actual row payloads.
-- UUID references without FKs are included (old maker/owner/history projections).
SELECT format($q$
 SELECT jsonb_build_object('section','reference_counts','table',%L,'column',%L,'records',jsonb_agg(to_jsonb(scoped)))
 FROM (SELECT t.%I::text AS reference_id,count(*) AS row_count,
       count(*) FILTER(WHERE COALESCE((to_jsonb(t)->>'is_deleted')::boolean,false)=false) AS non_deleted_rows
       FROM public.%I t WHERE t.%I=ANY(%L::uuid[]) GROUP BY t.%I) scoped HAVING count(*)>0;
 $q$,c.relname,a.attname,a.attname,c.relname,a.attname,:'reference_ids',a.attname)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
WHERE n.nspname='public' AND c.relkind IN('r','p') AND NOT c.relispartition
 AND a.atttypid='uuid'::regtype AND a.attname<>'id'
ORDER BY c.relname,a.attname \gexec

-- Current responsibilities use the same state predicates as DataHandoverService.
WITH responsibility(table_name,column_name,predicate) AS (VALUES
 ('clients','owner_employee_id','NOT t.is_deleted'),('suppliers','owner_employee_id','NOT t.is_deleted'),
 ('goods','owner_employee_id','NOT t.is_deleted'),('moulds','keeper_id','NOT t.is_deleted'),
 ('departments','manager_id','NOT t.is_deleted'),('employees','supervisor_id','NOT t.is_deleted'),
 ('inbound_expectations','owner_employee_id',$x$t.status='OPEN'$x$),
 ('procurement_arrival_exceptions','owner_employee_id',$x$t.status NOT IN('CLOSED','CANCELED')$x$),
 ('supplier_return_tasks','owner_employee_id',$x$t.status='PENDING_RETURN'$x$),
 ('website_inquiries','assignee_employee_id',$x$t.status IN('new','following')$x$),
 ('visitor_applications','host_employee_id',$x$NOT t.is_deleted AND t.status IN('pending','hostReviewing','approved') AND t.planned_visit_at>current_timestamp$x$),
 ('rd_tasks','assignee_employee_id',$x$NOT t.is_deleted AND t.status IN('OPEN','IN_PROGRESS')$x$),
 ('production_plans','seller_id','NOT t.is_deleted AND t.status=0'),('production_plans','worker_id','NOT t.is_deleted AND t.status=0'),
 ('production_execution_segments','responsible_employee_id',$x$NOT t.is_deleted AND t.status IN('READY','WAITING','DISPATCHED','IN_PROGRESS')$x$),
 ('fixed_assets','custodian_employee_id',$x$NOT t.is_deleted AND t.lifecycle_status<>'DISPOSED'$x$),
 ('deferred_expenses','responsible_employee_id',$x$NOT t.is_deleted AND t.lifecycle_status NOT IN('COMPLETED','TERMINATED')$x$),
 ('task_claims','claimed_by','t.released_at IS NULL'),('hr_task_claims','claimed_by','t.released_at IS NULL'),
 ('profile_change_requests','employee_id',$x$t.status='pending'$x$))
SELECT format($q$SELECT jsonb_build_object('section','current_responsibility','table',%L,'column',%L,
 'records',COALESCE(jsonb_agg(to_jsonb(scoped)),'[]'::jsonb)) FROM
 (SELECT t.%I AS employee_id,count(*) AS row_count FROM public.%I t
 WHERE t.%I=ANY(%L::uuid[]) AND (%s) GROUP BY t.%I) scoped;$q$,
 table_name,column_name,column_name,table_name,column_name,:'candidate_ids',predicate,column_name)
FROM responsibility WHERE to_regclass('public.'||table_name) IS NOT NULL ORDER BY table_name,column_name \gexec

SELECT jsonb_build_object('section','completed','read_only',current_setting('transaction_read_only'),
 'candidate_count',cardinality(:'candidate_ids'::uuid[]),'business_writes',0,'raw_pii_exported',false);
ROLLBACK;
