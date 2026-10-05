-- V798 (temporary number, renumber at merge): one server-side rule for the test files that
-- the workbench "clear business data" must physically delete (ADR-155).
--
-- One function lists the physical objects; the dialog preview, the check before draining,
-- the delete loop and the in-database re-verification all read it. All refusal conditions
-- the database can judge live in one function that runs before any file is deleted and again
-- as the first step of business_data_reset(). The signed intent ticket chain of V782 is removed.
--
-- Section order: 0 byte preconditions, 1 new functions, 2 replaced functions,
-- 3 anchor patch of business_data_reset(), 4 drops, 5 privileges, 6 self check.
-- No reset runs during this migration.
--
-- Do not write table/disposition tuples in this file except as doubled-quote literals:
-- BusinessDataResetSqlContractTest parses that tuple form.

-- ============ 0. Byte preconditions for the two wholly replaced functions ============
DO $v798_preconditions$
DECLARE
    actual text;
BEGIN
    SELECT md5(replace(prosrc, chr(13), '')) INTO actual
    FROM pg_catalog.pg_proc WHERE oid = 'public.fn_clear_business_test_object_metadata()'::regprocedure;
    IF actual IS DISTINCT FROM '73195ce907a32825dea7923b838e6b21' THEN
        RAISE EXCEPTION 'V798 was written against fn_clear_business_test_object_metadata() body md5 %, installed is %; another migration changed it: merge that change into V798 section 2 and update the hash',
            '73195ce907a32825dea7923b838e6b21', actual;
    END IF;
    SELECT md5(replace(prosrc, chr(13), '')) INTO actual
    FROM pg_catalog.pg_proc WHERE oid = 'public.fn_attachment_retained_identity_guard()'::regprocedure;
    IF actual IS DISTINCT FROM 'e8b80397f53496ba32613a22040a7fa1' THEN
        RAISE EXCEPTION 'V798 was written against fn_attachment_retained_identity_guard() body md5 %, installed is %; another migration changed it: merge that change into V798 section 2 and update the hash',
            'e8b80397f53496ba32613a22040a7fa1', actual;
    END IF;
END $v798_preconditions$;

-- ============ 1. New functions ============

-- The single object rule: one row per physical object that must be confirmed absent.
-- internal/local keep one file per key, so their identity has no version; the registered
-- versions of internal FINAL objects are only compared with the stored file.
-- deletable_storage is the only place that decides which storages the reset deletes from itself
-- (internal/local): refusal rule 20 and the Java delete loop both read this column.
-- Metadata only: never returns original bytes or candidate payloads.
CREATE FUNCTION public.fn_business_test_reset_objects()
RETURNS TABLE(object_provider text, object_location text, object_key text, identity_version text,
              registered_versions text[], source_kind text, source_label text, location_label text,
              file_name text, display_label text, recorded_absent boolean, object_identity text,
              deletable_storage boolean)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
WITH referenced AS (
    -- business attachments (final files)
    SELECT a.storage_provider::text AS provider, 'FINAL'::text AS location, a.storage_key::text AS object_key,
           a.storage_version::text AS version, 'ATTACHMENT'::text AS kind, 1 AS kind_rank, a.original_name::text AS name
    FROM public.attachments a
    WHERE upper(btrim(a.owner_type)) NOT IN ('GOODS', 'EMPLOYEE', 'EMPLOYEE_CONTRACT')
    UNION ALL
    -- upload sessions (staging copy and final file)
    SELECT s.storage_provider::text, place.kind, s.storage_key::text,
           CASE WHEN place.kind = 'FINAL' THEN s.final_version::text END, 'UPLOAD_SESSION', 2, s.original_name::text
    FROM public.attachment_upload_sessions s
    CROSS JOIN (VALUES ('STAGING'::text), ('FINAL'::text)) place(kind)
    WHERE upper(btrim(s.owner_type)) NOT IN ('GOODS', 'EMPLOYEE', 'EMPLOYEE_CONTRACT')
    UNION ALL
    -- AI recognition originals
    SELECT o.storage_provider::text, 'FINAL', o.storage_key::text, o.storage_version::text,
           'AI_INPUT_ORIGINAL', 3, o.original_name::text
    FROM public.ai_input_originals o WHERE o.storage_key IS NOT NULL
    UNION ALL
    -- quote template candidates (current and history)
    SELECT c.storage_provider::text, 'FINAL', c.storage_key::text, c.storage_version::text,
           'QUOTE_TEMPLATE_CANDIDATE', 4, c.source_name::text
    FROM public.sales_quote_template_candidates c WHERE c.storage_key IS NOT NULL
    UNION ALL
    SELECT h.storage_provider::text, 'FINAL', h.storage_key::text, h.storage_version::text,
           'QUOTE_TEMPLATE_CANDIDATE', 4, h.payload ->> 'source_name'
    FROM public.sales_quote_template_candidate_history h WHERE h.storage_key IS NOT NULL
    UNION ALL
    -- delete tasks in every status: a finished one only means "absent is success";
    -- the rows themselves are cleared by fn_clear_business_test_object_metadata()
    SELECT d.storage_provider::text, CASE WHEN d.operation = 'DELETE_STAGING' THEN 'STAGING' ELSE 'FINAL' END,
           d.storage_key::text, d.storage_version::text, 'DELETE_TASK', 5, coalesce(a.original_name, s.original_name)::text
    FROM public.attachment_object_outbox d
    LEFT JOIN public.attachments a ON a.id = d.attachment_id
    LEFT JOIN public.attachment_upload_sessions s ON s.id = d.upload_session_id
    WHERE upper(btrim(coalesce(a.owner_type, s.owner_type, 'UNKNOWN'))) NOT IN ('GOODS', 'EMPLOYEE', 'EMPLOYEE_CONTRACT')
), normalized AS (
    SELECT provider, location, object_key, NULLIF(btrim(version), '') AS version,
           CASE WHEN provider IN ('internal', 'local') THEN NULL ELSE NULLIF(btrim(version), '') END AS identity_version,
           kind, kind_rank, NULLIF(btrim(name), '') AS name
    FROM referenced
), physical AS (
    SELECT provider, location, object_key, identity_version,
           array_agg(DISTINCT version ORDER BY version)
               FILTER (WHERE version IS NOT NULL AND location = 'FINAL' AND provider = 'internal') AS registered_versions
    FROM normalized
    GROUP BY provider, location, object_key, identity_version
), per_file AS (
    -- the final file and the staging copy of one key share the display name and kind
    SELECT provider, object_key,
           (array_agg(kind ORDER BY kind_rank))[1] AS kind,
           (array_agg(name ORDER BY kind_rank, name) FILTER (WHERE name IS NOT NULL))[1] AS name
    FROM normalized
    GROUP BY provider, object_key
), objects AS (
    SELECT p.* FROM physical p
    -- internal/local are checked with a NULL version: any master row on the key protects it
    WHERE NOT public.fn_business_test_object_protected(p.provider, p.location, p.object_key, p.identity_version)
)
SELECT o.provider, o.location, o.object_key, o.identity_version, o.registered_versions,
       f.kind, label.kind_label, label.location_label, f.name,
       '「' || coalesce(f.name, '未登记文件名, 存储编号 ' || o.object_key) || '」(' || label.kind_label || ', ' || label.location_label || ')',
       EXISTS (SELECT 1 FROM public.attachment_object_outbox done
               WHERE done.status = 'SUCCEEDED' AND done.completed_at IS NOT NULL
                 AND done.storage_provider IS NOT DISTINCT FROM o.provider AND done.storage_key = o.object_key
                 AND (CASE WHEN done.operation = 'DELETE_STAGING' THEN 'STAGING' ELSE 'FINAL' END) = o.location
                 AND (o.identity_version IS NULL OR done.storage_version IS NOT DISTINCT FROM o.identity_version)),
       coalesce(o.provider, '<none>') || '|' || o.location || '|' || o.object_key || '|' || coalesce(o.identity_version, '*'),
       coalesce(o.provider IN ('internal', 'local'), false)
