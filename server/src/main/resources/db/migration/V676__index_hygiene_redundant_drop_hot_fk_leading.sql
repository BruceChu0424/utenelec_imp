-- V676 ADR-106 索引卫生：删掉被前缀覆盖/与唯一约束重复的冗余索引，给真实热点关联列补领头索引
--
-- 背景(审计 db-schema-14 / db-schema-15)：迁移逐次追加索引，从没做过全局去重——单号/旧库主键普通索引
-- 与同列唯一约束重复、分类树 *_parent 被 *_parent_sort 覆盖、同一定义建了两遍……每条都白白增加写入开销。
-- 另一方面，估值图、需求、预留、计划明细、总账凭证的反查列(触发器守恒校验与服务查询正按这些列回查
-- 子表)没有领头索引，数据量上来就退化成全表扫描；V675 改为改单位时按需查数量来源，各来源货品列也要
-- 有领头索引。
--
-- 冗余判定(与 SchemaIndexHygieneContractTest 同一条 SQL)：同表、同访问方法、同部分谓词、同表达式，
-- 键列(连同算子类、排序规则、排序选项)是另一索引的前缀，且 INCLUDE 列已被对方携带；支撑主键/唯一/
-- 排他约束的索引永不删除，唯一索引只在对方是同列唯一索引、且对方的空值规则不比它宽(NULLS NOT DISTINCT
-- 只被 NULLS NOT DISTINCT 覆盖)时才算重复。完全相同的两条留旧删新。下面 96 条都是普通(非唯一)索引。
-- 暂不删除两条(已在契约测试白名单写明原因)：
--   audit_log_archive_created_at_idx —— 审计表由审计整改工作流统一处理；
--   idx_procurement_iqc_stock_in_item_batch —— ops/reset_business_data.sql 的 V448 读路径索引自检要求它存在。
--
-- 只给真实热点补索引：不补 *_by 审计列、字典/人员父表；估值节点自引用游标列(return_head_id 等，
-- 每次移动游标都会改写，建索引会让这些更新失去 HOT)、没有任何查询按其回查的列与已退役的 MAKE 委托表
-- 不补，契约测试白名单逐条写明原因。

