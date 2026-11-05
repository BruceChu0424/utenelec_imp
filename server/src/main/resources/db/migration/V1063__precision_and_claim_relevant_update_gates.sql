-- Preserve the existing guards and their actual write authority while avoiding
-- calls whose only UPDATE branch is a comparison of unchanged frozen fields.
-- INSERT adoption remains mandatory; every split precision guard remains ALWAYS.
DO $precision_relevant_updates$
DECLARE relation_name text;
BEGIN
 FOREACH relation_name IN ARRAY ARRAY['stock_value_nodes','stock_value_edges','stock_value_events','stock_value_tasks',
  'stock_value_node_revisions','stock_value_position_transfers','stock_value_production_cost_revisions','stock_value_production_cost_tasks'] LOOP
  EXECUTE format('DROP TRIGGER trg_00_inventory_value_precision ON %I',relation_name);
  EXECUTE format('CREATE TRIGGER trg_00_inventory_value_precision BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_value_precision()',relation_name);
  EXECUTE format('CREATE TRIGGER trg_00_inventory_value_precision_upd BEFORE UPDATE ON %I FOR EACH ROW WHEN (OLD.value_precision_version IS DISTINCT FROM NEW.value_precision_version OR OLD.business_precision_policy IS DISTINCT FROM NEW.business_precision_policy) EXECUTE FUNCTION fn_guard_inventory_value_precision()',relation_name);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_00_inventory_value_precision',relation_name);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_00_inventory_value_precision_upd',relation_name);
 END LOOP;
END $precision_relevant_updates$;

-- Reserving a document number is an INSERT operation. Existing numbers use the
-- same immutable UPDATE guard as all other business documents (V674/V734).
DROP TRIGGER finance_application_identifier ON finance_applications;
CREATE TRIGGER finance_application_identifier BEFORE INSERT ON finance_applications
 FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_APPLICATION','application_no','');
CREATE TRIGGER finance_application_identifier_upd BEFORE UPDATE OF application_no ON finance_applications
 FOR EACH ROW WHEN (OLD.application_no IS DISTINCT FROM NEW.application_no OR NULLIF(btrim(NEW.application_no),'') IS NULL)
 EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('application_no','');

DROP TRIGGER trg_business_document_applications ON business_applications;
CREATE TRIGGER trg_business_document_applications BEFORE INSERT ON business_applications
 FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('BUSINESS_APPLICATION','application_no','');
CREATE TRIGGER trg_business_document_applications_upd BEFORE UPDATE OF application_no ON business_applications
 FOR EACH ROW WHEN (OLD.application_no IS DISTINCT FROM NEW.application_no OR NULLIF(btrim(NEW.application_no),'') IS NULL)
 EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('application_no','');

-- The deferred claim check reads this complete immutable identity plus the
-- consumed/released/deleted facts. Metadata-only and no-op writes add no work.
-- Keep the identity function as the single list of source identity attributes.
DROP TRIGGER sales_order_claim_source_quantity ON stock_reservations;
CREATE CONSTRAINT TRIGGER sales_order_claim_source_quantity AFTER INSERT ON stock_reservations
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_sales_delivery_order_claim();
CREATE CONSTRAINT TRIGGER sales_order_claim_source_quantity_upd AFTER UPDATE ON stock_reservations
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 WHEN (OLD.id IS DISTINCT FROM NEW.id
  OR fn_sales_delivery_order_claim_identity(OLD) IS DISTINCT FROM fn_sales_delivery_order_claim_identity(NEW)
  OR (OLD.consumed_qty,OLD.released_qty,OLD.is_deleted) IS DISTINCT FROM (NEW.consumed_qty,NEW.released_qty,NEW.is_deleted))
 EXECUTE FUNCTION fn_check_sales_delivery_order_claim();

DROP TRIGGER sales_order_claim_storage_quantity ON stock_reservation_storage_positions;
CREATE CONSTRAINT TRIGGER sales_order_claim_storage_quantity AFTER INSERT ON stock_reservation_storage_positions
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_sales_delivery_order_claim();
CREATE CONSTRAINT TRIGGER sales_order_claim_storage_quantity_upd AFTER UPDATE ON stock_reservation_storage_positions
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 WHEN ((OLD.reservation_id,OLD.warehouse_id,OLD.qty) IS DISTINCT FROM (NEW.reservation_id,NEW.warehouse_id,NEW.qty))
 EXECUTE FUNCTION fn_check_sales_delivery_order_claim();