FROM objects o
JOIN per_file f ON f.provider IS NOT DISTINCT FROM o.provider AND f.object_key = o.object_key
CROSS JOIN LATERAL (SELECT
    CASE f.kind WHEN 'ATTACHMENT' THEN '业务附件' WHEN 'UPLOAD_SESSION' THEN '上传会话'
                WHEN 'AI_INPUT_ORIGINAL' THEN 'AI识别原件' WHEN 'QUOTE_TEMPLATE_CANDIDATE' THEN '报价模板候选'
                ELSE '删除任务' END AS kind_label,
    CASE o.location WHEN 'STAGING' THEN '暂存副本' ELSE '正式文件' END AS location_label) label
$function$;
COMMENT ON FUNCTION public.fn_business_test_reset_objects() IS
    'The only rule for which physical file objects belong to test business data (ADR-155); preview, checks, delete loop and in-database re-verification all read it';

-- Concurrency and integrity check of one object list, not an authentication token.
CREATE FUNCTION public.fn_business_test_reset_object_fingerprint() RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
    SELECT count(*)::text || ':' || encode(sha256(convert_to(coalesce(string_agg(
               object_identity || '|' || coalesce(array_to_string(registered_versions, ','), ''),
               E'\n' ORDER BY object_identity), ''), 'UTF8')), 'hex')
    FROM public.fn_business_test_reset_objects()
$function$;

