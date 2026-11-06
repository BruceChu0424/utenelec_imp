-- Reuse the existing immutable actor-owned journal. Existing application IDs,
-- fingerprints, bytes, private result payloads and audit exclusions stay intact.
ALTER TABLE finance_application_operations DROP CONSTRAINT ck_finance_application_operation_scope;
ALTER TABLE finance_application_operations ADD CONSTRAINT ck_finance_application_operation_scope CHECK (
 application_id IS NOT NULL OR operation IN (
  'SETTINGS_SAVE','ROLE_SAVE','ROLE_REMOVE','PROCUREMENT_AP_POLICY_SAVE',
  'GL_REPORT_BINDING_REPLACE','GL_REPORT_BINDINGS_SEED','INVENTORY_COST_POLICY_SAVE',
  'INVENTORY_COST_PERIOD_CHOICE','INVENTORY_COST_POST','INVENTORY_COST_CLOSE',
  'FINANCE_DOCUMENT_APPROVE','FINANCE_DOCUMENT_UNAPPROVE','FINANCE_DOCUMENT_UPDATE'));
COMMENT ON CONSTRAINT ck_finance_application_operation_scope ON finance_application_operations IS
 'Explicit finance commands may omit application_id; immutable original actor/body/result receipts share one mechanism.';
-- The chart keeps its existing independent fingerprint/table. Its historical
-- receipts and new unwritten tombstones must both remain append-only.
CREATE TRIGGER finance_chart_manual_operations_immutable BEFORE UPDATE OR DELETE ON finance_chart_manual_operations
 FOR EACH ROW EXECUTE FUNCTION fn_finance_application_events_immutable();
