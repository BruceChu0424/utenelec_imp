-- Preserve mixed historical audit evidence until retention classes, holds and recovery proofs exist.
-- Only this previously unapplied forward migration changes behavior; V671 bytes stay immutable.
-- CREATE OR REPLACE preserves the existing function OID, owner, execute grants and return signature.
CREATE OR REPLACE FUNCTION public.fn_audit_retention_run()
RETURNS TABLE(
    hot_months INTEGER,
    archive_months INTEGER,
    hot_cutoff TIMESTAMPTZ,
    archive_cutoff TIMESTAMPTZ,
    archived_partitions TEXT[],
    archived_rows BIGINT,
    dropped_partitions TEXT[],
    dropped_rows BIGINT,
    created_partitions TEXT[],
    completion_event_id BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
SET lock_timeout = '5s' AS $$
DECLARE
    c_min_total_months CONSTANT INTEGER := 6;
    v_configured_hot INTEGER;
    v_configured_archive INTEGER;
    v_floor_applied BOOLEAN := FALSE;
    v_partition RECORD;
    v_lower TIMESTAMPTZ;
    v_upper TIMESTAMPTZ;
    v_rows BIGINT;
    v_target TEXT;
    v_created TEXT;
    v_offset INTEGER;
    v_index INTEGER;
    v_setting TEXT;
    v_move_names TEXT[] := ARRAY[]::TEXT[];
    v_move_targets TEXT[] := ARRAY[]::TEXT[];
    v_move_lower TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    v_move_upper TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    v_move_rows BIGINT[] := ARRAY[]::BIGINT[];
    v_preserved_names TEXT[] := ARRAY[]::TEXT[];
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('uten.audit.retention'));

    SELECT s.value INTO v_setting FROM public.system_settings s WHERE s.key = 'audit_hot_retention_months';
    v_configured_hot := COALESCE(NULLIF(btrim(v_setting), '')::INTEGER, 6);
    SELECT s.value INTO v_setting FROM public.system_settings s WHERE s.key = 'audit_archive_retention_months';
    v_configured_archive := COALESCE(NULLIF(btrim(v_setting), '')::INTEGER, 30);
    IF v_configured_hot NOT BETWEEN 1 AND 120 OR v_configured_archive NOT BETWEEN 0 AND 240 THEN
        RAISE EXCEPTION 'audit retention months out of range: hot=%, archive=%',
            v_configured_hot, v_configured_archive USING ERRCODE = '22023';
    END IF;
    hot_months := v_configured_hot;
    archive_months := v_configured_archive;
    IF hot_months + archive_months < c_min_total_months THEN
        archive_months := c_min_total_months - hot_months;
        v_floor_applied := TRUE;
    END IF;
    hot_cutoff := now() - make_interval(months => hot_months);
    archive_cutoff := now() - make_interval(months => hot_months + archive_months);
    archived_partitions := ARRAY[]::TEXT[];
    dropped_partitions := ARRAY[]::TEXT[];
    created_partitions := ARRAY[]::TEXT[];
    archived_rows := 0;
    dropped_rows := 0;

    -- 阶段一: 扫描。只占旧月分区上的共享类锁, 业务写入(只写当月分区)不受影响。
    FOR v_partition IN
        SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'public.audit_log'::regclass
        ORDER BY c.relname
    LOOP
        v_lower := substring(v_partition.bound FROM 'FROM \(''([^'']+)''\)')::TIMESTAMPTZ;
        v_upper := substring(v_partition.bound FROM 'TO \(''([^'']+)''\)')::TIMESTAMPTZ;
        CONTINUE WHEN v_lower IS NULL OR v_upper IS NULL OR v_upper > hot_cutoff;
        v_target := 'audit_log_archive_' || substring(v_partition.relname FROM '(p[0-9]{6})$');
        IF v_target IS NULL OR to_regclass('public.' || v_target) IS NOT NULL THEN
            RAISE EXCEPTION 'audit partition % cannot be archived as %', v_partition.relname, v_target
                USING ERRCODE = '55000';
        END IF;
        EXECUTE format('SELECT count(*) FROM public.%I', v_partition.relname) INTO v_rows;
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = format('public.%I', v_partition.relname)::regclass
                         AND conname = 'audit_month_bound') THEN
            EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT audit_month_bound '
                           'CHECK (created_at IS NOT NULL AND created_at >= %L AND created_at < %L) NOT VALID',
                           v_partition.relname, v_lower, v_upper);
        END IF;
        EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT audit_month_bound', v_partition.relname);
        v_move_names := v_move_names || v_partition.relname::TEXT;
        v_move_targets := v_move_targets || v_target;
        v_move_lower := v_move_lower || v_lower;
        v_move_upper := v_move_upper || v_upper;
        v_move_rows := v_move_rows || v_rows;
    END LOOP;


    -- 阶段二: 只剩元数据操作。整月移入归档; 超过原最终期限的分区只登记为保全候选，不销毁。
    FOR v_index IN 1 .. coalesce(array_length(v_move_names, 1), 0) LOOP
        EXECUTE format('ALTER TABLE public.audit_log DETACH PARTITION public.%I', v_move_names[v_index]);
        EXECUTE format('ALTER TABLE public.%I RENAME TO %I', v_move_names[v_index], v_move_targets[v_index]);
        EXECUTE format('ALTER TABLE public.audit_log_archive ATTACH PARTITION public.%I FOR VALUES FROM (%L) TO (%L)',
                       v_move_targets[v_index], v_move_lower[v_index], v_move_upper[v_index]);
        archived_partitions := archived_partitions || v_move_targets[v_index];
        archived_rows := archived_rows + v_move_rows[v_index];
    END LOOP;

    FOR v_partition IN
        SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'public.audit_log_archive'::regclass
        ORDER BY c.relname
    LOOP
        v_upper := substring(v_partition.bound FROM 'TO \(''([^'']+)''\)')::TIMESTAMPTZ;
        CONTINUE WHEN v_upper IS NULL OR v_upper > archive_cutoff;
        -- Existing archive is append-only. Record candidate identities without
        -- rescanning every retained historical row on every daily run.
        v_preserved_names := v_preserved_names || v_partition.relname::TEXT;
    END LOOP;

    -- R0 evidence protection: month partitions mix business decisions, source
    -- changes and technical events. Age alone proves no destruction eligibility.
    -- Keep all candidates until classification, holds and verified recovery are
    -- enforced by a separate forward migration. No runtime setting bypasses this.
    -- dropped_partitions/dropped_rows remain empty/zero for old caller compatibility.

    FOR v_offset IN 0 .. 3 LOOP
        v_created := public.fn_audit_ensure_partition('audit_log',
            (date_trunc('month', now() AT TIME ZONE 'Asia/Shanghai') + make_interval(months => v_offset))::DATE);
        IF v_created IS NOT NULL THEN
            created_partitions := created_partitions || v_created;
        END IF;
    END LOOP;

    INSERT INTO public.audit_log (
        actor_account, action, target_type, target_id, "after", result,
        event_source, risk_level, event_category, device_capture_status)
    VALUES (
        'system', 'audit_retention_completed', 'audit_retention',
        to_char(now() AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD'),
        jsonb_build_object(
            'hot_months', hot_months,
            'archive_months', archive_months,
            'configured_hot_months', v_configured_hot,
            'configured_archive_months', v_configured_archive,
            'minimum_total_months', c_min_total_months,
            'floor_applied', v_floor_applied,
            'hot_cutoff', hot_cutoff,
            'archive_cutoff', archive_cutoff,
            'archived_partitions', to_jsonb(archived_partitions),
            'archived_rows', archived_rows,
            'dropped_partitions', to_jsonb(dropped_partitions),
            'dropped_rows', dropped_rows,
            'purge_mode', 'PRESERVE_UNCLASSIFIED',
            'preserved_partitions', to_jsonb(v_preserved_names),
            'preserved_partition_count', cardinality(v_preserved_names),
            'created_partitions', to_jsonb(created_partitions)),
        'success', 'system', 'low', 'system', 'missing')
    RETURNING id INTO completion_event_id;
    RETURN NEXT;
END;
$$;

-- Expose installed behavior, not a saved setting or an application-version guess.
-- Pin the capability to this function body and execution settings. If maintenance
-- replaces the retention implementation, clients must show UNKNOWN until reverified.
DO $capability$
DECLARE
    v_fingerprint TEXT;
BEGIN
    SELECT md5(p.prosrc || ':' || COALESCE(p.proconfig::text, '') || ':' || p.prosecdef::text)
      INTO STRICT v_fingerprint
      FROM pg_proc p WHERE p.oid = 'public.fn_audit_retention_run()'::regprocedure;
    EXECUTE format($definition$
        CREATE OR REPLACE FUNCTION public.fn_audit_retention_purge_mode()
        RETURNS TEXT LANGUAGE sql STABLE
        SET search_path = pg_catalog, public, pg_temp AS $mode$
            SELECT COALESCE((
                SELECT CASE WHEN md5(p.prosrc || ':' || COALESCE(p.proconfig::text, '') || ':' || p.prosecdef::text) = %L
                            THEN 'PRESERVE_UNCLASSIFIED' ELSE 'UNKNOWN' END
                FROM pg_proc p
                WHERE p.oid = to_regprocedure('public.fn_audit_retention_run()')
            ), 'UNKNOWN')
        $mode$
    $definition$, v_fingerprint);
END;
$capability$;
-- This read reports one non-sensitive capability string and cannot run retention.
GRANT EXECUTE ON FUNCTION public.fn_audit_retention_purge_mode() TO PUBLIC;
