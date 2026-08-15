-- =====================================================================
-- V286: allow extension-only employee_sensitive rows
-- =====================================================================
-- V08's bootstrap ADMIN employee and reviewed legacy imports can predate an
-- identity-card/mobile enrollment while still carrying one of the seven
-- extension values moved by V282. The application already treats a missing
-- identity or phone as "cannot provision a login", not as fabricated data.
--
-- Let the V282 JVM runner create a row containing only the extension
-- ciphertext that actually exists. Do not synthesize an identity or phone;
-- onboarding and later account provisioning retain their service-level
-- validation. The identity HMAC partial unique index continues to ignore
-- NULL, and nullable mobile HMAC lookups remain unchanged.
-- =====================================================================

ALTER TABLE employee_sensitive
    ALTER COLUMN id_card_enc DROP NOT NULL,
    ALTER COLUMN phone_enc DROP NOT NULL;

COMMENT ON COLUMN employee_sensitive.id_card_enc IS
    'Encrypted identity number; NULL for bootstrap/legacy employees not yet identity-enrolled';
COMMENT ON COLUMN employee_sensitive.phone_enc IS
    'Encrypted primary mobile; NULL for bootstrap/legacy employees not yet mobile-enrolled';
