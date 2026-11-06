-- PROVISIONAL VERSION: choose only after fresh Main+parallel reservation CAS review.
-- Each transaction publishes one marker per minimal read domain. Business writers never lock a shared revision row.
CREATE TABLE summary_read_domains (
 domain text PRIMARY KEY,epoch uuid NOT NULL DEFAULT gen_random_uuid(),
 compacted_markers numeric(40,0) NOT NULL DEFAULT 0 CHECK(compacted_markers>=0)
);
CREATE TABLE summary_read_markers (
 domain text NOT NULL,transaction_id bigint NOT NULL,
 PRIMARY KEY(domain,transaction_id)
);
COMMENT ON TABLE summary_read_markers IS 'Transactional summary freshness metadata; no source content/authorization decisions. No FK: writers never lock shared domain rows.';
CREATE FUNCTION fn_guard_summary_read_metadata() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF current_user IS DISTINCT FROM (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid=TG_RELID) THEN
  RAISE EXCEPTION 'summary freshness metadata may only be maintained by its owned functions' USING ERRCODE='42501';
 END IF;
 IF TG_LEVEL='STATEMENT' THEN RETURN NULL; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_summary_metadata_write BEFORE INSERT OR UPDATE OR DELETE ON summary_read_domains FOR EACH ROW EXECUTE FUNCTION fn_guard_summary_read_metadata();
CREATE TRIGGER trg_summary_metadata_write BEFORE INSERT OR UPDATE OR DELETE ON summary_read_markers FOR EACH ROW EXECUTE FUNCTION fn_guard_summary_read_metadata();
CREATE TRIGGER trg_summary_metadata_truncate BEFORE TRUNCATE ON summary_read_domains FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_summary_read_metadata();
CREATE TRIGGER trg_summary_metadata_truncate BEFORE TRUNCATE ON summary_read_markers FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_summary_read_metadata();
CREATE FUNCTION fn_mark_summary_read_domain() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE domain_name text;
BEGIN
 IF TG_OP IN ('INSERT','UPDATE') THEN
  IF NOT EXISTS(SELECT 1 FROM summary_new_rows) THEN RETURN NULL; END IF;
 ELSIF TG_OP='DELETE' THEN
  IF NOT EXISTS(SELECT 1 FROM summary_old_rows) THEN RETURN NULL; END IF;
 END IF;
 FOREACH domain_name IN ARRAY TG_ARGV LOOP
  INSERT INTO public.summary_read_markers(domain,transaction_id) VALUES(domain_name,txid_current()) ON CONFLICT DO NOTHING;
 END LOOP;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION fn_mark_summary_read_domain() FROM PUBLIC;
-- Safe metadata-only operation: no caller-chosen count/epoch, SQL text or business rows.
-- The owner boundary also survives a later generic runtime-role GRANT on public tables.
CREATE FUNCTION fn_compact_summary_read_domain(p_domain text) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE removed_count integer;
BEGIN
 PERFORM domain FROM public.summary_read_domains WHERE domain=p_domain FOR UPDATE SKIP LOCKED;
 IF NOT FOUND THEN RETURN 0; END IF;
 WITH picked AS(SELECT ctid FROM public.summary_read_markers WHERE domain=p_domain ORDER BY transaction_id LIMIT 2000),
 removed AS(DELETE FROM public.summary_read_markers WHERE ctid IN(SELECT ctid FROM picked) RETURNING 1)
 SELECT count(*)::integer INTO removed_count FROM removed;
 IF removed_count>0 THEN
  UPDATE public.summary_read_domains SET compacted_markers=compacted_markers+removed_count WHERE domain=p_domain;
 END IF;
 RETURN removed_count;
