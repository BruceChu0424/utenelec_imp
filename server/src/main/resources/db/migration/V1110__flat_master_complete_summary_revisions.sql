-- Flat master streams use the same committed source-marker proof as category masters.
-- These are read freshness domains only: no change to writes, permissions or page caps.
INSERT INTO summary_read_domains(domain) VALUES
 ('color-master-list'),('unit-master-list'),('currency-master-list'),
 ('account-master-list'),('settlement-method-master-list');

CREATE TRIGGER trg_flat_master_summary_insert AFTER INSERT ON colors REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('color-master-list');
CREATE TRIGGER trg_flat_master_summary_update AFTER UPDATE ON colors REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('color-master-list');
CREATE TRIGGER trg_flat_master_summary_delete AFTER DELETE ON colors REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('color-master-list');
CREATE TRIGGER trg_flat_master_summary_truncate AFTER TRUNCATE ON colors FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('color-master-list');

CREATE TRIGGER trg_flat_master_summary_insert AFTER INSERT ON units REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('unit-master-list');
CREATE TRIGGER trg_flat_master_summary_update AFTER UPDATE ON units REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('unit-master-list');
CREATE TRIGGER trg_flat_master_summary_delete AFTER DELETE ON units REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('unit-master-list');
CREATE TRIGGER trg_flat_master_summary_truncate AFTER TRUNCATE ON units FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('unit-master-list');

CREATE TRIGGER trg_flat_master_summary_insert AFTER INSERT ON unit_measurement_profiles REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('unit-master-list');
CREATE TRIGGER trg_flat_master_summary_update AFTER UPDATE ON unit_measurement_profiles REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('unit-master-list');
CREATE TRIGGER trg_flat_master_summary_delete AFTER DELETE ON unit_measurement_profiles REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('unit-master-list');
CREATE TRIGGER trg_flat_master_summary_truncate AFTER TRUNCATE ON unit_measurement_profiles FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('unit-master-list');

CREATE TRIGGER trg_flat_master_summary_insert AFTER INSERT ON currencies REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('currency-master-list','account-master-list');
CREATE TRIGGER trg_flat_master_summary_update AFTER UPDATE ON currencies REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('currency-master-list','account-master-list');
CREATE TRIGGER trg_flat_master_summary_delete AFTER DELETE ON currencies REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('currency-master-list','account-master-list');
CREATE TRIGGER trg_flat_master_summary_truncate AFTER TRUNCATE ON currencies FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('currency-master-list','account-master-list');

CREATE TRIGGER trg_flat_master_summary_insert AFTER INSERT ON accounts REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('account-master-list');
CREATE TRIGGER trg_flat_master_summary_update AFTER UPDATE ON accounts REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('account-master-list');
CREATE TRIGGER trg_flat_master_summary_delete AFTER DELETE ON accounts REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('account-master-list');
CREATE TRIGGER trg_flat_master_summary_truncate AFTER TRUNCATE ON accounts FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('account-master-list');

CREATE TRIGGER trg_flat_master_summary_insert AFTER INSERT ON settlement_methods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('settlement-method-master-list');
CREATE TRIGGER trg_flat_master_summary_update AFTER UPDATE ON settlement_methods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('settlement-method-master-list');
CREATE TRIGGER trg_flat_master_summary_delete AFTER DELETE ON settlement_methods REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('settlement-method-master-list');
CREATE TRIGGER trg_flat_master_summary_truncate AFTER TRUNCATE ON settlement_methods FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('settlement-method-master-list');

SELECT public.fn_refresh_summary_read_marker_gates();
