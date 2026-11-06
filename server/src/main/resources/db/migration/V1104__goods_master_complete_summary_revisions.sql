-- Goods complete summaries keep their own transactional dependency closure.
-- Existing summary/native trigger definitions and arguments remain unchanged.
INSERT INTO summary_read_domains(domain) VALUES ('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON colors REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON colors REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON colors REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON colors  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON currencies REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON currencies REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON currencies REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON currencies  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON departments REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON departments REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON departments REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON departments  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON goods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON goods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON goods REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON goods  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON goods_bom_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON goods_bom_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON goods_bom_items REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON goods_bom_items  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON material_categories REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON material_categories REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON material_categories REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON material_categories  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON moulds REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON moulds REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON moulds REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON moulds  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON stock_balances REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON stock_balances REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON stock_balances REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON stock_balances  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON units REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON units REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON units REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON units  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

CREATE TRIGGER trg_goods_master_summary_insert AFTER INSERT ON warehouses REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_update AFTER UPDATE ON warehouses REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_delete AFTER DELETE ON warehouses REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');
CREATE TRIGGER trg_goods_master_summary_truncate AFTER TRUNCATE ON warehouses  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain('goods-master-list');

-- Newly installed statement triggers use the same persisted-transaction gate.
SELECT public.fn_refresh_summary_read_marker_gates();
