-- Views do not inherit defaults from the underlying partitioned table.
-- Preserve the original INSERT contract for omitted audit metadata while
-- explicit NULL values still follow the online table's rejection rules.
-- Leave id to fn_audit_log_all_insert's existing sequence/explicit-id paths.
ALTER VIEW public.v_audit_log_all
    ALTER COLUMN created_at SET DEFAULT now();
ALTER VIEW public.v_audit_log_all
    ALTER COLUMN event_source SET DEFAULT 'database'::text;
ALTER VIEW public.v_audit_log_all
    ALTER COLUMN device_capture_status SET DEFAULT 'legacy'::character varying;