END $$;
INSERT INTO summary_read_domains(domain) VALUES('finance-asset-opening-groups');
INSERT INTO summary_read_domains(domain) VALUES('finance-accounting-imports');
INSERT INTO summary_read_domains(domain) VALUES('finance-chart-imports');
INSERT INTO summary_read_domains(domain) VALUES('finance-auxiliary-imports');
INSERT INTO summary_read_domains(domain) VALUES('finance-payable-statement-choices');
INSERT INTO summary_read_domains(domain) VALUES('goods-cost-templates');
INSERT INTO summary_read_domains(domain) VALUES('goods-cost-versions');
INSERT INTO summary_read_domains(domain) VALUES('periodic-preparation');
INSERT INTO summary_read_domains(domain) VALUES('periodic-candidate-catalog');
INSERT INTO summary_read_domains(domain) VALUES('periodic-pending');
INSERT INTO summary_read_domains(domain) VALUES('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON ar_ap_ledger REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON ar_ap_ledger REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON ar_ap_ledger REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON ar_ap_ledger  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON client_co_owners REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON client_co_owners REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON client_co_owners REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON client_co_owners  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON client_visibility_grants REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON client_visibility_grants REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON client_visibility_grants REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON client_visibility_grants  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON clients REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON clients REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON clients REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON clients  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON colors REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON colors REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON colors REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON colors  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON currencies REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON currencies REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON currencies REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON currencies  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON departments REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON departments REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON departments REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON departments  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON finance_accounting_import_batches REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-accounting-imports');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON finance_accounting_import_batches REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-accounting-imports');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON finance_accounting_import_batches REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-accounting-imports');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON finance_accounting_import_batches  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-accounting-imports');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON finance_asset_opening_groups REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-asset-opening-groups');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON finance_asset_opening_groups REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-asset-opening-groups');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON finance_asset_opening_groups REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-asset-opening-groups');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON finance_asset_opening_groups  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-asset-opening-groups');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON finance_chart_code_styles REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON finance_chart_code_styles REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON finance_chart_code_styles REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON finance_chart_code_styles  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON finance_chart_codes REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON finance_chart_codes REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON finance_chart_codes REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON finance_chart_codes  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON finance_chart_imports REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-chart-imports');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON finance_chart_imports REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-chart-imports');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON finance_chart_imports REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-chart-imports');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON finance_chart_imports  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-chart-imports');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON finance_payable_statement_adjustments REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON finance_payable_statement_adjustments REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON finance_payable_statement_adjustments REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON finance_payable_statement_adjustments  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON finance_statement_document_reviews REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON finance_statement_document_reviews REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON finance_statement_document_reviews REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON finance_statement_document_reviews  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON finance_statement_source_reviews REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-auxiliary-imports');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON finance_statement_source_reviews REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-auxiliary-imports');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON finance_statement_source_reviews REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-auxiliary-imports');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON finance_statement_source_reviews  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-auxiliary-imports');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON goods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions','periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON goods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions','periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON goods REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions','periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON goods  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates','goods-cost-versions','periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON goods_bom_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON goods_bom_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON goods_bom_items REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON goods_bom_items  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON goods_cost_sheets REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON goods_cost_sheets REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON goods_cost_sheets REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON goods_cost_sheets  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-versions');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON goods_cost_templates REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON goods_cost_templates REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON goods_cost_templates REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON goods_cost_templates  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('goods-cost-templates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON goods_periodic_material_choices REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON goods_periodic_material_choices REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON goods_periodic_material_choices REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON goods_periodic_material_choices  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON payment_styles REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON payment_styles REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON payment_styles REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON payment_styles  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON production_actual_output_supplement_proofs REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON production_actual_output_supplement_proofs REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON production_actual_output_supplement_proofs REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON production_actual_output_supplement_proofs  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON production_execution_periodic_materials REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON production_execution_periodic_materials REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON production_execution_periodic_materials REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON production_execution_periodic_materials  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON production_execution_segments REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON production_execution_segments REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON production_execution_segments REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON production_execution_segments  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON production_material_demands REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON production_material_demands REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON production_material_demands REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON production_material_demands  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON production_material_settlement_events REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON production_material_settlement_events REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON production_material_settlement_events REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON production_material_settlement_events  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON production_material_settlement_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON production_material_settlement_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON production_material_settlement_postings REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON production_material_settlement_postings  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON production_material_stock_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON production_material_stock_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON production_material_stock_postings REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON production_material_stock_postings  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-pending');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON purchase_receipt_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON purchase_receipt_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON purchase_receipt_items REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON purchase_receipt_items  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON purchase_receipts REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON purchase_receipts REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON purchase_receipts REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON purchase_receipts  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON subcontract_receipt_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON subcontract_receipt_items REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON subcontract_receipt_items REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON subcontract_receipt_items  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON subcontract_receipts REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON subcontract_receipts REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON subcontract_receipts REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON subcontract_receipts  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-payable-statement-choices');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON units REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON units REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON units REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON units  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-candidate-catalog','periodic-material-candidates','periodic-pending','periodic-preparation');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON workshop_material_count_adjustment_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON workshop_material_count_adjustment_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON workshop_material_count_adjustment_postings REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON workshop_material_count_adjustment_postings  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON workshop_material_count_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON workshop_material_count_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON workshop_material_count_postings REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON workshop_material_count_postings  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON workshop_material_other_issues REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON workshop_material_other_issues REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON workshop_material_other_issues REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON workshop_material_other_issues  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON workshop_material_period_lines REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON workshop_material_period_lines REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON workshop_material_period_lines REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON workshop_material_period_lines  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON workshop_material_requisition_lines REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON workshop_material_requisition_lines REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON workshop_material_requisition_lines REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON workshop_material_requisition_lines  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON workshop_material_requisition_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON workshop_material_requisition_postings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON workshop_material_requisition_postings REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON workshop_material_requisition_postings  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON workshop_material_requisitions REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON workshop_material_requisitions REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON workshop_material_requisitions REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON workshop_material_requisitions  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_insert AFTER INSERT ON workshop_material_settings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_update AFTER UPDATE ON workshop_material_settings REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_delete AFTER DELETE ON workshop_material_settings REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
CREATE TRIGGER trg_summary_read_marker_truncate AFTER TRUNCATE ON workshop_material_settings  FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('periodic-material-candidates');
