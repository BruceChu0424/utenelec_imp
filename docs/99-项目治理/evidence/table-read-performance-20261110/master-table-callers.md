# 公共表格构造调用清单

AST扫描 lib/**/*.dart，排除注释/类型声明；当前共 235 个构造调用。
全部自动共用公共基础优化。未声明不可变合同不等于不适用；详细审定/未完成项见主回执。

| 调用位置 | 行类型 | 增量声明 |
|---|---|---|
| `lib/components/data_display/uten_cell_revision_table.dart:45` | `MasterDataTableView<UtenCellRevisionRow<T>>` | 保守路径，待所属owner合同核对 |
| `lib/components/data_display/uten_revision_table.dart:193` | `MasterDataTableView<UtenRevisionRow<T>>` | 保守路径，待所属owner合同核对 |
| `lib/components/inputs/uten_employee_selection_panel.dart:761` | `MasterDataTableView<UtenEmployeePickerItem>` | 保守路径，待所属owner合同核对 |
| `lib/components/layout/uten_doc_link_picker_sheet.dart:868` | `MasterDataTableView<D>` | 保守路径，待所属owner合同核对 |
| `lib/components/layout/uten_paged_picker_list.dart:52` | `MasterDataTableView<T>` | 保守路径，待所属owner合同核对 |
| `lib/features/admin/pages/admin_ai_usage_page.dart:448` | `MasterDataTableView<AiUsagePerson>` | 保守路径，待所属owner合同核对 |
| `lib/features/admin/pages/admin_ai_usage_records_page.dart:610` | `MasterDataTableView<AiUsageAuditRecord>` | 保守路径，待所属owner合同核对 |
| `lib/features/admin/pages/admin_ai_usage_records_page.dart:766` | `MasterDataTableView<AiUsageAuditUser>` | 保守路径，待所属owner合同核对 |
| `lib/features/admin/pages/audit_overview_widgets.dart:1062` | `MasterDataTableView<AuditLogEntry>` | 保守路径，待所属owner合同核对 |
| `lib/features/admin/pages/audit_overview_widgets.dart:1308` | `MasterDataTableView<AuditSessionSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/admin/pages/server_status_page.dart:898` | `MasterDataTableView<ServerJob>` | 保守路径，待所属owner合同核对 |
| `lib/features/admin/widgets/page_permission_drawer.dart:1181` | `MasterDataTableView<PagePermissionStaffSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/applications/pages/business_application_list_page.dart:528` | `MasterDataTableView<BusinessApplication>` | 保守路径，待所属owner合同核对 |
| `lib/features/approvals/pages/approval_policy_settings_page.dart:129` | `MasterDataTableView<ApprovalDepartmentPolicy>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/pages/account_detail_page.dart:1128` | `MasterDataTableView<AccountStatementRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/pages/account_workspace_page.dart:1579` | `MasterDataTableView<AccountListItem>` | 显式条件启用 |
| `lib/features/basic_data/pages/color_page.dart:992` | `MasterDataTableView<ColorListItem>` | 显式条件启用 |
| `lib/features/basic_data/pages/currency_page.dart:1074` | `MasterDataTableView<CurrencyListItem>` | 显式条件启用 |
| `lib/features/basic_data/pages/goods_import_preview_page.dart:1120` | `MasterDataTableView<GoodsImportProblemRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/pages/goods_price_analysis_page.dart:1440` | `MasterDataTableView<PriceObservation>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/pages/import_review_page.dart:395` | `MasterDataTableView<ImportReviewRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/pages/payment_style_page.dart:1223` | `MasterDataTableView<_PaymentStyleWorkspaceRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/pages/settlement_method_page.dart:802` | `MasterDataTableView<SettlementMethodAdminItem>` | 显式条件启用 |
| `lib/features/basic_data/pages/unit_page.dart:956` | `MasterDataTableView<UnitListItem>` | 显式条件启用 |
| `lib/features/basic_data/pages/warehouse_page.dart:1501` | `MasterDataTableView<WarehouseDetail>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_bom_comparison_table.dart:904` | `MasterDataTableView<_ComparisonTableRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_bom_learning_panel.dart:333` | `MasterDataTableView<GoodsBomLearningComponent>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_bom_material_evidence.dart:52` | `MasterDataTableView<GoodsBomMaterialEvidence>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_bom_tab.dart:3997` | `MasterDataTableView<_BomRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_actual_panel.dart:327` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_actual_panel.dart:458` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_actual_panel.dart:800` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_editor.dart:1178` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_editor.dart:2066` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_editor.dart:2236` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_import_dialog.dart:152` | `MasterDataTableView<_CostImportRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_production_evidence.dart:196` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_tab.dart:1416` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_cost_tab.dart:1627` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_price_facet_picker.dart:318` | `MasterDataTableView<MasterFacetBucket>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_price_observation_detail.dart:239` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_quote_history_tab.dart:331` | `MasterDataTableView<GoodsQuoteHistoryRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_subcontract_supplier_table.dart:105` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/goods_subcontract_supplier_table.dart:389` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/master_entity_detail_pane.dart:1966` | `MasterDataTableView<TItem>` | 显式条件启用 |
| `lib/features/basic_data/widgets/mould_picker_field.dart:654` | `MasterDataTableView<MouldListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/uten_goods_picker.dart:1835` | `MasterDataTableView<GoodsListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/uten_master_picker.dart:766` | `MasterDataTableView<TItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/basic_data/widgets/warehouse_inventory_panel.dart:512` | `MasterDataTableView<InstantInventoryRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/department/widgets/department_overview_pane.dart:570` | `MasterDataTableView<EmployeeSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/department/widgets/uten_position_entry_picker.dart:383` | `MasterDataTableView<Position>` | 保守路径，待所属owner合同核对 |
| `lib/features/department/widgets/uten_position_picker.dart:241` | `MasterDataTableView<Position>` | 保守路径，待所属owner合同核对 |
| `lib/features/employee/pages/employee_list_page.dart:323` | `MasterDataTableView<EmployeeSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/employee/widgets/department_employee_picker.dart:727` | `MasterDataTableView<UtenEmployeePickerItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/expense/pages/expense_approval_detail_page.dart:610` | `MasterDataTableView<ExpenseItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/expense/pages/expense_approval_list_page.dart:441` | `MasterDataTableView<ExpenseClaim>` | 保守路径，待所属owner合同核对 |
| `lib/features/expense/pages/expense_detail_page.dart:609` | `MasterDataTableView<ExpenseItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/expense/pages/expense_list_page.dart:264` | `MasterDataTableView<ExpenseClaim>` | 保守路径，待所属owner合同核对 |
| `lib/features/expense/widgets/expense_invoice_section.dart:151` | `MasterDataTableView<ExpenseClaimInvoice>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_account_flow_page.dart:553` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_application_settings_page.dart:237` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_applications_page.dart:418` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_applications_page.dart:690` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_ar_ap_overview_page.dart:1104` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_ar_ap_page.dart:726` | `MasterDataTableView<ArApLedgerItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_doc_detail_page.dart:1479` | `MasterDataTableView<FinanceDocItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_doc_list_page.dart:743` | `MasterDataTableView<FinanceDocListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_procurement_approval_tasks_page.dart:934` | `MasterDataTableView<FinanceProcurementApprovalTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_quote_review_list_page.dart:481` | `MasterDataTableView<SalesQuoteFinanceListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_quote_review_page.dart:1394` | `MasterDataTableView<SalesQuoteFinanceLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_reconciliation_page.dart:454` | `MasterDataTableView<ReconciliationItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_report_table_page.dart:1692` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_sales_order_confirmation_page.dart:1052` | `MasterDataTableView<SalesOrderFinancePendingItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_sales_order_review_page.dart:1326` | `MasterDataTableView<SalesOrderFinanceReviewLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_sales_shipment_audit_review_page.dart:1475` | `MasterDataTableView<SalesDocItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/pages/finance_statement_page.dart:658` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/payables/pages/finance_payables_page.dart:1036` | `MasterDataTableView<FinancePayableItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/payables/widgets/subcontract_loss_claim_detail_panel.dart:424` | `MasterDataTableView<SubcontractLossClaimLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/payables/widgets/subcontract_loss_claim_panel.dart:400` | `MasterDataTableView<SubcontractLossClaimSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/payables/widgets/supplier_settlement_panel.dart:437` | `MasterDataTableView<SupplierSettlementSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/payables/widgets/supplier_settlement_panel.dart:752` | `MasterDataTableView<SupplierSettlementLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_account_picker_panel.dart:145` | `MasterDataTableView<FinanceAccountReference>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_accounting_import_dialog.dart:1205` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_actual_receipt_context.dart:136` | `MasterDataTableView<CustomerActualReceipt>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_application_detail.dart:208` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_asset_detail.dart:653` | `MasterDataTableView<FinanceAssetScheduleLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_asset_ledger_panel.dart:571` | `MasterDataTableView<FinanceAssetSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_asset_opening_group_dialog.dart:1106` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_asset_opening_group_dialog.dart:1894` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_asset_posting_panel.dart:747` | `MasterDataTableView<AssetPostingLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_chart_dialog.dart:429` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_chart_import_workbench.dart:870` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_expense_analysis_dialog.dart:523` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_payroll_preparation.dart:1353` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/finance_source_table.dart:26` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/finance/widgets/inventory_cost_posting_dialog.dart:669` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/hr_profile/pages/hr_profile_changes_list_page.dart:441` | `MasterDataTableView<HrProfileChangeListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/hr_task/pages/hr_reconcile_page.dart:1261` | `MasterDataTableView<HrReconcileRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/hr_task/pages/hr_task_list_page.dart:347` | `MasterDataTableView<HrTaskItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/hr_task/widgets/hr_celebration_history_panel.dart:148` | `MasterDataTableView<HrCelebrationPublication>` | 保守路径，待所属owner合同核对 |
| `lib/features/operations_workbench/pages/operations_workbench_page.dart:1581` | `MasterDataTableView<OperationsWorkbenchTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/payroll/pages/payroll_review_page.dart:514` | `MasterDataTableView<PayrollSlip>` | 保守路径，待所属owner合同核对 |
| `lib/features/payroll/pages/payroll_review_page.dart:556` | `MasterDataTableView<PayrollSlip>` | 保守路径，待所属owner合同核对 |
| `lib/features/payroll/pages/payroll_slip_list_page.dart:76` | `MasterDataTableView<PayrollSlip>` | 保守路径，待所属owner合同核对 |
| `lib/features/procurement_iqc_rejection/pages/procurement_iqc_rejection_list_page.dart:587` | `MasterDataTableView<ProcurementIqcRejectionCase>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/delivery_processing/delivery_processing_tasks_button.dart:428` | `MasterDataTableView<DeliveryProcessingTarget>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/delivery_processing/delivery_processing_tasks_button.dart:664` | `MasterDataTableView<DeliveryProcessingTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/material_analysis_bucket_detail.dart:777` | `MasterDataTableView<_BucketRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/material_analysis_candidates.dart:770` | `MasterDataTableView<MaterialAnalysisSalesCandidateLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/material_analysis_child_shortage_page.dart:307` | `MasterDataTableView<_MaterialTableRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/material_analysis_material_table.dart:1510` | `MasterDataTableView<_MaterialTableRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/material_analysis_order_page.dart:188` | `MasterDataTableView<_MaterialTableRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_analysis_sales_order_page.dart:200` | `MasterDataTableView<AnalysisLinkedSalesOrderLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_board_page.dart:1100` | `MasterDataTableView<SchedulePendingRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_chain_health_page.dart:188` | `MasterDataTableView<_ChainHealthRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_daily_report_detail_page.dart:1527` | `MasterDataTableView<ProductionDailyReportDetailGroupRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_daily_report_list_page.dart:413` | `MasterDataTableView<ProductionDailyReportListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_draw_request_page.dart:653` | `MasterDataTableView<ProductionDrawRequestSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_draw_request_page.dart:795` | `MasterDataTableView<ProductionDrawRequestLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_execution_batch_page.dart:804` | `MasterDataTableView<ProductionDrawRequestSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_material_analysis_history_page.dart:385` | `MasterDataTableView<MaterialAnalysisListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_material_analysis_page.dart:2827` | `MasterDataTableView<MaterialAnalysisSourceInput>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_material_discovery_request_page.dart:808` | `MasterDataTableView<DiscoveryRequestMaterialRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_material_increment_create.dart:449` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_material_increment_pages.dart:177` | `MasterDataTableView<ProductionMaterialIncrementRequest>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_over_limit_pages.dart:242` | `MasterDataTableView<ProductionOverLimitDisposition>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_overproduction_rate_pages.dart:211` | `MasterDataTableView<ProductionOverproductionRateRequest>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_plan_list_page.dart:597` | `MasterDataTableView<ProductionPlanListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_report_page.dart:552` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/production_workshop_tasks_page.dart:3082` | `MasterDataTableView<ProductionExecutionWorkbenchSegment>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/where_used_report_page.dart:1531` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/workshop_material_reports_page.dart:770` | `MasterDataTableView<WmBinUsageRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/workshop_material_reports_page.dart:904` | `MasterDataTableView<WmProductUsageRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/workshop_material_reports_page.dart:1153` | `MasterDataTableView<WmMissingWeightRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/pages/workshop_material_reports_page.dart:1243` | `MasterDataTableView<WmLedgerRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/widgets/daily_report_material_review_section.dart:146` | `MasterDataTableView<DailyReportMaterialReviewRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/widgets/plan_order_import_sheet.dart:273` | `MasterDataTableView<ScheduleBomComponent>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/widgets/production_execution_group_panel.dart:239` | `MasterDataTableView<ProductionExecutionWorkbenchGroup>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/widgets/reportable_plan_line_picker.dart:261` | `MasterDataTableView<ReportablePlanLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/production/widgets/workshop_task_material_table.dart:227` | `MasterDataTableView<ProductionWorkshopTaskMaterial>` | 保守路径，待所属owner合同核对 |
| `lib/features/profile/pages/my_profile_changes_page.dart:235` | `MasterDataTableView<MyProfileChangeListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/purchase/pages/purchase_doc_detail_page.dart:1651` | `MasterDataTableView<PurchaseDocItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/purchase/pages/purchase_doc_list_page.dart:978` | `MasterDataTableView<PurchaseDocListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/purchase/pages/purchase_report_table_page.dart:530` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/production_fqc_handling_page.dart:1224` | `MasterDataTableView<FqcReportRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/production_fqc_handling_page.dart:1332` | `MasterDataTableView<_SheetHeaderRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/production_fqc_handling_page.dart:2100` | `MasterDataTableView<_FactRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/production_fqc_handling_page.dart:2239` | `MasterDataTableView<FqcReportRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/production_fqc_inspections_page.dart:427` | `MasterDataTableView<ProductionFqcInspection>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/quality_batch_approval_page.dart:1050` | `MasterDataTableView<_ApprovalRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/quality_inspection_records_page.dart:637` | `MasterDataTableView<QualityInspectionRecord>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/quality_inspection_records_page.dart:1145` | `MasterDataTableView<_DetailQuantityRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/quality_inspection_records_page.dart:1272` | `MasterDataTableView<_DetailField>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/quality_pending_disposal_page.dart:589` | `MasterDataTableView<_DisposalRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/quality_pending_disposal_page.dart:1676` | `MasterDataTableView<_ReceiptHeaderRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/quality/pages/quality_pending_disposal_page.dart:1757` | `MasterDataTableView<ProcurementInspectionItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/rd_task/pages/rd_task_page.dart:996` | `MasterDataTableView<RdTaskRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/sales/pages/sales_doc_detail_page.dart:2419` | `MasterDataTableView<SalesDocItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/sales/pages/sales_doc_list_page.dart:1552` | `MasterDataTableView<SalesDocListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/sales/pages/sales_manager_review_page.dart:743` | `MasterDataTableView<SalesManagerReviewTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/sales/pages/sales_order_progress_page.dart:762` | `MasterDataTableView<SalesOrderProgressRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/sales/pages/sales_report_page.dart:574` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/sales/pages/sales_report_page.dart:1069` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/sales/widgets/sales_plan_progress_panel.dart:448` | `MasterDataTableView<OrderPlanProgressLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/sales/widgets/sales_shipment_task_workbench.dart:1007` | `MasterDataTableView<SalesDocListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/security/pages/security_blacklist_page.dart:169` | `MasterDataTableView<VisitorBlacklistItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/stock/counts/pages/stock_count_review_page.dart:818` | `MasterDataTableView<StockCountRequest>` | 保守路径，待所属owner合同核对 |
| `lib/features/stock/counts/pages/stock_count_review_page.dart:1062` | `MasterDataTableView<StockCountRequestLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/stock/counts/pages/stock_count_session_page.dart:1016` | `MasterDataTableView<CountStockRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/stock/counts/widgets/stock_count_batch_approval_dialog.dart:218` | `MasterDataTableView<_CountReviewRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/stock/pages/instant_inventory_page.dart:1186` | `MasterDataTableView<InstantInventoryRow>` | 显式条件启用 |
| `lib/features/stock/widgets/instant_inventory_overview_content.dart:832` | `MasterDataTableView<InventoryUnitSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/pages/subcontract_business_list_pages.dart:1110` | `MasterDataTableView<SubcontractDocListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/pages/subcontract_decomposition_page.dart:2114` | `MasterDataTableView<OperationsWorkbenchTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/pages/subcontract_decomposition_page.dart:2518` | `MasterDataTableView<SubcontractPendingRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/pages/subcontract_doc_detail_page.dart:1155` | `MasterDataTableView<SubcontractDocItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/pages/subcontract_doc_detail_page.dart:1706` | `MasterDataTableView<SubcontractOrderMaterialLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/pages/subcontract_draw_request_page.dart:801` | `MasterDataTableView<SubcontractDrawPreviewLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/pages/subcontract_report_table_page.dart:544` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/pages/subcontract_short_delivery_page.dart:574` | `MasterDataTableView<SubcontractShortDeliveryCase>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/widgets/subcontract_application_kit_dialog.dart:273` | `MasterDataTableView<SubcontractKitMaterial>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/widgets/subcontract_draw_task_detail_dialog.dart:299` | `MasterDataTableView<SubcontractDrawMaterial>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/widgets/subcontract_order_progress.dart:333` | `MasterDataTableView<SubcontractDrawMaterial>` | 保守路径，待所属owner合同核对 |
| `lib/features/subcontract/widgets/subcontract_order_progress.dart:442` | `MasterDataTableView<SubcontractSupplierLedgerLine>` | 保守路径，待所属owner合同核对 |
| `lib/features/suggestion/pages/suggestion_list_page.dart:99` | `MasterDataTableView<Suggestion>` | 保守路径，待所属owner合同核对 |
| `lib/features/visitor/pages/visitor_home_page.dart:215` | `MasterDataTableView<VisitorApplication>` | 保守路径，待所属owner合同核对 |
| `lib/features/visitor_approval/pages/my_visitors_page.dart:309` | `MasterDataTableView<VisitorApplication>` | 保守路径，待所属owner合同核对 |
| `lib/features/visitor_approval/pages/visitor_approval_list_page.dart:472` | `MasterDataTableView<VisitorApplication>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/materialbin/pages/workshop_material_bin_page.dart:1232` | `MasterDataTableView<WmPositionRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/materialbin/pages/workshop_material_bin_page.dart:1418` | `MasterDataTableView<WmRequisition>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/materialbin/widgets/workshop_material_overview.dart:368` | `MasterDataTableView<WmSetting>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/materialbin/widgets/workshop_material_summary_table.dart:36` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/materialbin/widgets/workshop_material_task_center.dart:275` | `MasterDataTableView<_BinStatusRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/materialbin/widgets/workshop_request_material_picker.dart:399` | `MasterDataTableView<WmMaterialOption>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/production_finished_batch_stock_in_page.dart:514` | `MasterDataTableView<ProductionFinishedInboundTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/production_material_discovery_page.dart:636` | `MasterDataTableView<DiscoveryMaterialRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/shelf_label_page.dart:553` | `MasterDataTableView<ShelfLabelRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/stock_doc_detail_page.dart:1624` | `MasterDataTableView<StockDocItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/stock_doc_list_page.dart:693` | `MasterDataTableView<StockDocListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_document_history_detail_page.dart:191` | `MasterDataTableView<WarehouseDocumentPhysicalItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_insight_page.dart:1107` | `MasterDataTableView<InsightHealthRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_insight_page.dart:1174` | `MasterDataTableView<InsightCycleCountRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_insight_page.dart:1227` | `MasterDataTableView<InsightWeightAlertRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_insight_page.dart:1267` | `MasterDataTableView<InsightCounterpartSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_insight_page.dart:1297` | `MasterDataTableView<InsightLearningRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_quality_results_page.dart:734` | `MasterDataTableView<WarehouseQualityResultTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_report_table_page.dart:559` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_sales_outbound_batch_page.dart:958` | `MasterDataTableView<WarehouseSalesOutboundTableRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart:523` | `MasterDataTableView<WarehouseSalesOutboundTableRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/production_draw_detail_table.dart:317` | `MasterDataTableView<ProductionDrawDetailRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/production_finished_inbound_tasks_view.dart:595` | `MasterDataTableView<ProductionFinishedInboundTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_arrival_exceptions_view.dart:607` | `MasterDataTableView<ProcurementArrivalException>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_delivery_components_table.dart:56` | `MasterDataTableView<({WarehouseSalesOutboundDetail detail, WarehouseDeliveryComponent component})>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_document_history_view.dart:372` | `MasterDataTableView<WarehouseDocumentHistorySummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_draw_task_segment.dart:635` | `MasterDataTableView<WarehouseDrawTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_inbound_expectations_view.dart:831` | `MasterDataTableView<InboundExpectation>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_sales_outbound_workbench.dart:549` | `MasterDataTableView<WarehouseSalesOutboundSummary>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_stock_doc_segment.dart:794` | `MasterDataTableView<StockDocListItem>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_stock_outbound_detail_table.dart:48` | `MasterDataTableView<WarehouseStockOutboundRow>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_subcontract_outbound_workbench.dart:340` | `MasterDataTableView<OutboundTask>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_task_physical_detail_dialog.dart:492` | `MasterDataTableView<Map<String, dynamic>>` | 保守路径，待所属owner合同核对 |
| `lib/features/warehouse/widgets/warehouse_task_records_view.dart:1311` | `MasterDataTableView<WarehouseTaskCenterRecord>` | 保守路径，待所属owner合同核对 |
| `lib/shared/delivery/order_delivery_window.dart:452` | `MasterDataTableView<_DeliveryRow>` | 保守路径，待所属owner合同核对 |
| `lib/shared/drafts/draft_workspace_table.dart:660` | `MasterDataTableView<DraftWorkspaceRow>` | 保守路径，待所属owner合同核对 |
| `lib/shared/drafts/form_draft_category_table.dart:408` | `MasterDataTableView<FormDraftCategoryRow<T>>` | 保守路径，待所属owner合同核对 |
| `lib/shared/drafts/form_draft_category_table.dart:1002` | `MasterDataTableView<Object>` | 保守路径，待所属owner合同核对 |
| `lib/shared/history/record_history_page.dart:644` | `MasterDataTableView<MasterRecordRevision>` | 保守路径，待所属owner合同核对 |
| `lib/shared/stock_ledger/widgets/goods_production_trace_view.dart:384` | `MasterDataTableView<GoodsProductionTraceRow>` | 保守路径，待所属owner合同核对 |
| `lib/shared/stock_ledger/widgets/goods_stock_balance_view.dart:277` | `MasterDataTableView<BalanceRow>` | 保守路径，待所属owner合同核对 |
| `lib/shared/stock_ledger/widgets/goods_stock_ledger_view.dart:388` | `MasterDataTableView<StockLedgerRow>` | 保守路径，待所属owner合同核对 |
| `lib/shared/stock_ledger/widgets/goods_weight_learning_view.dart:585` | `MasterDataTableView<WeightObservation>` | 保守路径，待所属owner合同核对 |
| `lib/shared/stock_ledger/widgets/goods_weight_learning_view.dart:831` | `MasterDataTableView<GoodsWeightEstimateRow>` | 保守路径，待所属owner合同核对 |
| `lib/shared/stock_ledger/widgets/material_trace_subject_picker.dart:248` | `MasterDataTableView<MaterialTraceSubject>` | 保守路径，待所属owner合同核对 |
| `lib/shared/widgets/sales_order_picker.dart:377` | `MasterDataTableView<SalesDocListItem>` | 保守路径，待所属owner合同核对 |
| `lib/shared/widgets/warehouse_picker_panel.dart:508` | `MasterDataTableView<WarehouseDictEntry>` | 保守路径，待所属owner合同核对 |