-- Read-only view of the classification that stays written in business_data_reset().
-- The pattern is literally the same as BusinessDataResetSqlContractTest.POLICY_ROW.
CREATE FUNCTION public.fn_business_reset_table_policy()
RETURNS TABLE(table_name text, disposition text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
    SELECT m[1], m[2]
    FROM regexp_matches(pg_catalog.pg_get_functiondef('public.business_data_reset()'::regprocedure),
                        '\(''([a-z][a-z0-9_]*)''\s*,\s*''(CLEAR|PRESERVE)''\)', 'g') AS m
$function$;

-- The only database refusal check. Messages are complete and plain; Java never rewrites them.
CREATE FUNCTION public.fn_business_data_reset_refusals()
RETURNS TABLE(sort_order integer, reason_code text, item_count bigint, message text)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
DECLARE
    reset_owner oid;
    n bigint;
    wait_minutes integer;
    sample text;
    stuck_n bigint;
    stuck_failed_n bigint;
    stuck_sample text;
    kept_files constant text := '它们处理的是清空时要保留的文件(货品成本导入原件、已采用的报价模板、货品或员工档案附件)';
BEGIN
    SELECT proowner INTO reset_owner FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure;

    -- 10 background events still queued (status 0). Dead events (status 2) are cleared and
    -- reported, not refused (user 2026-10-05, D7).
    SELECT count(*), GREATEST(1, CEIL(EXTRACT(EPOCH FROM (max(available_at) - now())) / 60.0))::integer
      INTO n, wait_minutes
    FROM public.business_outbox WHERE status = 0;
    IF n > 0 THEN
        sort_order := 10; reason_code := 'BACKGROUND_EVENTS_PENDING'; item_count := n;
        message := format('后台还有 %s 条事件正在排队处理(消息通知、单据联动等)，预计 %s 分钟内处理完。现在清空会丢掉这些处理结果，请 %s 分钟后点「重新检查」再清空；如果多次重新检查仍在排队，请联系开发人员检查后台事件处理。',
                          n, wait_minutes, wait_minutes);
        RETURN NEXT;
    END IF;

    -- 15 and 16: unfinished delete tasks of files the reset keeps (goods cost import originals,
    -- adopted quote templates, goods/employee files). The reset keeps these tasks - exactly the rows
    -- fn_clear_business_test_object_metadata() keeps: no business owner and protected with the task's
    -- own version - so it waits until the ordinary delete queue has finished them (user 2026-10-05, D9).
    -- Queue states (AttachmentObjectOutboxProcessor): PENDING and FAILED run again at available_at
    -- (a failure waits 2^attempts seconds, at most 1024 s); PROCESSING is taken over 15 minutes after
    -- locked_at (default uten.storage.outbox.stale-processing-minutes); from 5 failed attempts
    -- (default alert-after-attempts) the worker logs that a person must look; SUCCEEDED and
    -- RETAINED_HISTORY are final. Waiting = will finish on its own; stuck = needs a developer.
    SELECT count(*) FILTER (WHERE NOT task.stuck),
           GREATEST(1, CEIL(EXTRACT(EPOCH FROM (max(task.expected_at) FILTER (WHERE NOT task.stuck) - now())) / 60.0))::integer,
           array_to_string((array_agg(task.label ORDER BY task.label) FILTER (WHERE NOT task.stuck))[1:5], '、'),
           count(*) FILTER (WHERE task.stuck),
           count(*) FILTER (WHERE task.stuck AND task.status = 'FAILED'),
           array_to_string((array_agg(task.label ORDER BY task.label) FILTER (WHERE task.stuck))[1:5], '、')
      INTO n, wait_minutes, sample, stuck_n, stuck_failed_n, stuck_sample
    FROM (SELECT d.status,
                 (d.status = 'FAILED' AND d.attempts >= 5)
                     OR (d.status = 'PROCESSING' AND d.locked_at IS NULL)
                     OR d.status NOT IN ('PENDING', 'PROCESSING', 'FAILED') AS stuck,
                 CASE WHEN d.status = 'PROCESSING' THEN d.locked_at + interval '15 minutes' ELSE d.available_at END AS expected_at,
                 '「' || CASE WHEN kept.employee_file THEN '员工档案文件, 存储编号 ' || d.storage_key
                              ELSE coalesce(kept.file_name, '未登记文件名, 存储编号 ' || d.storage_key) END
                     || '」(' || kept.kind_label || ', '
                     || CASE WHEN d.operation = 'DELETE_STAGING' THEN '暂存副本' ELSE '正式文件' END || ')' AS label
          FROM public.attachment_object_outbox d
          LEFT JOIN public.attachments a ON a.id = d.attachment_id
          LEFT JOIN public.attachment_upload_sessions s ON s.id = d.upload_session_id
          CROSS JOIN LATERAL (
              -- display only (protection is decided above); employee file names are never shown
              SELECT k.file_name, k.kind_label, k.employee_file FROM (
                  SELECT 1 AS kind_rank, g.source_name::text AS file_name, '货品成本导入'::text AS kind_label, false AS employee_file
                  FROM public.goods_cost_imports g
                  WHERE g.storage_key = d.storage_key AND (g.storage_provider = d.storage_provider OR g.storage_provider = 'legacy_unknown')
                  UNION ALL
                  SELECT 2, v.source_name::text, '已采用的报价模板', false
                  FROM public.sales_quote_template_versions v
                  WHERE v.storage_key = d.storage_key AND v.storage_provider = d.storage_provider
                  UNION ALL
                  SELECT 3, m.original_name::text,
                         CASE WHEN upper(btrim(m.owner_type)) = 'GOODS' THEN '货品档案附件' ELSE '员工档案附件' END,
                         upper(btrim(m.owner_type)) <> 'GOODS'
                  FROM public.attachments m
                  WHERE upper(btrim(m.owner_type)) IN ('GOODS', 'EMPLOYEE', 'EMPLOYEE_CONTRACT')
                    AND m.storage_key = d.storage_key AND (m.storage_provider = d.storage_provider OR m.storage_provider = 'legacy_unknown')
                  UNION ALL
                  SELECT 4, m.original_name::text,
                         CASE WHEN upper(btrim(m.owner_type)) = 'GOODS' THEN '货品档案附件' ELSE '员工档案附件' END,
                         upper(btrim(m.owner_type)) <> 'GOODS'
                  FROM public.attachment_upload_sessions m
                  WHERE upper(btrim(m.owner_type)) IN ('GOODS', 'EMPLOYEE', 'EMPLOYEE_CONTRACT')
                    AND m.storage_key = d.storage_key AND (m.storage_provider = d.storage_provider OR m.storage_provider = 'legacy_unknown')
                  UNION ALL
                  SELECT 5, NULL, '保留文件', false
              ) k ORDER BY k.kind_rank, k.file_name LIMIT 1) kept
          WHERE upper(btrim(coalesce(a.owner_type, s.owner_type, 'UNKNOWN'))) = 'UNKNOWN'
            AND (d.status NOT IN ('SUCCEEDED', 'RETAINED_HISTORY') OR d.completed_at IS NULL)
            AND public.fn_business_test_object_protected(d.storage_provider,
                    CASE WHEN d.operation = 'DELETE_STAGING' THEN 'STAGING' ELSE 'FINAL' END,
                    d.storage_key, d.storage_version)) task;
    IF n > 0 THEN
        sort_order := 15; reason_code := 'PROTECTED_DELETE_TASKS_PENDING'; item_count := n;
        message := format('有 %s 个删除任务还没有完成，%s：%s%s。清空会保留这些任务，要等它们完成后才能清空。后台正在自动处理它们(排队中、处理中或等待重试)，预计约 %s 分钟内处理完，请 %s 分钟后点「重新检查」；如果到时仍没有完成，请联系开发人员。',
                          n, kept_files, sample, CASE WHEN n > 5 THEN format(' 等 %s 个', n) ELSE '' END,
                          wait_minutes, wait_minutes);
        RETURN NEXT;
    END IF;
    IF stuck_n > 0 THEN
        sort_order := 16; reason_code := 'PROTECTED_DELETE_TASKS_STUCK'; item_count := stuck_n;
        message := format('有 %s 个删除任务卡住了，%s：%s%s。%s%s清空会保留这些任务，要等它们完成后才能清空。请联系开发人员查明这些删除任务为什么没有完成(服务器日志里有失败原因)并处理，处理完后点「重新检查」。',
                          stuck_n, kept_files, stuck_sample, CASE WHEN stuck_n > 5 THEN format(' 等 %s 个', stuck_n) ELSE '' END,
                          CASE WHEN stuck_failed_n = 0 THEN ''
                               WHEN stuck_failed_n = stuck_n THEN '它们已经连续失败至少 5 次，后台虽然还会每隔一段时间(最长约 17 分钟)自动重试，但连续失败说明不会自己恢复。'
                               ELSE format('其中 %s 个已经连续失败至少 5 次，后台虽然还会每隔一段时间(最长约 17 分钟)自动重试，但连续失败说明不会自己恢复。', stuck_failed_n) END,
                          CASE WHEN stuck_failed_n = stuck_n THEN ''
                               WHEN stuck_failed_n = 0 THEN '它们的处理记录不完整(状态和时间对不上)，后台不会再处理它们。'
                               ELSE format('其中 %s 个的处理记录不完整(状态和时间对不上)，后台不会再处理它们。', stuck_n - stuck_failed_n) END);
        RETURN NEXT;
    END IF;

    -- 20 test files in storage the system cannot delete (unless recorded as already deleted)
    SELECT count(*), array_to_string((array_agg(label ORDER BY label))[1:5], '、') INTO n, sample
    FROM (SELECT '「' || coalesce(o.file_name, '未登记文件名, 存储编号 ' || o.object_key) || '」(' || o.source_label || ', '
                 || o.location_label || ', '
                 || CASE WHEN o.object_provider = 'oss' THEN '旧阿里云存储' ELSE '存储位置未登记' END || ')' AS label
          FROM public.fn_business_test_reset_objects() o
          WHERE NOT o.deletable_storage AND NOT o.recorded_absent) blocked;
    IF n > 0 THEN
        sort_order := 20; reason_code := 'UNSUPPORTED_STORAGE'; item_count := n;
        message := format('有 %s 个测试文件存放在系统无法删除的位置，清空不能把它们一并删除：%s%s。系统里没有删除这类文件的功能，需要开发人员处理：确认这些文件在原存储上已经删除(或已迁移到内部存储)后，在数据库里把它们登记为已删除，然后回到这里点「重新检查」。',
                          n, sample, CASE WHEN n > 5 THEN format(' 等 %s 个', n) ELSE '' END);
        RETURN NEXT;
    END IF;

    -- 30 a table classified more than once
    SELECT count(*), array_to_string((array_agg(d.table_name ORDER BY d.table_name))[1:10], '、') INTO n, sample
    FROM (SELECT p.table_name FROM public.fn_business_reset_table_policy() p GROUP BY p.table_name HAVING count(*) <> 1) d;
    IF n > 0 THEN
        sort_order := 30; reason_code := 'CATALOG_DUPLICATE'; item_count := n;
        message := format('清空清单里有 %s 张数据表登记了不止一次(数据表：%s%s)。这是程序版本问题，请联系开发人员修复后再清空。',
                          n, sample, CASE WHEN n > 10 THEN format(' 等 %s 张', n) ELSE '' END);
        RETURN NEXT;
    END IF;

    -- 31 a public table nobody classified
    SELECT count(*), array_to_string((array_agg(c.relname::text ORDER BY c.relname))[1:10], '、') INTO n, sample
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
    WHERE ns.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relispartition AND c.relname <> 'spatial_ref_sys'
      AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend dep JOIN pg_catalog.pg_extension ext ON ext.oid = dep.refobjid
                      WHERE dep.classid = 'pg_catalog.pg_class'::regclass AND dep.objid = c.oid AND dep.deptype = 'e')
      AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension ext WHERE c.oid = ANY(COALESCE(ext.extconfig, ARRAY[]::oid[])))
      AND NOT EXISTS (SELECT 1 FROM public.fn_business_reset_table_policy() p WHERE p.table_name = c.relname);
    IF n > 0 THEN
        sort_order := 31; reason_code := 'CATALOG_UNCLASSIFIED'; item_count := n;
        message := format('数据库里有 %s 张数据表没有登记清空时要清除还是保留(数据表：%s%s)。这是程序版本问题(新增数据表时漏了登记)，请联系开发人员修复后再清空。',
                          n, sample, CASE WHEN n > 10 THEN format(' 等 %s 张', n) ELSE '' END);
        RETURN NEXT;
    END IF;

    -- 32 a classified table that does not exist or is not an ordinary parent table
    SELECT count(*), array_to_string((array_agg(p.table_name ORDER BY p.table_name))[1:10], '、') INTO n, sample
    FROM public.fn_business_reset_table_policy() p
    LEFT JOIN (SELECT c.relname, c.relkind, c.relispartition FROM pg_catalog.pg_class c
               JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace WHERE ns.nspname = 'public') actual
      ON actual.relname = p.table_name
    WHERE actual.relname IS NULL OR actual.relkind NOT IN ('r', 'p') OR actual.relispartition;
    IF n > 0 THEN
        sort_order := 32; reason_code := 'CATALOG_MISSING'; item_count := n;
        message := format('清空清单登记的 %s 张数据表在数据库里不存在或不是普通数据表(数据表：%s%s)。这是程序版本问题，请联系开发人员修复后再清空。',
                          n, sample, CASE WHEN n > 10 THEN format(' 等 %s 张', n) ELSE '' END);
        RETURN NEXT;
    END IF;

    -- 33 a preserved table references a cleared table
    SELECT count(*), array_to_string((array_agg(format('%s 引用 %s', child.relname, parent.relname)
               ORDER BY child.relname, parent.relname))[1:10], '、') INTO n, sample
    FROM pg_catalog.pg_constraint con
    JOIN pg_catalog.pg_class child ON child.oid = con.conrelid
    JOIN pg_catalog.pg_class parent ON parent.oid = con.confrelid
    JOIN pg_catalog.pg_namespace cn ON cn.oid = child.relnamespace AND cn.nspname = 'public'
    JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace AND pn.nspname = 'public'
    JOIN public.fn_business_reset_table_policy() cp ON cp.table_name = child.relname AND cp.disposition = 'PRESERVE'
    JOIN public.fn_business_reset_table_policy() pp ON pp.table_name = parent.relname AND pp.disposition = 'CLEAR'
    WHERE con.contype = 'f';
    IF n > 0 THEN
        sort_order := 33; reason_code := 'CATALOG_PRESERVE_REFERENCES_CLEAR'; item_count := n;
        message := format('有 %s 处要保留的数据引用了要清除的数据，清除会破坏保留的数据(%s%s)。这是程序版本问题，请联系开发人员修复后再清空。',
                          n, sample, CASE WHEN n > 10 THEN format(' 等 %s 处', n) ELSE '' END);
        RETURN NEXT;
    END IF;

    -- 34 a table outside the reset scope (other schemas and partitions included) references a cleared family
    WITH RECURSIVE clear_root AS (
        SELECT c.oid FROM public.fn_business_reset_table_policy() p
        JOIN pg_catalog.pg_class c ON c.relname = p.table_name AND c.relnamespace = 'public'::regnamespace
        WHERE p.disposition = 'CLEAR'
    ), family(member_oid) AS (
        SELECT oid FROM clear_root
        UNION
        SELECT i.inhrelid FROM family f JOIN pg_catalog.pg_inherits i ON i.inhparent = f.member_oid
    )
    SELECT count(*), array_to_string((array_agg(format('%s 引用 %s', fk.conrelid::regclass, fk.confrelid::regclass)
               ORDER BY fk.conrelid::regclass::text, fk.confrelid::regclass::text))[1:10], '、') INTO n, sample
    FROM pg_catalog.pg_constraint fk
    WHERE fk.contype = 'f' AND fk.confrelid IN (SELECT member_oid FROM family)
      AND fk.conrelid NOT IN (SELECT member_oid FROM family);
    IF n > 0 THEN
        sort_order := 34; reason_code := 'CATALOG_EXTERNAL_REFERENCE'; item_count := n;
        message := format('有 %s 处不在清空范围内的数据引用了要清除的数据(%s%s)。这是程序版本问题，请联系开发人员修复后再清空。',
                          n, sample, CASE WHEN n > 10 THEN format(' 等 %s 处', n) ELSE '' END);
        RETURN NEXT;
    END IF;

    -- 35 the reset function owner cannot truncate a cleared table (judged by owner, whoever calls)
    SELECT count(*), array_to_string((array_agg(p.table_name ORDER BY p.table_name))[1:10], '、') INTO n, sample
    FROM public.fn_business_reset_table_policy() p
    JOIN pg_catalog.pg_class c ON c.relname = p.table_name AND c.relnamespace = 'public'::regnamespace
    WHERE p.disposition = 'CLEAR' AND NOT pg_catalog.has_table_privilege(reset_owner, c.oid, 'TRUNCATE');
    IF n > 0 THEN
        sort_order := 35; reason_code := 'CATALOG_NO_TRUNCATE'; item_count := n;
        message := format('清空程序使用的数据库账号对 %s 张要清除的数据表没有清空权限(数据表：%s%s)。请让维护人员检查数据库权限后再清空。',
                          n, sample, CASE WHEN n > 10 THEN format(' 等 %s 张', n) ELSE '' END);
        RETURN NEXT;
    END IF;

    -- 36 the single row the reset's last step uses to sign everyone out (also re-checked there)
    SELECT count(*) INTO n FROM public.authorization_state WHERE singleton_id = 1;
    IF n <> 1 THEN
        sort_order := 36; reason_code := 'AUTHORIZATION_STATE_MISSING'; item_count := n;
        message := format('数据库里记录全员登录状态的数据应当正好有 1 条，现在有 %s 条，清空最后一步无法让所有人重新登录。这是数据库被人为改动或程序缺陷，请联系开发人员修复后再清空。',
                          n);
        RETURN NEXT;
    END IF;
    RETURN;
