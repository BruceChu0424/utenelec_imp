-- Account <-> payment-style relations are UUID-authoritative at runtime.
--
-- The old path defaults are consumed exactly once here for active historical
-- accounts that still have no persisted style_id.  Runtime writes and posting
-- never infer a relation from path, name, code, or legacy id after this point.

-- V265/V267 kept these legacy guards while clients were being upgraded.  Drop
-- them before canonicalizing historical shadows: the UUID guard remains, and
-- the strict authority trigger installed below replaces both legacy lookups.
DROP TRIGGER IF EXISTS trg_psref_accounts_active_legacy ON accounts;
DROP TRIGGER IF EXISTS trg_psref_accounts_style ON accounts;

-- Serialize the one-time hierarchy normalization with all payment-style
-- maintenance and reference writers installed by V265.
SELECT pg_advisory_xact_lock(
    hashtextextended('PAYMENT_STYLE_HIERARCHY', 0));

-- Some native V276 databases have active accounts but never imported the old
-- M_Style tree.  Create only the two canonical roots that those accounts need,
-- and only when the path has no historical row at all.  An existing disabled,
-- deleted, non-ACCOUNT, non-leaf, or duplicate path is evidence that requires
-- reviewed repair and is deliberately left for the validation below to reject.
WITH default_styles(account_type, code, name, sort_order) AS (
    VALUES
        ('CASH'::TEXT, '101'::TEXT, '现金'::TEXT, 101),
        ('NON_CASH'::TEXT, '102'::TEXT, '银行存款'::TEXT, 102)
), required_defaults AS (
    SELECT DISTINCT defaults.code, defaults.name, defaults.sort_order
    FROM default_styles defaults
    JOIN accounts account
      ON COALESCE(account.is_deleted, FALSE) = FALSE
     AND account.status = '使用'
     AND account.style_id IS NULL
     AND defaults.account_type = CASE
             WHEN account.account_type = 'CASH' THEN 'CASH'
             ELSE 'NON_CASH'
         END
)
INSERT INTO payment_styles (
    code, name, category, level, sort_order,
    is_receipt, is_payment, status, auto_created)
SELECT required.code, required.name, 'ACCOUNT', 0, required.sort_order,
       TRUE, TRUE, '使用', TRUE
FROM required_defaults required
WHERE NOT EXISTS (
    SELECT 1
    FROM payment_styles existing
    WHERE existing.path = '/' || required.code || '/'
);

-- Every default path that is actually needed must now resolve to exactly one
-- active ACCOUNT leaf.  Ambiguous or historically unavailable paths abort.
DO $$
DECLARE
    required RECORD;
    match_count BIGINT;
BEGIN
    FOR required IN
        SELECT CASE WHEN account.account_type = 'CASH'
                    THEN '/101/' ELSE '/102/' END AS required_path
        FROM accounts account
        WHERE COALESCE(account.is_deleted, FALSE) = FALSE
          AND account.status = '使用'
          AND account.style_id IS NULL
        GROUP BY 1
    LOOP
        SELECT COUNT(*) INTO match_count
        FROM payment_styles style
        WHERE style.path = required.required_path
          AND style.category = 'ACCOUNT'
          AND style.status = '使用'
          AND COALESCE(style.is_deleted, FALSE) = FALSE
          AND NOT EXISTS (
              SELECT 1
              FROM payment_styles child
              WHERE child.parent_id = style.id
                AND COALESCE(child.is_deleted, FALSE) = FALSE
          );

        IF match_count <> 1 THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = format(
                    'account style migration path %s resolved to %s active ACCOUNT leaves; expected exactly one',
                    required.required_path, match_count);
        END IF;
    END LOOP;
END
$$;

