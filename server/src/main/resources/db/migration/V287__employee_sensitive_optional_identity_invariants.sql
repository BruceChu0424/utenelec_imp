-- =====================================================================
-- V287: preserve optional primary-identity derivation invariants
-- =====================================================================
-- V286 intentionally allows an employee_sensitive row to contain only the
-- extension ciphertext introduced by V282. A missing identity/mobile cipher
-- must not, however, leave a hash or identity-card suffix that makes the row
-- look enrolled while its authoritative value cannot be decrypted.
--
-- Before V286 both cipher columns were NOT NULL, so validating these forward
-- checks is safe for every database upgraded through the normal Flyway chain.
-- Any database changed out of band fails closed and must be reconciled rather
-- than silently discarding an orphaned hash/suffix.
-- =====================================================================

ALTER TABLE employee_sensitive
    ADD CONSTRAINT employee_sensitive_id_card_derivation_ck
    CHECK (
        id_card_enc IS NOT NULL
        OR (id_card_last4 IS NULL AND id_card_hash IS NULL)
    ) NOT VALID;

ALTER TABLE employee_sensitive
    VALIDATE CONSTRAINT employee_sensitive_id_card_derivation_ck;

ALTER TABLE employee_sensitive
    ADD CONSTRAINT employee_sensitive_phone_derivation_ck
    CHECK (phone_enc IS NOT NULL OR phone_hash IS NULL)
    NOT VALID;

ALTER TABLE employee_sensitive
    VALIDATE CONSTRAINT employee_sensitive_phone_derivation_ck;

COMMENT ON CONSTRAINT employee_sensitive_id_card_derivation_ck
    ON employee_sensitive IS
    'Optional identity is absent only when its last4 and HMAC derivations are also absent';
COMMENT ON CONSTRAINT employee_sensitive_phone_derivation_ck
    ON employee_sensitive IS
    'Optional primary mobile is absent only when its HMAC derivation is also absent';