-- 一、删除冗余索引(括号内为覆盖它的索引)
DROP INDEX IF EXISTS idx_accounts_legacy_id; -- accounts (accounts_legacy_id_key)
DROP INDEX IF EXISTS idx_clientcat_legacy_id; -- client_categories (client_categories_legacy_id_key)
DROP INDEX IF EXISTS idx_clientcat_parent; -- client_categories (idx_clientcat_parent_sort)
DROP INDEX IF EXISTS idx_clients_legacy_id; -- clients (clients_legacy_id_key)
DROP INDEX IF EXISTS idx_colors_legacy_id; -- colors (colors_legacy_id_key)
DROP INDEX IF EXISTS idx_currencies_legacy_id; -- currencies (currencies_legacy_id_key)
DROP INDEX IF EXISTS idx_departments_parent; -- departments (idx_departments_parent_sort)
DROP INDEX IF EXISTS idx_employee_phones_employee; -- employee_phones (uq_employee_phones_hash)
DROP INDEX IF EXISTS idx_expense_claim_invoices_claim; -- expense_claim_invoices (expense_claim_invoices_line_uk)
DROP INDEX IF EXISTS idx_expense_claim_items_claim; -- expense_claim_items (expense_claim_items_line_uk)
DROP INDEX IF EXISTS idx_fbt_bill_no; -- finance_bank_transfers (finance_bank_transfers_bill_no_key)
DROP INDEX IF EXISTS idx_fbt_legacy; -- finance_bank_transfers (finance_bank_transfers_legacy_id_key)
DROP INDEX IF EXISTS idx_fexp_bill_no; -- finance_expenses (finance_expenses_bill_no_key)
DROP INDEX IF EXISTS idx_fexp_legacy; -- finance_expenses (finance_expenses_legacy_id_key)
DROP INDEX IF EXISTS idx_foi_bill_no; -- finance_other_incomes (finance_other_incomes_bill_no_key)
DROP INDEX IF EXISTS idx_foi_legacy; -- finance_other_incomes (finance_other_incomes_legacy_id_key)
DROP INDEX IF EXISTS idx_fpm_bill_no; -- finance_payments (finance_payments_bill_no_key)
DROP INDEX IF EXISTS idx_fpm_legacy; -- finance_payments (finance_payments_legacy_id_key)
DROP INDEX IF EXISTS idx_frt_bill_no; -- finance_receipts (finance_receipts_bill_no_key)
DROP INDEX IF EXISTS idx_frt_legacy; -- finance_receipts (finance_receipts_legacy_id_key)
DROP INDEX IF EXISTS idx_goods_bom_legacy_id; -- goods_bom_items (goods_bom_items_legacy_id_key)
DROP INDEX IF EXISTS idx_goods_legacy_id; -- goods (goods_legacy_id_key)
DROP INDEX IF EXISTS idx_matcat_legacy_id; -- material_categories (material_categories_legacy_id_key)
DROP INDEX IF EXISTS idx_matcat_parent; -- material_categories (idx_matcat_parent_sort)
DROP INDEX IF EXISTS idx_mouldcat_legacy_id; -- mould_categories (mould_categories_legacy_id_key)
DROP INDEX IF EXISTS idx_mouldcat_parent; -- mould_categories (idx_mouldcat_parent_sort)
DROP INDEX IF EXISTS idx_moulds_legacy_id; -- moulds (moulds_legacy_id_key)
DROP INDEX IF EXISTS idx_notice_acknowledgments_notice; -- notice_acknowledgments (notice_acknowledgments_pkey)
DROP INDEX IF EXISTS idx_notice_blessings_notice; -- notice_blessings (notice_blessings_notice_id_user_id_key)
DROP INDEX IF EXISTS idx_notice_user_states_user; -- notice_user_states (idx_notice_user_states_todo_completion)
DROP INDEX IF EXISTS idx_payroll_items_slip; -- payroll_items (payroll_items_line_uk)
DROP INDEX IF EXISTS idx_pcrt_billno; -- purchase_receipts (purchase_receipts_bill_no_key)
DROP INDEX IF EXISTS idx_pcrt_legacy; -- purchase_receipts (purchase_receipts_legacy_id_key)
DROP INDEX IF EXISTS idx_pdl_draw; -- plan_draw_links (uq_pdl_active_draw)
DROP INDEX IF EXISTS idx_pdl_plan; -- plan_draw_links (uq_pdl_active_plan_draw)
DROP INDEX IF EXISTS idx_pdr_billno; -- production_daily_reports (production_daily_reports_bill_no_key)
DROP INDEX IF EXISTS idx_pdri_goods; -- production_daily_report_items (idx_production_daily_report_items_goods_color)
DROP INDEX IF EXISTS idx_po_billno; -- purchase_orders (purchase_orders_bill_no_key)
DROP INDEX IF EXISTS idx_po_legacy; -- purchase_orders (purchase_orders_legacy_id_key)
DROP INDEX IF EXISTS idx_pp_billno; -- production_plans (production_plans_bill_no_key)
DROP INDEX IF EXISTS idx_pp_legacy; -- production_plans (production_plans_legacy_id_key)
DROP INDEX IF EXISTS idx_pr_billno; -- purchase_requests (purchase_requests_bill_no_key)
DROP INDEX IF EXISTS idx_pr_legacy; -- purchase_requests (purchase_requests_legacy_id_key)
DROP INDEX IF EXISTS idx_preplan_subcontract_make_task_batches_task; -- preplan_subcontract_make_task_batches (preplan_subcontract_make_task_batch_task_id_idempotency_key_key)
DROP INDEX IF EXISTS idx_pret_billno; -- purchase_returns (purchase_returns_bill_no_key)
DROP INDEX IF EXISTS idx_pret_legacy; -- purchase_returns (purchase_returns_legacy_id_key)
DROP INDEX IF EXISTS idx_production_finished_arrival_registration_items_registration; -- production_finished_arrival_registration_items (production_finished_arrival_registration_item_uk)
DROP INDEX IF EXISTS idx_production_finished_in_confirm_batch_items_batch; -- production_finished_in_confirm_batch_items (production_finished_in_confirm_batch_item_batch_position_uk)
DROP INDEX IF EXISTS idx_production_fqc_inspection_sheet_items_sheet; -- production_fqc_inspection_sheet_items (production_fqc_inspection_sheet_item_line_uk)
DROP INDEX IF EXISTS idx_production_material_demand_goods; -- production_material_demands (idx_pmd_where_used_all_evidence)
DROP INDEX IF EXISTS idx_ps_legacy_id; -- payment_styles (payment_styles_legacy_id_key)
DROP INDEX IF EXISTS idx_ps_parent; -- payment_styles (idx_ps_parent_sort)
DROP INDEX IF EXISTS idx_rd_task_forwarders_task; -- rd_task_forwarders (uq_rd_task_forwarders)
DROP INDEX IF EXISTS idx_sapp_billno; -- subcontract_applications (subcontract_applications_bill_no_key)
DROP INDEX IF EXISTS idx_sapp_legacy; -- subcontract_applications (subcontract_applications_legacy_id_key)
DROP INDEX IF EXISTS idx_sb_goods; -- stock_balances (idx_stock_balances_goods_cover)
DROP INDEX IF EXISTS idx_sinq_billno; -- subcontract_inquiries (subcontract_inquiries_bill_no_key)
DROP INDEX IF EXISTS idx_sinq_legacy; -- subcontract_inquiries (subcontract_inquiries_legacy_id_key)
DROP INDEX IF EXISTS idx_smiss_billno; -- subcontract_material_issues (subcontract_material_issues_bill_no_key)
DROP INDEX IF EXISTS idx_smiss_legacy; -- subcontract_material_issues (subcontract_material_issues_legacy_id_key)
DROP INDEX IF EXISTS idx_smret_billno; -- subcontract_material_returns (subcontract_material_returns_bill_no_key)
DROP INDEX IF EXISTS idx_smret_legacy; -- subcontract_material_returns (subcontract_material_returns_legacy_id_key)
DROP INDEX IF EXISTS idx_so_billno; -- sales_orders (sales_orders_bill_no_key)
DROP INDEX IF EXISTS idx_so_legacy; -- sales_orders (sales_orders_legacy_id_key)
DROP INDEX IF EXISTS idx_soci_legacy; -- sales_order_cost_items (sales_order_cost_items_legacy_id_key)
DROP INDEX IF EXISTS idx_sord_billno; -- subcontract_orders (subcontract_orders_bill_no_key)
DROP INDEX IF EXISTS idx_sord_legacy; -- subcontract_orders (subcontract_orders_legacy_id_key)
DROP INDEX IF EXISTS idx_sos_billno; -- sales_other_shipments (sales_other_shipments_bill_no_key)
DROP INDEX IF EXISTS idx_sos_legacy; -- sales_other_shipments (sales_other_shipments_legacy_id_key)
DROP INDEX IF EXISTS idx_sq_billno; -- sales_quotes (sales_quotes_bill_no_key)
DROP INDEX IF EXISTS idx_sq_legacy; -- sales_quotes (sales_quotes_legacy_id_key)
DROP INDEX IF EXISTS idx_sr_billno; -- sales_returns (sales_returns_bill_no_key)
DROP INDEX IF EXISTS idx_sr_legacy; -- sales_returns (sales_returns_legacy_id_key)
DROP INDEX IF EXISTS idx_srcpt_billno; -- subcontract_receipts (subcontract_receipts_bill_no_key)
DROP INDEX IF EXISTS idx_srcpt_legacy; -- subcontract_receipts (subcontract_receipts_legacy_id_key)
DROP INDEX IF EXISTS idx_sret_billno; -- subcontract_returns (subcontract_returns_bill_no_key)
DROP INDEX IF EXISTS idx_sret_legacy; -- subcontract_returns (subcontract_returns_legacy_id_key)
DROP INDEX IF EXISTS idx_ss_billno; -- sales_shipments (sales_shipments_bill_no_key)
DROP INDEX IF EXISTS idx_ss_legacy; -- sales_shipments (sales_shipments_legacy_id_key)
DROP INDEX IF EXISTS idx_stock_documents_maker_id; -- stock_documents (idx_stock_documents_maker)
DROP INDEX IF EXISTS idx_stock_movements_goods_date; -- stock_movements (idx_sm_goods_date)
DROP INDEX IF EXISTS idx_suppliercat_legacy_id; -- supplier_categories (supplier_categories_legacy_id_key)
DROP INDEX IF EXISTS idx_suppliercat_parent; -- supplier_categories (idx_suppliercat_parent_sort)
DROP INDEX IF EXISTS idx_suppliers_legacy_id; -- suppliers (suppliers_legacy_id_key)
DROP INDEX IF EXISTS idx_swst_billno; -- subcontract_wastes (subcontract_wastes_bill_no_key)
DROP INDEX IF EXISTS idx_swst_legacy; -- subcontract_wastes (subcontract_wastes_legacy_id_key)
DROP INDEX IF EXISTS idx_units_legacy_id; -- units (units_legacy_id_key)
DROP INDEX IF EXISTS idx_warehouses_legacy_id; -- warehouses (warehouses_legacy_id_key)
DROP INDEX IF EXISTS idx_workshop_custody_handoff_source; -- production_workshop_material_custody_handoffs (production_workshop_material__source_allocation_id_command__key)
DROP INDEX IF EXISTS idx_workshop_custody_move_target; -- production_workshop_material_custody_moves (uq_workshop_custody_move_target)
DROP INDEX IF EXISTS idx_workshop_direct_transfer_report; -- production_workshop_direct_transfers (uq_workshop_direct_transfer_key)
DROP INDEX IF EXISTS master_code_history_batch_idx; -- master_code_history (master_code_history_batch_entity_uq)
DROP INDEX IF EXISTS mv_fin_ar_ap_ym; -- finance_ar_ap_mv (mv_fin_ar_ap_uidx)
DROP INDEX IF EXISTS mv_production_monthly_type; -- production_monthly_mv (mv_production_monthly_uidx)
DROP INDEX IF EXISTS mv_stock_monthly_ym; -- stock_monthly_mv (mv_stock_monthly_uidx)
DROP INDEX IF EXISTS mv_subcontract_monthly_type; -- subcontract_monthly_mv (mv_subcontract_monthly_uidx)