-- Migration-only defaulting.  The target legacy id is derived from the chosen
-- UUID and retained solely as a compatibility/audit shadow.
WITH required_targets AS (
    SELECT style.path, style.id, style.legacy_id
    FROM payment_styles style
    WHERE style.path IN ('/101/', '/102/')
      AND style.category = 'ACCOUNT'
      AND style.status = '使用'
      AND COALESCE(style.is_deleted, FALSE) = FALSE
      AND NOT EXISTS (
          SELECT 1
          FROM payment_styles child
          WHERE child.parent_id = style.id
            AND COALESCE(child.is_deleted, FALSE) = FALSE
      )
)
UPDATE accounts account
SET style_id = target.id,
    style_legacy_id = target.legacy_id
FROM required_targets target
WHERE COALESCE(account.is_deleted, FALSE) = FALSE
  AND account.status = '使用'
  AND account.style_id IS NULL
  AND target.path = CASE WHEN account.account_type = 'CASH'
                         THEN '/101/' ELSE '/102/' END;

-- Existing UUID relations own their compatibility shadows.  Never select a
-- UUID from a shadow during this normalization.
UPDATE accounts account
SET style_legacy_id = style.legacy_id
FROM payment_styles style
WHERE account.style_id = style.id
  AND account.style_legacy_id IS DISTINCT FROM style.legacy_id;

UPDATE payment_styles style
SET linked_account_legacy_id = account.legacy_id
FROM accounts account
WHERE style.linked_account_id = account.id
  AND style.linked_account_legacy_id IS DISTINCT FROM account.legacy_id;

-- V267 should already have converted every historical legacy relation.  If a
-- later native writer introduced a legacy-only relation, stop for reviewed
-- repair instead of guessing an identity during this upgrade.
DO $$
DECLARE
    broken_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO broken_count
    FROM accounts
    WHERE style_legacy_id IS NOT NULL AND style_id IS NULL;
    IF broken_count <> 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                'accounts contain %s legacy-only style relations; reviewed UUID repair is required',
                broken_count);
    END IF;

    SELECT COUNT(*) INTO broken_count
    FROM payment_styles
    WHERE linked_account_legacy_id IS NOT NULL
      AND linked_account_id IS NULL;
    IF broken_count <> 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                'payment_styles contain %s legacy-only linked-account relations; reviewed UUID repair is required',
                broken_count);
    END IF;
END
$$;

ALTER TABLE accounts
    ADD CONSTRAINT ck_accounts_active_style_uuid
        CHECK (COALESCE(is_deleted, FALSE) OR status <> '使用' OR style_id IS NOT NULL)
        NOT VALID,
    ADD CONSTRAINT ck_accounts_style_shadow_requires_uuid
        CHECK (style_legacy_id IS NULL OR style_id IS NOT NULL)
        NOT VALID;

ALTER TABLE payment_styles
    ADD CONSTRAINT ck_payment_styles_linked_account_shadow_requires_uuid
        CHECK (linked_account_legacy_id IS NULL OR linked_account_id IS NOT NULL)
        NOT VALID;

ALTER TABLE accounts VALIDATE CONSTRAINT ck_accounts_active_style_uuid;
ALTER TABLE accounts VALIDATE CONSTRAINT ck_accounts_style_shadow_requires_uuid;
ALTER TABLE payment_styles
    VALIDATE CONSTRAINT ck_payment_styles_linked_account_shadow_requires_uuid;

