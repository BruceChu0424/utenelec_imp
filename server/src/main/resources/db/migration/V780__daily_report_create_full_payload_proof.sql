-- Preserve CREATE-V3 request_hash and every existing command identity.
-- Legacy rows have no full-body proof and must never be backfilled by guessing.
ALTER TABLE public.production_daily_report_commands
    ADD COLUMN create_payload_version SMALLINT,
    ADD COLUMN create_payload_hash VARCHAR(64);

ALTER TABLE public.production_daily_report_commands
    ADD CONSTRAINT production_daily_report_create_payload_proof_chk CHECK (
        (create_payload_version IS NULL AND create_payload_hash IS NULL)
        OR (command_kind = 'CREATE' AND create_payload_version IS NOT NULL
            AND create_payload_hash IS NOT NULL AND create_payload_version = 1
            AND create_payload_hash ~ '^[0-9a-f]{64}$')
    );

COMMENT ON COLUMN public.production_daily_report_commands.create_payload_hash IS
    'Original actor CREATE native request plus complete per-line platform fields proof, frozen before domain mutation in the same transaction. NULL is unconfirmed legacy.';
COMMENT ON COLUMN public.production_daily_report_commands.create_payload_version IS
    'Independent full-payload proof version; does not change the accepted native CREATE-V3 request_hash or old POST replay contract.';

-- Row guards alone do not protect TRUNCATE. Keep every command identity and
-- original proof, including replication-role sessions, permanently intact.
CREATE TRIGGER trg_guard_production_daily_report_command_truncate
    BEFORE TRUNCATE ON public.production_daily_report_commands
    FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_production_daily_report_command();
ALTER TABLE public.production_daily_report_commands
    ENABLE ALWAYS TRIGGER trg_guard_production_daily_report_command_truncate;
