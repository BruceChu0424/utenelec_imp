-- Account <-> accounting-style runtime references use UUIDs.  Legacy ids remain
-- migration shadows only; posting resolves accounts.style_id first.
ALTER TABLE accounts ADD COLUMN style_id UUID;
ALTER TABLE payment_styles ADD COLUMN linked_account_id UUID;

ALTER TABLE accounts
    ADD CONSTRAINT fk_accounts_style
        FOREIGN KEY (style_id) REFERENCES payment_styles(id)
        ON DELETE RESTRICT NOT VALID;
ALTER TABLE payment_styles
    ADD CONSTRAINT fk_payment_styles_linked_account
        FOREIGN KEY (linked_account_id) REFERENCES accounts(id)
        ON DELETE RESTRICT NOT VALID;

-- All values are NULL at this point, so validate before backfill.  Subsequent
-- migration writes are protected immediately and do not leave pending FK events.
ALTER TABLE accounts VALIDATE CONSTRAINT fk_accounts_style;
ALTER TABLE payment_styles VALIDATE CONSTRAINT fk_payment_styles_linked_account;

UPDATE accounts account
SET style_id = style.id
FROM payment_styles style
WHERE account.style_id IS NULL
  AND account.style_legacy_id IS NOT NULL
  AND style.legacy_id = account.style_legacy_id;

UPDATE payment_styles style
SET linked_account_id = account.id
FROM accounts account
WHERE style.linked_account_id IS NULL
  AND style.linked_account_legacy_id IS NOT NULL
  AND account.legacy_id = style.linked_account_legacy_id;

-- Historical and disabled rows still need a UUID identity. Do not silently
-- discard them during backfill; fail the migration on orphan/wrong-category
-- shadows, while applying active+leaf rules only to accounts still in use.
DO $$
DECLARE
    broken_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO broken_count
    FROM accounts account
    LEFT JOIN payment_styles style ON style.id = account.style_id
    WHERE account.style_legacy_id IS NOT NULL
      AND (style.id IS NULL
           OR style.legacy_id IS DISTINCT FROM account.style_legacy_id
           OR style.category IS DISTINCT FROM 'ACCOUNT');
    IF broken_count <> 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                'accounts style UUID backfill has %s orphan or non-ACCOUNT mappings',
                broken_count);
    END IF;

    SELECT COUNT(*) INTO broken_count
    FROM accounts account
    JOIN payment_styles style ON style.id = account.style_id
    WHERE COALESCE(account.is_deleted, FALSE) = FALSE
      AND account.status = '使用'
      AND account.style_legacy_id IS NOT NULL
      AND (COALESCE(style.is_deleted, FALSE) = TRUE
           OR style.status IS DISTINCT FROM '使用'
           OR EXISTS (
               SELECT 1 FROM payment_styles child
               WHERE child.parent_id = style.id
                 AND COALESCE(child.is_deleted, FALSE) = FALSE));
    IF broken_count <> 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                'active accounts have %s disabled, deleted, or non-leaf style mappings',
                broken_count);
    END IF;

    SELECT COUNT(*) INTO broken_count
    FROM payment_styles style
    LEFT JOIN accounts account ON account.id = style.linked_account_id
    WHERE style.linked_account_legacy_id IS NOT NULL
      AND (account.id IS NULL
           OR account.legacy_id IS DISTINCT FROM style.linked_account_legacy_id
           OR style.category IS DISTINCT FROM 'ACCOUNT');
    IF broken_count <> 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                'payment style linked-account UUID backfill has %s invalid mappings',
                broken_count);
    END IF;
END
$$;

CREATE INDEX idx_accounts_style_id
    ON accounts(style_id) WHERE style_id IS NOT NULL;
CREATE INDEX idx_payment_styles_linked_account_id
    ON payment_styles(linked_account_id) WHERE linked_account_id IS NOT NULL;

-- Keep V265's legacy-shadow guard for compatibility reads, and add a second
-- guard for the UUID truth. Offline legacy scripts populate both columns.
CREATE TRIGGER trg_psref_accounts_style_uuid
    BEFORE INSERT OR UPDATE OF style_id ON accounts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference(
        'style_id', 'ACCOUNT', 'true', 'true', 'false', 'false');

-- Reactivating or restoring an account must revalidate its unchanged style.
CREATE TRIGGER trg_psref_accounts_active_uuid
    BEFORE UPDATE OF status, is_deleted ON accounts
    FOR EACH ROW
    WHEN (NEW.status = '使用' AND COALESCE(NEW.is_deleted, FALSE) = FALSE)
    EXECUTE FUNCTION fn_guard_payment_style_reference(
        'style_id', 'ACCOUNT', 'true', 'true', 'false', 'true');
CREATE TRIGGER trg_psref_accounts_active_legacy
    BEFORE UPDATE OF status, is_deleted ON accounts
    FOR EACH ROW
    WHEN (NEW.status = '使用'
          AND COALESCE(NEW.is_deleted, FALSE) = FALSE
          AND NEW.style_id IS NULL)
    EXECUTE FUNCTION fn_guard_payment_style_reference(
        'style_legacy_id', 'ACCOUNT', 'true', 'true', 'true', 'true');

-- Conversely, an active account prevents its style from being disabled or
-- deleted. This is the DB final defense for native SQL and future writers.
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
          AND (
              account.style_id = NEW.id
              OR (account.style_id IS NULL
                  AND NEW.legacy_id IS NOT NULL
                  AND account.style_legacy_id = NEW.legacy_id)
          )
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = '收付款类别仍被使用中的账户引用，不能停用或删除';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_psref_style_active_accounts
    BEFORE UPDATE OF status, is_deleted ON payment_styles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_active_account_style_status();

CREATE OR REPLACE FUNCTION account_style_id(p_account_id UUID) RETURNS UUID AS $$
    SELECT COALESCE(
        (SELECT account.style_id
           FROM accounts account
          WHERE account.id = p_account_id
            AND account.style_id IS NOT NULL),
        (SELECT style.id
           FROM accounts account
           JOIN payment_styles style
             ON account.style_id IS NULL
            AND style.legacy_id = account.style_legacy_id
          WHERE account.id = p_account_id),
        (SELECT style.id
           FROM accounts account
           JOIN payment_styles style
             ON style.path = CASE WHEN account.account_type = 'CASH' THEN '/101/' ELSE '/102/' END
          WHERE account.id = p_account_id),
        (SELECT id FROM payment_styles WHERE path = '/102/'));
$$ LANGUAGE SQL STABLE;

COMMENT ON COLUMN accounts.style_id IS
    'Accounting style UUID truth -> payment_styles.id; style_legacy_id is a migration shadow only.';
COMMENT ON COLUMN payment_styles.linked_account_id IS
    'Linked account UUID truth -> accounts.id; linked_account_legacy_id is a migration shadow only.';
COMMENT ON FUNCTION fn_guard_active_account_style_status() IS
    'Prevents disabling/deleting a payment style still referenced by an active account under the shared hierarchy lock.';