CREATE OR REPLACE FUNCTION fn_enforce_account_style_uuid_authority()
RETURNS TRIGGER AS $$
DECLARE
    canonical_legacy_id INTEGER;
    style_category TEXT;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('PAYMENT_STYLE_HIERARCHY', 0));

    IF NEW.style_id IS NULL THEN
        IF NEW.style_legacy_id IS NOT NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'accounts.style_legacy_id is a shadow; style_id UUID is required';
        END IF;
        IF COALESCE(NEW.is_deleted, FALSE) = FALSE
                AND NEW.status = '使用' THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'active account requires an ACCOUNT leaf style_id UUID';
        END IF;
        RETURN NEW;
    END IF;

    SELECT style.legacy_id, style.category
      INTO canonical_legacy_id, style_category
      FROM payment_styles style
     WHERE style.id = NEW.style_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '23503',
            MESSAGE = 'accounts.style_id does not reference a payment style';
    END IF;
    IF style_category IS DISTINCT FROM 'ACCOUNT' THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'accounts.style_id must reference an ACCOUNT style';
    END IF;
    IF NEW.style_legacy_id IS NOT NULL
            AND NEW.style_legacy_id IS DISTINCT FROM canonical_legacy_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'accounts style UUID conflicts with legacy shadow';
    END IF;

    NEW.style_legacy_id := canonical_legacy_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_account_style_uuid_authority
    BEFORE INSERT OR UPDATE OF style_id, style_legacy_id, status, is_deleted
    ON accounts
    FOR EACH ROW EXECUTE FUNCTION fn_enforce_account_style_uuid_authority();

-- V267 installed the reverse status guard with a transition-only legacy
-- fallback.  V277 replaces its body in place so the existing trigger also
-- treats accounts.style_id as the sole runtime identity source.
CREATE OR REPLACE FUNCTION fn_guard_active_account_style_status()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IS NOT DISTINCT FROM OLD.status
            AND COALESCE(NEW.is_deleted, FALSE)
                IS NOT DISTINCT FROM COALESCE(OLD.is_deleted, FALSE) THEN
        RETURN NEW;
    END IF;
    IF NEW.status = '使用' AND COALESCE(NEW.is_deleted, FALSE) = FALSE THEN
        RETURN NEW;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('PAYMENT_STYLE_HIERARCHY', 0));
    IF EXISTS (
        SELECT 1
        FROM accounts account
        WHERE account.status = '使用'
          AND COALESCE(account.is_deleted, FALSE) = FALSE
          AND account.style_id = NEW.id
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = '收付款类别仍被使用中的账户引用，不能停用或删除';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_enforce_payment_style_account_uuid_authority()
RETURNS TRIGGER AS $$
DECLARE
    canonical_legacy_id INTEGER;
BEGIN
    IF NEW.linked_account_id IS NULL THEN
        IF NEW.linked_account_legacy_id IS NOT NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'payment_styles.linked_account_legacy_id is a shadow; linked_account_id UUID is required';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.category IS DISTINCT FROM 'ACCOUNT' THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'only ACCOUNT payment styles may link an account';
    END IF;

    SELECT account.legacy_id INTO canonical_legacy_id
    FROM accounts account
    WHERE account.id = NEW.linked_account_id
      AND account.status = '使用'
      AND COALESCE(account.is_deleted, FALSE) = FALSE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'payment_styles.linked_account_id does not reference an active account';
    END IF;
    IF NEW.linked_account_legacy_id IS NOT NULL
            AND NEW.linked_account_legacy_id IS DISTINCT FROM canonical_legacy_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'payment style linked-account UUID conflicts with legacy shadow';
    END IF;

    NEW.linked_account_legacy_id := canonical_legacy_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_style_account_uuid_authority
    BEFORE INSERT OR UPDATE OF linked_account_id, linked_account_legacy_id, category
    ON payment_styles
    FOR EACH ROW
    EXECUTE FUNCTION fn_enforce_payment_style_account_uuid_authority();

-- Posting reads only the persisted UUID.  Missing account/mapping returns NULL,
-- so downstream validation/join logic fails closed without an inferred style.
CREATE OR REPLACE FUNCTION account_style_id(p_account_id UUID) RETURNS UUID AS $$
    SELECT account.style_id
    FROM accounts account
    WHERE account.id = p_account_id;
$$ LANGUAGE SQL STABLE STRICT;

COMMENT ON FUNCTION account_style_id(UUID) IS
    'Returns only accounts.style_id; NULL means missing and no legacy/path/name fallback is permitted.';
COMMENT ON CONSTRAINT ck_accounts_active_style_uuid ON accounts IS
    'Every active, non-deleted account persists its accounting-style UUID truth.';