END $function$;

-- Caller identity: the same check that business_data_reset() runs first. It judges session_user,
-- which SECURITY DEFINER does not relax (V625/V782 use the same form).
CREATE FUNCTION public.fn_business_test_reset_require_caller() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $function$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(true);
END $function$;

-- EXCLUSIVE locks on the 9 source tables: blocks writers and SELECT FOR UPDATE/SHARE, still allows
-- plain SELECT. DEFINER because the runtime role may lack the privileges LOCK needs.
CREATE FUNCTION public.fn_business_test_reset_lock_sources() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $function$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(true);
    LOCK TABLE public.attachments, public.attachment_upload_sessions, public.attachment_object_outbox,
        public.ai_input_originals, public.sales_quote_template_candidates, public.sales_quote_template_candidate_history,
        public.sales_quote_template_versions, public.goods_cost_imports, public.business_outbox IN EXCLUSIVE MODE;
END $function$;

-- Under the source locks: without a declared fingerprint the list must be empty (direct call);
-- with one it must equal the recomputed value (otherwise a program defect).
CREATE FUNCTION public.fn_business_test_reset_verify_purged() RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
DECLARE
    declared text := NULLIF(current_setting('app.business_test_reset_objects', true), '');
    actual text;
    actual_count bigint;
    declared_count text;