-- 二、热点关联列领头索引：估值图、需求、预留、计划明细、总账凭证的引用方
CREATE INDEX idx_stock_value_postings_node_id ON stock_value_postings (node_id);
CREATE INDEX idx_stock_value_production_cost_tasks_input_node_id ON stock_value_production_cost_tasks (input_node_id);
CREATE INDEX idx_stock_value_production_cost_tasks_output_source_node_id ON stock_value_production_cost_tasks (output_source_node_id);
CREATE INDEX idx_stock_value_production_cost_tasks_execution_segment_id ON stock_value_production_cost_tasks (execution_segment_id);
CREATE INDEX idx_stock_value_production_cost_outputs_source_node_id ON stock_value_production_cost_outputs (source_node_id);
CREATE INDEX idx_stock_value_nodes_pool_id ON stock_value_nodes (pool_id);
CREATE INDEX idx_stock_value_nodes_creation_event_id ON stock_value_nodes (creation_event_id);
CREATE INDEX idx_stock_value_events_pool_id ON stock_value_events (pool_id);
CREATE INDEX idx_stock_value_events_source_node_id ON stock_value_events (source_node_id);
CREATE INDEX idx_stock_value_events_result_node_id ON stock_value_events (result_node_id);
CREATE INDEX idx_stock_value_events_result_head_id ON stock_value_events (result_head_id);
CREATE INDEX idx_stock_value_edges_creation_event_id ON stock_value_edges (creation_event_id);
CREATE INDEX idx_stock_value_node_revisions_event_id ON stock_value_node_revisions (event_id);
CREATE INDEX idx_stock_value_jobs_source_node_id ON stock_value_jobs (source_node_id);
CREATE INDEX idx_stock_value_openings_head_node_id ON stock_value_openings (head_node_id);
CREATE INDEX idx_stock_value_pools_head_node_id ON stock_value_pools (head_node_id);
CREATE INDEX idx_stock_value_production_cost_dirty_source_event_id ON stock_value_production_cost_dirty (source_event_id);
CREATE INDEX idx_stock_value_production_cost_objects_product_pool_id ON stock_value_production_cost_objects (product_pool_id);
CREATE INDEX idx_stock_value_production_cost_objects_current_revision_id ON stock_value_production_cost_objects (current_revision_id);
CREATE INDEX idx_stock_value_production_cost_shares_last_task_id ON stock_value_production_cost_shares (last_task_id);
CREATE INDEX idx_preplan_stock_entitlement_events_target_demand_id ON preplan_stock_entitlement_events (target_demand_id);
CREATE INDEX idx_pm_make_receipt_alloc_demand ON production_material_make_receipt_allocations (demand_id);
CREATE INDEX idx_production_material_peg_transfers_demand_id ON production_material_peg_transfers (demand_id);
CREATE INDEX idx_pm_subcontract_peg_transfers_demand ON production_material_subcontract_peg_transfers (demand_id);
CREATE INDEX idx_pm_subcontract_receipt_alloc_demand ON production_material_subcontract_receipt_allocations (demand_id);
CREATE INDEX idx_workshop_custody_moves_target_demand ON production_workshop_material_custody_moves (target_demand_id);
CREATE INDEX idx_workshop_custody_prep_target_demand ON production_workshop_material_custody_preparations (target_demand_id);
CREATE INDEX idx_production_fqc_replenishment_supply_gaps_demand_id ON production_fqc_replenishment_supply_gaps (demand_id);
CREATE INDEX idx_preplan_entitlement_target_reservation ON preplan_stock_entitlement_events (target_stock_reservation_id);
CREATE INDEX idx_preplan_root_output_events_source_reservation_id ON preplan_root_output_events (source_reservation_id);
CREATE INDEX idx_workshop_custody_prep_source_reservation ON production_workshop_material_custody_preparations (source_reservation_id);
CREATE INDEX idx_workshop_return_preplan_source_reservation ON production_workshop_return_preplan_events (source_reservation_id);
CREATE INDEX idx_subcontract_outbound_issue_alloc_reservation ON subcontract_outbound_issue_reservation_allocations (reservation_id);
CREATE INDEX idx_production_execution_segments_source_plan_item_id ON production_execution_segments (source_plan_item_id);
CREATE INDEX idx_production_fqc_inspections_source_plan_item_id ON production_fqc_inspections (source_plan_item_id);
CREATE INDEX idx_production_fqc_recovery_authorizations_source_plan_item_id ON production_fqc_recovery_authorizations (source_plan_item_id);
CREATE INDEX idx_fqc_contribution_adj_source_plan_item ON production_fqc_contribution_adjustments (source_plan_item_id);
CREATE INDEX idx_production_fqc_replenishment_cycles_source_plan_item_id ON production_fqc_replenishment_cycles (source_plan_item_id);
-- 并行会话 V647 的车间工单原位增长事件(只追加账本)按计划明细回查, 建表时未带该列领头索引
CREATE INDEX idx_execution_segment_growth_plan_item ON production_execution_segment_growth_events (plan_item_id);
CREATE INDEX idx_da_amortization_log_voucher_id ON da_amortization_log (voucher_id);
CREATE INDEX idx_fa_depreciation_log_voucher_id ON fa_depreciation_log (voucher_id);
CREATE INDEX idx_finance_asset_posting_lines_voucher_id ON finance_asset_posting_lines (voucher_id);
CREATE INDEX idx_finance_asset_posting_runs_voucher_id ON finance_asset_posting_runs (voucher_id);
CREATE INDEX idx_gl_vouchers_reversed_by_voucher_id ON gl_vouchers (reversed_by_voucher_id);

