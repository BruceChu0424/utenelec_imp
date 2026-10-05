-- =====================================================================
-- V798: employee_sensitive.id_card_check, the stored identity-number check result
-- =====================================================================
-- Opening a login account for an existing employee no longer stops on a
-- wrong or missing identity number; it warns and gives HR a correction task.
-- That warning and the HR task list must not decrypt every identity cipher on
-- each read, so the check result is written once, next to the cipher, by the
-- only Java writer (EmployeePiiWriter) and stored as non-sensitive metadata.
--
-- Values: 'valid', 'unchecked' (legacy import, resolved by the startup runner
-- EmployeeIdentityCheckRunner, which holds the JVM-side key), 'unreadable'
-- (the runner could not decrypt the cipher: corrupt data, or a key version
-- missing from the key ring; stored so it is not retried on every startup and
-- cleared only when HR saves the number again) or one problem code from
-- IdCardUtil.check: empty, length:<n>, character:<position>, birth_date,
-- birth_too_early, birth_future, region_code, sequence_code, check_digit.
-- A code carries positions and lengths only, never digits of the number.
-- NULL exactly when there is no identity cipher.
--
-- The database cannot decrypt (the key is bound from Java per statement), so
-- existing ciphers start as 'unchecked'. Adding a column to employee_sensitive
-- needs no fixture or reset-policy change; no table is created.
-- =====================================================================

ALTER TABLE employee_sensitive ADD COLUMN id_card_check TEXT;

UPDATE employee_sensitive
   SET id_card_check = 'unchecked'
 WHERE id_card_enc IS NOT NULL;

ALTER TABLE employee_sensitive
    ADD CONSTRAINT employee_sensitive_id_card_check_value_ck
        CHECK (id_card_check ~ '^(valid|unchecked|unreadable|empty|length:[0-9]{1,3}|character:[0-9]{1,2}|birth_date|birth_too_early|birth_future|region_code|sequence_code|check_digit)$'),
    ADD CONSTRAINT employee_sensitive_id_card_check_presence_ck
        CHECK ((id_card_enc IS NULL) = (id_card_check IS NULL));

COMMENT ON COLUMN employee_sensitive.id_card_check IS
    'Identity number check result written together with the cipher: valid, unchecked (legacy import, resolved by the startup runner), unreadable (the startup runner could not decrypt it; HR re-enters the number) or a problem code (positions and lengths only, never digits); NULL exactly when id_card_enc is NULL';
COMMENT ON CONSTRAINT employee_sensitive_id_card_check_value_ck ON employee_sensitive IS
    'Only valid, unchecked, unreadable or a known identity-number problem code';
COMMENT ON CONSTRAINT employee_sensitive_id_card_check_presence_ck ON employee_sensitive IS
    'Every stored identity cipher carries a check result; no cipher, no result';