BEGIN
    IF NOT public.fn_business_test_reset_active() THEN
        RAISE EXCEPTION 'Explicit trusted test-reset context required' USING ERRCODE = '42501';
    END IF;
    actual := public.fn_business_test_reset_object_fingerprint();
    actual_count := split_part(actual, ':', 1)::bigint;
    IF declared IS NULL THEN
        IF actual_count = 0 THEN
            PERFORM set_config('app.business_test_reset_verified', actual, true);
            RETURN;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'UT901', MESSAGE = format(
            '还有 %s 个测试文件没有删除。清空必须从工作台「系统测试 > 清空数据」执行，它会先删除这些文件再清空数据；本次没有清空任何数据。',
            actual_count);
    END IF;
    IF declared IS DISTINCT FROM actual THEN
        declared_count := CASE WHEN declared ~ '^[0-9]+:[0-9a-f]{64}$' THEN split_part(declared, ':', 1) ELSE '?' END;
        RAISE EXCEPTION USING ERRCODE = 'UT901', MESSAGE = format(
            '原因：清空前核对的测试文件清单(%s 个)和清空时数据库里的清单(%s 个)不一致，这是程序缺陷。本次没有清空任何数据，请联系开发人员。',
            declared_count, actual_count);
    END IF;
    PERFORM set_config('app.business_test_reset_verified', actual, true);
