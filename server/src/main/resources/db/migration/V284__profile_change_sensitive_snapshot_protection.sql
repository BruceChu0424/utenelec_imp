-- =====================================================================
-- V284: protect sensitive profile-change old/new snapshots at rest
-- =====================================================================
-- V18 named old_value_enc/new_value_enc as encrypted snapshots, but the
-- application historically persisted decrypted/request text for review-only
-- phone, household-address and emergency-contact changes.  This migration
-- introduces an explicit, durable encoding state and a fail-closed write
-- guard.  The JVM-side ProfileChangeSnapshotBackfillRunner owns historical
-- classification/encryption because Flyway must never receive the PGP key.
--
-- Existing sensitive rows start as LEGACY_UNKNOWN.  Any later UPDATE is
-- rejected until the runner has either verified/re-wrapped a versioned cipher
-- or encrypted a safely identifiable plaintext value.  Ambiguous/corrupt
-- values therefore stop application startup instead of being exposed or lost.
-- =====================================================================

ALTER TABLE profile_change_requests
    ADD COLUMN IF NOT EXISTS value_encoding VARCHAR(24);

UPDATE profile_change_requests
SET value_encoding = CASE
    WHEN field_code IN ('phone', 'hujiAddress')
      OR field_code LIKE 'emergencyContact.%'
        THEN 'LEGACY_UNKNOWN'
    ELSE 'PLAIN'
END
WHERE value_encoding IS NULL;

ALTER TABLE profile_change_requests
    ALTER COLUMN value_encoding SET DEFAULT 'PLAIN',
    ALTER COLUMN value_encoding SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'profile_change_requests_value_encoding_ck'
          AND conrelid = 'profile_change_requests'::regclass
    ) THEN
        ALTER TABLE profile_change_requests
            ADD CONSTRAINT profile_change_requests_value_encoding_ck
            CHECK (value_encoding IN ('PLAIN', 'PGCRYPTO_V1', 'LEGACY_UNKNOWN'));
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS profile_change_requests_legacy_encoding_idx
    ON profile_change_requests (id)
    WHERE value_encoding = 'LEGACY_UNKNOWN';