-- 三、货品数量来源的货品列领头索引(V675 改单位时按需 EXISTS，未使用的货品要查遍全部来源)
CREATE INDEX idx_inbound_expectation_items_goods_id ON inbound_expectation_items (goods_id);
CREATE INDEX idx_measurement_capture_evidence_goods_id ON measurement_capture_evidence (goods_id);
CREATE INDEX idx_measurement_capture_line_snapshots_goods_id ON measurement_capture_line_snapshots (goods_id);
CREATE INDEX idx_preplan_material_reallocations_goods_id ON preplan_material_reallocations (goods_id);
CREATE INDEX idx_preplan_public_supply_events_goods_id ON preplan_public_supply_events (goods_id);
CREATE INDEX idx_preplan_root_output_events_goods_id ON preplan_root_output_events (goods_id);
CREATE INDEX idx_preplan_subcontract_make_tasks_goods_id ON preplan_subcontract_make_tasks (goods_id);
CREATE INDEX idx_preplan_subcontract_handoff_items_goods ON preplan_subcontract_requirement_handoff_items (goods_id);
CREATE INDEX idx_preplan_subcontract_handoffs_target_goods ON preplan_subcontract_requirement_handoffs (target_goods_id);
CREATE INDEX idx_preplan_supply_actions_goods_id ON preplan_supply_actions (goods_id);
CREATE INDEX idx_procurement_arrival_exceptions_goods_id ON procurement_arrival_exceptions (goods_id);
CREATE INDEX idx_procurement_inspection_items_goods_id ON procurement_inspection_items (goods_id);
CREATE INDEX idx_procurement_iqc_rejection_cases_goods_id ON procurement_iqc_rejection_cases (goods_id);
CREATE INDEX idx_procurement_iqc_stock_in_batch_items_goods_id ON procurement_iqc_stock_in_batch_items (goods_id);
CREATE INDEX idx_production_execution_segments_product_goods_id ON production_execution_segments (product_goods_id);
CREATE INDEX idx_production_fqc_inspections_goods_id ON production_fqc_inspections (goods_id);
CREATE INDEX idx_production_fqc_recovery_authorizations_goods_id ON production_fqc_recovery_authorizations (goods_id);
CREATE INDEX idx_production_material_analysis_borrows_goods_id ON production_material_analysis_borrows (goods_id);
CREATE INDEX idx_production_material_analysis_items_goods_id ON production_material_analysis_items (goods_id);
CREATE INDEX idx_production_material_analysis_materials_goods_id ON production_material_analysis_materials (goods_id);
CREATE INDEX idx_production_material_demands_goods_id ON production_material_demands (goods_id);
CREATE INDEX idx_production_plan_items_mgoods_id ON production_plan_items (mgoods_id);
CREATE INDEX idx_sales_order_cost_items_alt_goods_id ON sales_order_cost_items (alt_goods_id);
CREATE INDEX idx_sales_return_quality_items_goods_id ON sales_return_quality_items (goods_id);
CREATE INDEX idx_stock_reservations_goods_id ON stock_reservations (goods_id);
CREATE INDEX idx_subcontract_loss_case_lines_goods_id ON subcontract_loss_case_lines (goods_id);
CREATE INDEX idx_subcontract_material_issue_items_parent_goods_id ON subcontract_material_issue_items (parent_goods_id);
CREATE INDEX idx_subcontract_material_plan_items_goods_id ON subcontract_material_plan_items (goods_id);
CREATE INDEX idx_subcontract_material_plan_items_parent_goods_id ON subcontract_material_plan_items (parent_goods_id);
CREATE INDEX idx_subcontract_material_return_items_parent_goods_id ON subcontract_material_return_items (parent_goods_id);
CREATE INDEX idx_subcontract_order_cost_items_parent_goods_id ON subcontract_order_cost_items (parent_goods_id);