END $function$;

-- ============ 2. Wholly replaced functions (byte preconditions in section 0) ============

CREATE OR REPLACE FUNCTION public.fn_clear_business_test_object_metadata() RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
BEGIN
    IF NOT public.fn_business_test_reset_active() THEN
        RAISE EXCEPTION 'Explicit trusted test-reset context required' USING ERRCODE = '42501';
    END IF;
    PERFORM public.fn_business_test_reset_lock_sources();
    PERFORM public.fn_business_test_reset_verify_purged();
    -- reconciliation findings: only the objects of this test file list (master objects are not in it)
    DELETE FROM public.attachment_reconciliation_findings finding
    WHERE EXISTS (SELECT 1 FROM public.fn_business_test_reset_objects() o
        WHERE o.object_provider = finding.storage_provider AND o.object_location = finding.object_location
          AND o.object_key = finding.storage_key
          AND (o.identity_version IS NULL OR o.identity_version IS NOT DISTINCT FROM finding.storage_version));
    -- delete tasks: every business-owned row; an owner-less (self-contained) row only when no
    -- master reference protects it (V783 rule unchanged)
    DELETE FROM public.attachment_object_outbox operation
    WHERE upper(btrim(coalesce(
              (SELECT a.owner_type FROM public.attachments a WHERE a.id = operation.attachment_id),
              (SELECT s.owner_type FROM public.attachment_upload_sessions s WHERE s.id = operation.upload_session_id),
              'UNKNOWN'))) NOT IN ('GOODS', 'EMPLOYEE', 'EMPLOYEE_CONTRACT')
      AND (upper(btrim(coalesce(
              (SELECT a.owner_type FROM public.attachments a WHERE a.id = operation.attachment_id),
              (SELECT s.owner_type FROM public.attachment_upload_sessions s WHERE s.id = operation.upload_session_id),
              'UNKNOWN'))) <> 'UNKNOWN'
           OR NOT public.fn_business_test_object_protected(operation.storage_provider,
                  CASE WHEN operation.operation = 'DELETE_STAGING' THEN 'STAGING' ELSE 'FINAL' END,
                  operation.storage_key, operation.storage_version));
    DELETE FROM public.attachment_upload_sessions WHERE upper(btrim(owner_type)) NOT IN ('GOODS', 'EMPLOYEE', 'EMPLOYEE_CONTRACT');
    DELETE FROM public.attachments WHERE upper(btrim(owner_type)) NOT IN ('GOODS', 'EMPLOYEE', 'EMPLOYEE_CONTRACT');
END $function$;

CREATE OR REPLACE FUNCTION public.fn_attachment_retained_identity_guard() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP='DELETE' AND public.fn_business_test_reset_active() THEN
        IF upper(btrim(OLD.owner_type)) IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT') THEN
            RAISE EXCEPTION 'Protected master attachment cannot be cleared' USING ERRCODE='23514';
        END IF;
        IF NULLIF(current_setting('app.business_test_reset_verified', true), '') IS NULL THEN
            RAISE EXCEPTION 'Business attachment rows can be cleared only after the test file list is verified' USING ERRCODE='23514';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Attachment records and original identity must be retained' USING ERRCODE='23514'; END IF;
    IF OLD.lifecycle_state IN('CLEAN','RETAINED_HISTORY','DELETED','DELETE_PENDING','DELETE_FAILED')
       AND ROW(NEW.id,NEW.owner_type,NEW.owner_id,NEW.storage_provider,NEW.storage_key,NEW.storage_version,
           NEW.original_name,NEW.content_type,NEW.size_bytes,NEW.sha256,NEW.stored_size_bytes,NEW.storage_encoding,
           NEW.scan_engine,NEW.scan_signature,NEW.scanned_at,NEW.promoted_at)
       IS DISTINCT FROM ROW(OLD.id,OLD.owner_type,OLD.owner_id,OLD.storage_provider,OLD.storage_key,OLD.storage_version,
           OLD.original_name,OLD.content_type,OLD.size_bytes,OLD.sha256,OLD.stored_size_bytes,OLD.storage_encoding,
           OLD.scan_engine,OLD.scan_signature,OLD.scanned_at,OLD.promoted_at) THEN
        RAISE EXCEPTION 'Attachment original bytes and owner identity are immutable' USING ERRCODE='23514';
    END IF;
    IF OLD.lifecycle_state='RETAINED_HISTORY' AND
       (to_jsonb(NEW)-'updated_at'-'updated_by') IS DISTINCT FROM (to_jsonb(OLD)-'updated_at'-'updated_by') THEN
        RAISE EXCEPTION 'Deleted attachment history is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $function$;

-- ============ 3. Anchor patch of business_data_reset() ============
-- Every edit must find its anchor the expected number of times, otherwise fail closed.
-- Other migrations' edits to this function (classification rows or logic) are kept as they are.
DO $v798_reset_patch$
DECLARE
    definition text;
    edits text[][];
    edit_name text;
    needle text;
    replacement text;
    expected integer;
    found integer;
    range_start integer;
    range_end integer;
    policy_pattern constant text := '\(''([a-z][a-z0-9_]*)''\s*,\s*''(CLEAR|PRESERVE)''\)';
    before_rows text[];
    after_rows text[];
    changed text;
    before_secdef boolean;
    before_config text[];
    before_owner oid;
    i integer;
