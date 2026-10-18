-- Remote staff authentication: encrypted TOTP secrets, serialized replay/failure state,
-- and MFA proof bound to the existing server-side session. No existing user is enrolled.
CREATE TABLE staff_mfa (
    user_id UUID PRIMARY KEY REFERENCES users(id),
    secret_ciphertext TEXT,
    enabled_at TIMESTAMPTZ,
    pending_secret_ciphertext TEXT,
    -- Soft binding: business reset clears auth_sessions but preserves enrolled factors.
    -- Confirmation separately locks a live owner session, checks this exact sid and the TTL.
    -- A foreign key here would prevent the existing reset's authenticated-session cleanup.
    pending_session_id UUID,
    pending_expires_at TIMESTAMPTZ,
    last_accepted_step BIGINT,
    failed_attempts INTEGER NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
    locked_until TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_staff_mfa_enabled CHECK ((secret_ciphertext IS NULL) = (enabled_at IS NULL)),
    CONSTRAINT ck_staff_mfa_pending CHECK (
        (pending_secret_ciphertext IS NULL AND pending_session_id IS NULL AND pending_expires_at IS NULL)
        OR (pending_secret_ciphertext IS NOT NULL AND pending_session_id IS NOT NULL AND pending_expires_at IS NOT NULL)),
    CONSTRAINT ck_staff_mfa_cipher CHECK (
        (secret_ciphertext IS NULL OR secret_ciphertext ~ '^g[A-Za-z0-9]{1,16}:')
        AND (pending_secret_ciphertext IS NULL OR pending_secret_ciphertext ~ '^g[A-Za-z0-9]{1,16}:'))
);
COMMENT ON TABLE staff_mfa IS 'Staff TOTP credentials; application AES-GCM with environment/user/column AAD, never plaintext';
COMMENT ON COLUMN staff_mfa.pending_session_id IS 'Non-authoritative pending session identity; live session, owner and expiry are revalidated on confirmation; old sessions may be cleared during business reset';
ALTER TABLE auth_sessions ADD COLUMN mfa_verified_at TIMESTAMPTZ;
ALTER TABLE auth_sessions ADD CONSTRAINT ck_auth_sessions_staff_mfa
    CHECK (mfa_verified_at IS NULL OR user_id IS NOT NULL);
ALTER TABLE auth_sessions DROP CONSTRAINT ck_auth_sessions_revoked_reason;
ALTER TABLE auth_sessions ADD CONSTRAINT ck_auth_sessions_revoked_reason CHECK (
    revoked_reason IS NULL OR revoked_reason = ANY (ARRAY[
        'logout', 'idle_timeout', 'password_changed', 'account_status_changed',
        'password_reset', 'remote_access_changed', 'refresh_reuse', 'step_up_locked',
        'login_account_changed', 'replaced_by_new_login', 'mfa_changed']));

-- Only enrollment state is auditable. Never snapshot ciphertext, OTP counters or pending credentials.
SELECT public.fn_audit_track_table('staff_mfa','COLUMN_SCOPED','system',false,
    ARRAY['enabled_at'],false,NULL::text);
DO $mfa_reset_policy$
DECLARE definition text; anchor text := '(''system_settings'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V873 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''staff_mfa'', ''PRESERVE'')');
END $mfa_reset_policy$;
