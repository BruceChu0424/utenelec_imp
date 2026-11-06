-- Complete customer, supplier and mould master summaries reuse their original list owners.
-- Keep every previously installed source marker and precision/business rule unchanged.
INSERT INTO summary_read_domains(domain) VALUES ('client-master-list');
INSERT INTO summary_read_domains(domain) VALUES ('supplier-master-list');
INSERT INTO summary_read_domains(domain) VALUES ('mould-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON client_categories REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON client_categories REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON client_categories REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON client_categories  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON client_co_owners REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON client_co_owners REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON client_co_owners REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON client_co_owners  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON client_visibility_grants REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON client_visibility_grants REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON client_visibility_grants REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON client_visibility_grants  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON clients REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON clients REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON clients REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON clients  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON employee_identity_aliases REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON employee_identity_aliases REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON employee_identity_aliases REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON employee_identity_aliases  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON employee_identity_user_tombstones REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON employee_identity_user_tombstones REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON employee_identity_user_tombstones REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON employee_identity_user_tombstones  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON employees REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON employees REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON employees REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON employees  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON mould_categories REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('mould-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON mould_categories REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('mould-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON mould_categories REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('mould-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON mould_categories  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('mould-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON moulds REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('mould-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON moulds REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('mould-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON moulds REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('mould-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON moulds  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('mould-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON settlement_methods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON settlement_methods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON settlement_methods REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON settlement_methods  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON subcontract_order_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON subcontract_order_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON subcontract_order_items REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON subcontract_order_items  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON subcontract_orders REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON subcontract_orders REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON subcontract_orders REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON subcontract_orders  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON subcontract_short_delivery_cases REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON subcontract_short_delivery_cases REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON subcontract_short_delivery_cases REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON subcontract_short_delivery_cases  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON subcontract_wastes REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON subcontract_wastes REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON subcontract_wastes REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON subcontract_wastes  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON supplier_categories REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON supplier_categories REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON supplier_categories REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON supplier_categories  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON suppliers REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON suppliers REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON suppliers REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON suppliers  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('supplier-master-list');

CREATE TRIGGER trg_master_sibling_summary_insert AFTER INSERT ON users REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_update AFTER UPDATE ON users REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_delete AFTER DELETE ON users REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');
CREATE TRIGGER trg_master_sibling_summary_truncate AFTER TRUNCATE ON users  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('client-master-list','supplier-master-list');

-- Every new statement trigger uses the one persisted-transaction gate installer.
SELECT public.fn_refresh_summary_read_marker_gates();