BEGIN
    SELECT prosecdef, proconfig, proowner INTO before_secdef, before_config, before_owner
    FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure;
    definition := replace(pg_catalog.pg_get_functiondef('public.business_data_reset()'::regprocedure), E'\r\n', E'\n');

    -- classification before the patch, without the retired intents row
    SELECT coalesce(array_agg(m[1] || ':' || m[2] ORDER BY m[1], m[2]), ARRAY[]::text[]) INTO before_rows
    FROM regexp_matches(definition, policy_pattern, 'g') AS m
    WHERE NOT (m[1] = 'business_test_object_cleanup_intents' AND m[2] = 'CLEAR');

    edits := ARRAY[
        -- E1 declarations used only by the moved refusal checks
        ARRAY['E1',
              '    duplicate_tables TEXT;' || E'\n' || '    unknown_tables TEXT;' || E'\n'
              || '    invalid_policy_tables TEXT;' || E'\n' || '    unsafe_fk_edges TEXT;' || E'\n'
              || '    blocked_outbox BIGINT;' || E'\n' || '    unsafe_attachment_owners BIGINT;' || E'\n',
              '    refusal_text TEXT;' || E'\n',
              '1'],
        -- E2 the single refusal check runs first, then the locked fingerprint re-verification
        ARRAY['E2',
              '    PERFORM public.fn_clear_business_test_object_metadata();' || E'\n',
              '    -- refusal check (the same function that runs before any test file is deleted),' || E'\n'
              || '    -- then lock the file sources and re-verify the test file list fingerprint' || E'\n'
              || '    SELECT string_agg(refusal.message, E''\n'' ORDER BY refusal.sort_order, refusal.message)' || E'\n'
              || '    INTO refusal_text FROM public.fn_business_data_reset_refusals() refusal;' || E'\n'
              || '    IF refusal_text IS NOT NULL THEN' || E'\n'
              || '        RAISE EXCEPTION USING ERRCODE = ''UT900'', MESSAGE = refusal_text;' || E'\n'
              || '    END IF;' || E'\n'
              || '    PERFORM public.fn_clear_business_test_object_metadata();' || E'\n',
              '1'],
        -- E3 the intents table is dropped below
        ARRAY['E3',
              '            (''business_test_object_cleanup_intents'', ''CLEAR''),' || E'\n',
              '',
              '1'],
        -- E4 parsed classification must equal the executed classification
        ARRAY['E4',
              '    (''unit_measurement_profiles'', ''PRESERVE'');' || E'\n',
              '    (''unit_measurement_profiles'', ''PRESERVE'');' || E'\n'
              || '    IF EXISTS (SELECT 1' || E'\n'
              || '               FROM (SELECT table_name, disposition, count(*) AS n FROM reset_business_table_policy GROUP BY 1, 2) actual' || E'\n'
              || '               FULL JOIN (SELECT table_name, disposition, count(*) AS n FROM public.fn_business_reset_table_policy() GROUP BY 1, 2) parsed' || E'\n'
              || '               USING (table_name, disposition)' || E'\n'
              || '               WHERE actual.n IS DISTINCT FROM parsed.n) THEN' || E'\n'
              || '        RAISE EXCEPTION ''清空清单解析结果与函数内清单不一致，整体回滚(程序缺陷，请联系开发人员)'' USING ERRCODE = ''XX000'';' || E'\n'
              || '    END IF;' || E'\n',
              '1'],
        -- E8 the retained control receipts; the other three actions are never written again
        ARRAY['E8',
              'action IN(''business_data_reset'',''business_data_reset_received'',''business_data_reset_failed'',''business_attachment_reset_prepare'',''business_test_object_cleanup_prepare'',''business_test_object_cleanup_failed'')',
              'action IN(''business_data_reset'',''business_data_reset_received'',''business_data_reset_failed'')',
              '2'],
        -- E9 comments only
        ARRAY['E9a',
              '（psql 停机版没有的收尾）',
              ' (清空收尾)',
              '1'],
        ARRAY['E9b',
              '与 psql 版（停机、无会话）刻意不同',
              '因为清空在运行中的应用里执行, 仍有会话需要作废',
              '1']
    ];
    FOR i IN 1 .. array_length(edits, 1) LOOP
        edit_name := edits[i][1];
        needle := edits[i][2];
        replacement := edits[i][3];
        expected := edits[i][4]::integer;
        found := (length(definition) - length(replace(definition, needle, ''))) / length(needle);
        IF found <> expected THEN
            RAISE EXCEPTION 'V798 edit % expected % occurrence(s) of its anchor in business_data_reset(), found %; another migration changed this part - adjust V798 by hand',
                edit_name, expected, found;
        END IF;
        definition := replace(definition, needle, replacement);
    END LOOP;

    -- E5 E6 E7: range deletions; the start marker is removed, the end marker is kept
    edits := ARRAY[
        -- E5 old refusals and catalog checks, now in fn_business_data_reset_refusals()
        ARRAY['E5',
              '    -- ============ 前置拒绝（ERRCODE UT900 → 应用层映射 409） ============' || E'\n',
              '    -- ============ 统计待清行数 + TRUNCATE（RESTART IDENTITY，ID 从 1 开始） ============' || E'\n'],
        -- E6 TRUNCATE privilege check, now refusal rule 35
        ARRAY['E6',
              '    -- LOCK privileges do not replace the original TRUNCATE check.',
              '    DROP TABLE IF EXISTS pg_temp.reset_business_clear_family;' || E'\n'],
        -- E7 references from outside the reset scope, now refusal rule 34
        ARRAY['E7',
              '    -- Retain full TRUNCATE RESTRICT even when a referenced table is empty:',
              '    FOR t IN SELECT table_name FROM reset_business_clear_work ORDER BY table_name LOOP' || E'\n']
    ];
    FOR i IN 1 .. array_length(edits, 1) LOOP
        edit_name := edits[i][1];
        needle := edits[i][2];
        replacement := edits[i][3];
        IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1
           OR (length(definition) - length(replace(definition, replacement, ''))) / length(replacement) <> 1 THEN
            RAISE EXCEPTION 'V798 edit % expected 1 occurrence of each range marker in business_data_reset(), found % and %; another migration changed this part - adjust V798 by hand',
                edit_name,
                (length(definition) - length(replace(definition, needle, ''))) / length(needle),
                (length(definition) - length(replace(definition, replacement, ''))) / length(replacement);
        END IF;
        range_start := strpos(definition, needle);
        range_end := strpos(definition, replacement);
        IF range_start >= range_end THEN
            RAISE EXCEPTION 'V798 edit % range markers are out of order in business_data_reset(); adjust V798 by hand', edit_name;
        END IF;
        definition := left(definition, range_start - 1) || substr(definition, range_end);
    END LOOP;

    EXECUTE definition;

    -- second check: the classification changed by exactly the retired intents row
    SELECT coalesce(array_agg(p.table_name || ':' || p.disposition ORDER BY p.table_name, p.disposition), ARRAY[]::text[])
    INTO after_rows FROM public.fn_business_reset_table_policy() p;
    IF before_rows IS DISTINCT FROM after_rows THEN
        SELECT string_agg(row_text, ', ' ORDER BY row_text) INTO changed FROM (
            (SELECT unnest(before_rows) EXCEPT ALL SELECT unnest(after_rows))
            UNION ALL
            (SELECT unnest(after_rows) EXCEPT ALL SELECT unnest(before_rows))
        ) difference(row_text);
        RAISE EXCEPTION 'V798 changed reset catalog rows other than business_test_object_cleanup_intents: %', changed;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure
                   AND prosecdef = before_secdef AND proconfig IS NOT DISTINCT FROM before_config
                   AND proowner = before_owner) THEN
        RAISE EXCEPTION 'V798 changed the security attributes or owner of business_data_reset()';
    END IF;