CREATE OR REPLACE FUNCTION fn_profile_change_snapshot_requires_encryption(
    p_field_code TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_field_code IN ('phone', 'hujiAddress')
        OR p_field_code LIKE 'emergencyContact.%'
$$;

CREATE OR REPLACE FUNCTION fn_is_versioned_pgcrypto_text(p_value TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_separator INTEGER;
    v_version   TEXT;
    v_body      TEXT;
BEGIN
    IF p_value IS NULL THEN
        RETURN FALSE;
    END IF;

    v_separator := strpos(p_value, ':');
    IF v_separator < 2 THEN
        RETURN FALSE;
    END IF;

    v_version := left(p_value, v_separator - 1);
    v_body := regexp_replace(substr(p_value, v_separator + 1), '[[:space:]]', '', 'g');

    RETURN v_version ~ '^[A-Za-z0-9._-]{1,64}$'
       AND length(v_body) >= 8
       AND length(v_body) % 4 = 0
       AND v_body ~ '^[A-Za-z0-9+/]+={0,2}$';
END
$$;

CREATE OR REPLACE FUNCTION fn_guard_profile_change_snapshot_protection()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF fn_profile_change_snapshot_requires_encryption(NEW.field_code) THEN
        -- This is an application-version capability, not a secret.  Requiring
        -- it on every sensitive INSERT/UPDATE prevents a pre-V284 process (or
        -- an unsafe old-JAR rollback) from consuming the new domain-wrapped
        -- ciphertext as if it were business plaintext.
        IF current_setting('app.profile_change_snapshot_codec', true)
                IS DISTINCT FROM 'v1' THEN
            RAISE EXCEPTION
                'sensitive profile-change write requires snapshot codec capability v1 (id %, field %)',
                NEW.id, NEW.field_code;
        END IF;
        IF NEW.value_encoding IS DISTINCT FROM 'PGCRYPTO_V1' THEN
            RAISE EXCEPTION
                'sensitive profile-change snapshot must use PGCRYPTO_V1 (id %, field %)',
                NEW.id, NEW.field_code;
        END IF;
        IF NOT fn_is_versioned_pgcrypto_text(NEW.new_value_enc) THEN
            RAISE EXCEPTION
                'sensitive profile-change new snapshot is not versioned ciphertext (id %, field %)',
                NEW.id, NEW.field_code;
        END IF;
        IF NEW.old_value_enc IS NOT NULL
           AND NOT fn_is_versioned_pgcrypto_text(NEW.old_value_enc) THEN
            RAISE EXCEPTION
                'sensitive profile-change old snapshot is not versioned ciphertext (id %, field %)',
                NEW.id, NEW.field_code;
        END IF;
    ELSIF NEW.value_encoding IS DISTINCT FROM 'PLAIN' THEN
        RAISE EXCEPTION
            'non-sensitive profile-change snapshot must use PLAIN encoding (id %, field %)',
            NEW.id, NEW.field_code;
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS profile_change_snapshot_protection_guard
    ON profile_change_requests;
CREATE TRIGGER profile_change_snapshot_protection_guard
BEFORE INSERT OR UPDATE ON profile_change_requests
FOR EACH ROW
EXECUTE FUNCTION fn_guard_profile_change_snapshot_protection();

COMMENT ON COLUMN profile_change_requests.value_encoding IS
    'PLAIN for non-sensitive fields; PGCRYPTO_V1 for protected snapshots; LEGACY_UNKNOWN only until fail-closed JVM backfill';
COMMENT ON COLUMN profile_change_requests.old_value_enc IS
    'Old snapshot; sensitive fields require a versioned pgcrypto ciphertext and PGCRYPTO_V1 state';
COMMENT ON COLUMN profile_change_requests.new_value_enc IS
    'New snapshot; sensitive fields require a versioned pgcrypto ciphertext and PGCRYPTO_V1 state';

-- V23 replaced V18's broken dedicated trigger with the generic fn_audit(),
-- and V146+ removes old_value_enc/new_value_enc before writing new audit rows.
-- Assert that the effective chain still has both controls before cleaning the
-- bounded historical profile-change subset.  Keep business metadata and the
-- new value_encoding state; remove duplicated snapshot payloads and the
-- already-redacted free-text review comment from pre-V146 audit history.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger trigger_row
        JOIN pg_proc function_row ON function_row.oid = trigger_row.tgfoid
        WHERE trigger_row.tgrelid = 'profile_change_requests'::regclass
          AND NOT trigger_row.tgisinternal
          AND function_row.proname = 'fn_audit'
    ) THEN
        RAISE EXCEPTION
            'profile_change_requests must use the redacting generic fn_audit trigger';
    END IF;

    IF fn_audit_redact_row(
            'profile_change_requests',
            jsonb_build_object(
                'id', gen_random_uuid(),
                'old_value_enc', 'v284-redaction-sentinel-old',
                'new_value_enc', 'v284-redaction-sentinel-new',
                'review_comment', 'v284-redaction-sentinel-comment',
                'status', 'pending'))
            ?| ARRAY['old_value_enc', 'new_value_enc', 'review_comment'] THEN
        RAISE EXCEPTION
            'fn_audit_redact_row must remove profile-change snapshots and review comments';
    END IF;
END
$$;

UPDATE audit_log
SET before = CASE
        WHEN before IS NULL THEN NULL
        ELSE before - ARRAY[
            'old_value_enc', 'new_value_enc', 'review_comment'
        ]::TEXT[]
    END,
    "after" = CASE
        WHEN "after" IS NULL THEN NULL
        ELSE "after" - ARRAY[
            'old_value_enc', 'new_value_enc', 'review_comment'
        ]::TEXT[]
    END
WHERE target_type IN ('profile_change_requests', 'profileChangeRequest')
  AND (
      COALESCE(
          before ?| ARRAY['old_value_enc', 'new_value_enc', 'review_comment'],
          FALSE)
      OR COALESCE(
          "after" ?| ARRAY['old_value_enc', 'new_value_enc', 'review_comment'],
          FALSE)
  );
