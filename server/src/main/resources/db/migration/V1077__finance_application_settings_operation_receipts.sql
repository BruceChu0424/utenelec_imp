-- Reuse the existing actor-owned immutable application journal for configuration
-- commands. No synthetic application or duplicate journal is created.
ALTER TABLE finance_application_operations ALTER COLUMN application_id DROP NOT NULL;
ALTER TABLE finance_application_operations ADD CONSTRAINT ck_finance_application_operation_scope
 CHECK (application_id IS NOT NULL OR operation IN ('SETTINGS_SAVE','ROLE_SAVE','ROLE_REMOVE'));
COMMENT ON CONSTRAINT ck_finance_application_operation_scope ON finance_application_operations IS
 'Only settings/role commands have no application; original application receipts retain their UUID identity.';
-- Existing immutable trigger and COLUMN_SCOPED audit policy are unchanged:
-- result remains private and is not copied into audit detail.