END $v798_reset_patch$;

-- ============ 4. Drop the signed intent ticket chain (no CASCADE: hidden dependencies fail closed) ============
DROP FUNCTION public.fn_assert_business_test_objects_cleared();
DROP FUNCTION public.fn_test_object_complete(uuid, uuid, uuid, bigint, bigint, text, boolean, text);
DROP FUNCTION public.fn_test_object_claim(uuid, uuid, bigint);
DROP FUNCTION public.fn_test_object_prepare(uuid, uuid, bigint, uuid, text, text, text, text, text, text, text, text, text, boolean, bigint, text, text, timestamp with time zone);
DROP FUNCTION public.fn_test_object_lock_sources();
DROP FUNCTION public.fn_test_object_require_actor(uuid, uuid, bigint);
DROP TABLE public.business_test_object_cleanup_intents;
DROP FUNCTION public.fn_test_object_intent_guard();
DROP FUNCTION public.fn_business_test_object_sources();
DROP VIEW public.v_business_test_object_sources;
DROP FUNCTION public.fn_business_attachment_reset_blockers();

-- ============ 5. Privileges (V782 form) ============
DO $v798_privileges$
DECLARE
    reset_owner_name text := pg_catalog.pg_get_userbyid((SELECT proowner FROM pg_catalog.pg_proc
        WHERE oid = 'public.business_data_reset()'::regprocedure));
    helper_owner_name text := pg_catalog.pg_get_userbyid((SELECT proowner FROM pg_catalog.pg_proc
        WHERE oid = 'public.fn_business_test_reset_lock_sources()'::regprocedure));
    runtime_functions constant text := 'public.fn_business_test_reset_objects(), public.fn_business_test_reset_object_fingerprint(), '
        || 'public.fn_business_reset_table_policy(), public.fn_business_data_reset_refusals(), '
        || 'public.fn_business_test_reset_require_caller(), public.fn_business_test_reset_lock_sources()';
BEGIN
    -- The runtime role first (V782 order): default privileges may have granted it the two private
    -- helpers, so revoke them explicitly. The grants to the reset owner come after, so an owner that
    -- is uten itself never loses EXECUTE on both (defensive: V625 already refuses a non-superuser
    -- uten owner of business_data_reset(), and a superuser owner bypasses privilege checks).
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'uten') THEN
        REVOKE ALL ON FUNCTION public.fn_business_test_reset_verify_purged(), public.fn_clear_business_test_object_metadata() FROM uten;
        EXECUTE 'GRANT EXECUTE ON FUNCTION ' || runtime_functions || ' TO uten';
    END IF;
    EXECUTE 'REVOKE ALL ON FUNCTION ' || runtime_functions || ', public.fn_business_test_reset_verify_purged() FROM PUBLIC';
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s, public.fn_business_test_reset_verify_purged(), public.fn_clear_business_test_object_metadata() TO %I',
                   runtime_functions, reset_owner_name);
    -- the owner of the DEFINER helpers (uten_migrator after a role split) must reach the caller check
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.fn_require_runtime_maintenance(boolean) TO %I', helper_owner_name);
END $v798_privileges$;

-- ============ 6. Self check ============
DO $v798_self_check$
DECLARE
    leftover text;
BEGIN
    IF to_regclass('public.business_test_object_cleanup_intents') IS NOT NULL
       OR to_regclass('public.v_business_test_object_sources') IS NOT NULL
       OR to_regprocedure('public.fn_business_test_object_sources()') IS NOT NULL
       OR to_regprocedure('public.fn_assert_business_test_objects_cleared()') IS NOT NULL
       OR to_regprocedure('public.fn_business_attachment_reset_blockers()') IS NOT NULL
       OR to_regprocedure('public.fn_test_object_lock_sources()') IS NOT NULL
       OR to_regprocedure('public.fn_test_object_intent_guard()') IS NOT NULL
       OR to_regprocedure('public.fn_test_object_require_actor(uuid,uuid,bigint)') IS NOT NULL
       OR to_regprocedure('public.fn_test_object_claim(uuid,uuid,bigint)') IS NOT NULL THEN
        RAISE EXCEPTION 'V798 left a retired test intent object behind';
    END IF;
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO leftover
    FROM pg_catalog.pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prosrc ~ '(v_business_test_object_sources|fn_business_test_object_sources|business_test_object_cleanup_intents|fn_test_object_|fn_assert_business_test_objects_cleared|fn_business_attachment_reset_blockers)';
    IF leftover IS NOT NULL THEN
        RAISE EXCEPTION 'V798 left references to retired test intent objects in: %', leftover;
    END IF;
END $v798_self_check$;
