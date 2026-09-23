package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 行级审计三清单契约(ADR-105, V646 起)。
 *
 * <p>每张 public 业务表必须且只能归入一类, 每条带理由:
 * <ul>
 *   <li>FULL: 整行审计(INSERT/DELETE 存整行, UPDATE 只存变化键), 人工维护的主档、权限、单据;</li>
 *   <li>COLUMN_SCOPED: 只审计人为决定的列, 派生列变化不留行审计;</li>
 *   <li>NONE: 不挂行级审计(派生投影、队列、编号预留、只追加流水、遗留只读数据、技术表)。</li>
 * </ul>
 * 废除 V169 起「除技术白名单外全表必审、审计触发器不许带 WHEN/列清单」的规则。V646 按本清单
 * 挂/拆触发器; 之后新建的表必须在这里登记, 属于 FULL/COLUMN_SCOPED 的由建表迁移调用
 * {@code fn_audit_track_table} 挂审计, 不许手写 CREATE TRIGGER trg_audit_*。
 * 真库上的触发器形态由 {@link AuditTriggerCoveragePostgresTest} 按同一清单核对。
 */
class AuditTriggerCoverageMigrationContractTest {

    static final Path MIGRATION_ROOT = Path.of("src/main/resources/db/migration");
    static final int POLICY_BASELINE_VERSION = 646;
    static final Path POLICY_BASELINE =
            MIGRATION_ROOT.resolve("V646__audit_three_list_policy_change_only_rows.sql");
    private static final Pattern MIGRATION_FILE = Pattern.compile("^V(\\d+)__.+\\.sql$");
    private static final String IDENT =
            "(?:\"?public\"?\\s*\\.\\s*)?\"?([a-z_][a-z0-9_]*)\"?";
    static final Pattern CREATE_TABLE = Pattern.compile(
            "(?i)\\bCREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(?!IF\\s)" + IDENT
                    + "(?![A-Za-z0-9_'%|$])(\\s+PARTITION\\s+OF)?");
    private static final Pattern DROP_TABLE = Pattern.compile(
            "(?i)\\bDROP\\s+TABLE\\s+(?:IF\\s+EXISTS\\s+)?((?:(?:\"?public\"?\\s*\\.\\s*)?\"?[a-z_][a-z0-9_]*\"?"
                    + "\\s*,\\s*)*(?:\"?public\"?\\s*\\.\\s*)?\"?[a-z_][a-z0-9_]*\"?)");
    private static final Pattern RENAME_TABLE = Pattern.compile(
            "(?i)\\bALTER\\s+TABLE\\s+(?:IF\\s+EXISTS\\s+)?(?:ONLY\\s+)?" + IDENT
                    + "\\s+RENAME\\s+TO\\s+\"?([a-z_][a-z0-9_]*)\"?");
    private static final Pattern FULL_CALL = Pattern.compile(
            "(?s)fn_audit_track_table\\(t, 'FULL', '([a-z_]+)', (true|false)\\)\\s+FROM unnest\\(ARRAY\\[(.*?)]\\) AS t;");
    private static final Pattern SCOPED_CALL = Pattern.compile(
            "(?s)fn_audit_track_table\\('([a-z_]+)', 'COLUMN_SCOPED', '([a-z_]+)', (true|false),\\s*"
                    + "ARRAY\\[(.*?)], (true|false)\\);");
    private static final Pattern REGISTRATION = Pattern.compile(
            "fn_audit_track_table\\(\\s*'([a-z_][a-z0-9_]*)'\\s*,\\s*'(FULL|COLUMN_SCOPED|NONE)'");
    private static final Pattern QUOTED = Pattern.compile("'([a-z_][a-z0-9_]*)'");
    /** Flyway 自己建的表, 不在迁移脚本里。 */
    private static final Set<String> CREATED_OUTSIDE_MIGRATIONS = Set.of("flyway_schema_history");
    private static final Set<String> CATEGORIES = Set.of("data_change", "authorization", "system");

    record FullGroup(String key, String category, boolean redacted, String reason, Set<String> tables) {
    }

    record ScopedTable(String table, String category, boolean insertDelete, List<String> columns,
                       String reason) {
    }

    record NoneGroup(String key, String reason, Set<String> tables) {
    }

    /** FULL: 整行审计(INSERT/DELETE 存整行, UPDATE 只存变化键)。分组即理由, 分组内每张表同一理由。 */
    static final List<FullGroup> FULL = List.of(
            new FullGroup("authorization", "authorization", false,
                    "账号、权限点、授权覆盖与数据范围: 谁能做什么的唯一事实, 每次变化都要能还原前后值(角色四表已随 V655 删除)",
                    Set.of(
                        "client_visibility_grants", "department_permissions",
                        "manager_permission_delegations",
                        "organization_permission_leader_assignments",
                        "permission_surface_permissions", "permission_surfaces", "permissions",
                        "user_data_scopes", "user_permission_overrides", "users")),
            new FullGroup("system", "system", false,
                    "系统设置与全局配置: 改动影响全平台运行口径",
                    Set.of(
                        "business_identifier_namespaces", "expense_claim_settings",
                        "measurement_capture_profiles", "system_master_category_registry",
                        "system_posting_style_roles", "system_settings",
                        "unit_measurement_profiles")),
            new FullGroup("master", "data_change", false,
                    "基础资料主档: 人工维护, 被所有单据引用",
                    Set.of(
                        "accounts", "client_categories", "client_ship_addresses", "clients",
                        "colors", "currencies", "finance_payment_methods", "goods",
                        "goods_bom_items", "goods_import_batches", "goods_import_creations",
                        "master_code_change_batches", "material_categories", "mould_categories",
                        "moulds", "official_policy_briefs", "party_activity_records",
                        "party_addresses", "party_contact_methods", "payment_styles",
                        "settlement_methods", "supplier_categories", "suppliers", "units",
                        "warehouses")),
            new FullGroup("org_hr", "data_change", false,
                    "组织、人事与访客资料: 人工维护的敏感资料, 由脱敏函数去掉证件/联系方式/自由文本后整行审计",
                    Set.of(
                        "attachments", "departments", "emergency_contacts",
                        "employee_compensation", "employee_contracts", "employee_credentials",
                        "employee_data_handover_scopes", "employee_data_handovers",
                        "employee_education", "employee_phones", "employee_secondary_departments",
                        "employee_sensitive", "employee_vehicles", "employees",
                        "employment_history", "positions", "profile_change_requests",
                        "rd_task_forwarders", "rd_tasks", "suggestion_replies", "suggestions",
                        "visitor_accounts", "visitor_applications", "visitor_approval_steps",
                        "website_inquiries")),
            new FullGroup("payroll", "data_change", true,
                    "工资与报销: 额外去掉金额与姓名快照后整行审计",
                    Set.of(
                        "expense_claim_items", "expense_claims", "payroll_batches",
                        "payroll_items", "payroll_slips", "payroll_variable_inputs")),
            new FullGroup("sales_docs", "data_change", false,
                    "销售单据头与明细: 人工录入并审核的业务单据",
                    Set.of(
                        "sales_order_cost_items", "sales_order_items", "sales_orders",
                        "sales_other_shipment_items", "sales_other_shipments", "sales_quote_items",
                        "sales_quotes", "sales_return_items", "sales_return_quality_items",
                        "sales_returns", "sales_shipment_items", "sales_shipments")),
            new FullGroup("purchase_docs", "data_change", false,
                    "采购单据、财务审批案与供应商结算: 人工录入并审核的业务单据",
                    Set.of(
                        "procurement_arrival_exceptions", "procurement_iqc_rejection_cases",
                        "procurement_order_approval_cases", "purchase_order_items",
                        "purchase_orders", "purchase_receipt_items", "purchase_receipts",
                        "purchase_request_items", "purchase_requests", "purchase_return_items",
                        "purchase_returns", "supplier_claim_cash_receipts",
                        "supplier_claim_receivables", "supplier_open_item_offsets",
                        "supplier_return_tasks", "supplier_settlement_batch_lines",
                        "supplier_settlement_batches")),
            new FullGroup("subcontract_docs", "data_change", false,
                    "委外单据头与明细: 人工录入并审核的业务单据",
                    Set.of(
                        "subcontract_application_items", "subcontract_applications",
                        "subcontract_inquiries", "subcontract_inquiry_items",
                        "subcontract_loss_case_lines", "subcontract_loss_cases",
                        "subcontract_loss_resolutions", "subcontract_material_issue_items",
                        "subcontract_material_issues", "subcontract_material_plan_items",
                        "subcontract_material_plans", "subcontract_material_return_items",
                        "subcontract_material_returns", "subcontract_order_cost_items",
                        "subcontract_order_items", "subcontract_orders",
                        "subcontract_receipt_items", "subcontract_receipts",
                        "subcontract_return_items", "subcontract_returns",
                        "subcontract_short_delivery_cases", "subcontract_waste_items",
                        "subcontract_wastes")),
            new FullGroup("stock_docs", "data_change", false,
                    "库存单据、预留与调整申请: 人工录入并审核的业务单据",
                    Set.of(
                        "stock_balance_adjustment_requests", "stock_document_items",
                        "stock_documents", "stock_reservations")),
            new FullGroup("production_docs", "data_change", false,
                    "生产计划、日报、执行段、退料、点收、质检与直送单据: 人工录入并审核的业务单据",
                    Set.of(
                        "production_daily_report_items", "production_daily_report_material_usages",
                        "production_daily_report_workers", "production_daily_reports",
                        "production_execution_segments",
                        "production_finished_arrival_registration_items",
                        "production_finished_arrival_registrations",
                        "production_finished_in_confirmation_items",
                        "production_finished_in_confirmations",
                        "production_fqc_inspection_sheet_items",
                        "production_fqc_inspection_sheets", "production_fqc_inspections",
                        "production_material_analysis_borrows",
                        "production_material_return_request_items",
                        "production_material_return_requests", "production_plan_items",
                        "production_plans", "production_workshop_direct_transfer_items",
                        "production_workshop_direct_transfers")),
            new FullGroup("finance_docs", "data_change", false,
                    "财务单据、凭证、往来台账与资产: 人工录入并审核的财务事实",
                    Set.of(
                        "ar_ap_ledger", "customer_open_item_offset_batches", "finance_report_line_bindings",
                        "customer_open_item_offsets", "deferred_expenses",
                        "expense_claim_invoices", "finance_asset_accounting_periods",
                        "finance_asset_books", "finance_asset_categories",
                        "finance_asset_posting_lines", "finance_asset_posting_runs",
                        "finance_bank_transfer_lines", "finance_bank_transfers",
                        "finance_check_register", "finance_deferral_schedule_lines",
                        "finance_deferral_schedule_versions", "finance_expense_items",
                        "finance_expenses", "finance_other_income_items", "finance_other_incomes",
                        "finance_payment_lines", "finance_payments", "finance_receipt_lines",
                        "finance_receipt_source_allocations", "finance_receipts",
                        "finance_reconciliations", "fixed_assets", "gl_entries", "gl_vouchers")));

    /** COLUMN_SCOPED: 只审计人为决定的列; 派生列的变化不留行审计。 */
    static final List<ScopedTable> COLUMN_SCOPED = List.of(
            new ScopedTable("production_material_analyses", "data_change", true,
                    List.of("status", "cancelled_by", "cancelled_at", "cancellation_reason", "is_deleted", "deleted_at", "warehouse_id", "participating_warehouse_ids", "maker_id"),
                    "物料分析表头: 只记新建/删除与状态、取消、仓库、制单人这些人为决定, 版本号和指纹每次刷新都会变, 不记"),
            new ScopedTable("production_material_analysis_materials", "data_change", false,
                    List.of("confirmed_route", "route_reason", "route_confirmed_by"),
                    "物料分析物料行是每次刷新重算的投影: 只记人工确认路线与理由, 需求/可用/缺口等派生数量不记"),
            new ScopedTable("production_material_analysis_items", "data_change", false,
                    List.of("requested_qty", "delivery_date", "line_priority", "source_reason", "is_deleted"),
                    "物料分析来源行: 只记人工改的需求数量、交期、优先级、原因和删除, 就绪量等派生数量不记"),
            new ScopedTable("preplan_material_reallocations", "data_change", false,
                    List.of("status", "closed_by", "closed_at", "close_reason"),
                    "物料改挪记录: 新建时行内已带发起人与原因, 之后会被人工撤回/取消、随优先履约推进状态: "
                            + "只记状态与关闭人、关闭时间、关闭原因"));

    /** NONE: 不挂行级审计。分组即理由。 */
    static final List<NoneGroup> NONE = List.of(
            new NoneGroup("technical",
                    "技术元数据、计数器、凭证与迁移控制: 不是业务数据, 或含凭证不应被复制",
                    Set.of(
                        "audit_log", "audit_log_archive", "authorization_state",
                        "business_document_sequences", "category_master_code_sequences",
                        "doc_number_sequences", "flyway_schema_history",
                        "legacy_migration_checkpoints", "legacy_migration_reconciliation_items",
                        "legacy_migration_rejects", "legacy_migration_run_files",
                        "legacy_migration_runs", "master_code_sequences", "password_history",
                        "production_product_no_sequences", "refresh_tokens",
                        "report_materialized_view_refresh_state", "visitor_refresh_tokens",
                        "visitor_sms_codes")),
            new NoneGroup("notice",
                    "通知投递与互动机制: 人工发布、确认、祝福已有显式业务事件",
                    Set.of(
                        "notice_acknowledgments", "notice_blessings",
                        "notice_celebration_subjects", "notice_user_states", "notices",
                        "suggestion_likes")),
            new NoneGroup("queue",
                    "队列、任务、认领、幂等命令与系统核对结果: 系统协调状态, 人的操作由请求级语义事件记录",
                    Set.of(
                        "attachment_object_outbox", "attachment_reconciliation_findings",
                        "attachment_upload_sessions", "business_outbox", "hr_task_claims",
                        "procurement_iqc_rejection_commands", "production_daily_report_commands",
                        "production_fqc_release_commands", "production_material_analysis_commands",
                        "production_planning_drafts", "stock_value_jobs",
                        "stock_value_production_cost_dirty", "stock_value_production_cost_tasks",
                        "stock_value_tasks", "subcontract_outbound_preparation_commands",
                        "task_claims", "warehouse_arrival_registration_commands")),
            new NoneGroup("reservation",
                    "编号终身预留、冲突证据与改号历史: 只追加, 行本身就是占用/改号记录",
                    Set.of(
                        "business_identifier_conflicts", "business_identifier_reservation_members",
                        "business_identifier_reservations", "business_prefix_reservation_members",
                        "business_prefix_reservations", "master_code_history",
                        "master_code_reservation_members", "master_code_reservations")),
            new NoneGroup("preference",
                    "使用偏好与自动学习: 系统按使用习惯自动写入, 不是业务决定",
                    Set.of(
                        "user_preferences", "warehouse_goods_place_preferences")),
            new NoneGroup("derived",
                    "派生投影与计算结果: 可由单据和流水重算, 每次重算整行复制只是噪声",
                    Set.of(
                        "account_flow_monthly_summaries", "da_amortization_log",
                        "execution_segment_sales_allocations", "fa_depreciation_log",
                        "inbound_expectation_items", "inbound_expectations", "mrp_generations",
                        "preplan_analysis_stock_exact_pegs", "preplan_future_supply_transfers",
                        "preplan_make_entitlement_delegations",
                        "preplan_reallocation_make_supplements",
                        "preplan_subcontract_make_task_batches", "preplan_subcontract_make_tasks",
                        "preplan_subcontract_requirement_handoff_items",
                        "preplan_subcontract_requirement_handoffs",
                        "preplan_subcontract_requirement_supply_claims",
                        "preplan_supply_action_allocations", "preplan_supply_actions",
                        "procurement_inspection_items", "procurement_iqc_replacement_allocations",
                        "production_fqc_release_allocations",
                        "production_fqc_replenishment_attempts",
                        "production_fqc_replenishment_cycles",
                        "production_fqc_replenishment_supply_gaps",
                        "production_fqc_replenishment_tasks", "production_material_demands",
                        "production_material_make_receipt_allocations",
                        "production_material_peg_transfers",
                        "production_material_receipt_allocations",
                        "production_material_subcontract_peg_transfers",
                        "production_material_subcontract_receipt_allocations",
                        "production_material_supply_pegs",
                        "production_workshop_direct_source_allocations", "stock_balances",
                        "stock_value_edges", "stock_value_node_revisions", "stock_value_nodes",
                        "stock_value_pools", "stock_value_production_cost_objects",
                        "stock_value_production_cost_outputs",
                        "stock_value_production_cost_shares",
                        "subcontract_loss_fulfillment_allocations",
                        "subcontract_outbound_issue_reservation_allocations",
                        "subcontract_receipt_material_consumptions")),
            new NoneGroup("link",
                    "单据关联与下达包: 由下单/下达命令生成的链接, 命令本身已有语义事件",
                    Set.of(
                        "plan_draw_links", "plan_order_item_links",
                        "production_fqc_replenishment_analysis_links",
                        "production_fqc_replenishment_draw_links",
                        "production_material_analysis_plan_links",
                        "production_material_movement_links",
                        "production_planning_package_document_items",
                        "production_planning_package_documents", "production_planning_packages",
                        "purchase_order_item_sources", "subcontract_order_item_sources",
                        "subplan_links")),
            new NoneGroup("ledger",
                    "只追加的事件/流水/批次账: 行内带操作人与时间(子行经父行追溯), 行本身就是留痕",
                    Set.of(
                        "account_balance_adjustment_batches", "account_balance_adjustment_items",
                        "ar_ap_source_refs", "client_access_change_events",
                        "employee_offboarding_events", "expense_claim_events",
                        "finance_asset_approval_steps", "finance_asset_events",
                        "measurement_capture_decision_events", "measurement_capture_evidence",
                        "measurement_capture_line_snapshots",
                        "preplan_future_supply_transfer_cancellations",
                        "preplan_public_supply_events",
                        "preplan_root_output_events", "preplan_stock_entitlement_events",
                        "preplan_subcontract_entitlement_handoff_slices",
                        "preplan_subcontract_make_batch_reversals",
                        "preplan_subcontract_requirement_handoff_events",
                        "procurement_arrival_exception_events", "procurement_inspection_events",
                        "procurement_iqc_consideration_reversals",
                        "procurement_iqc_consideration_review_approvals",
                        "procurement_iqc_credit_case_allocations",
                        "procurement_iqc_credit_documents", "procurement_iqc_credit_slices",
                        "procurement_iqc_funding_settlements", "procurement_iqc_funding_slices",
                        "procurement_iqc_quality_consideration_parts",
                        "procurement_iqc_rejection_events",
                        "procurement_iqc_stock_consideration_parts",
                        "procurement_iqc_stock_in_batch_items", "procurement_iqc_stock_in_batches",
                        "procurement_order_approval_events", "procurement_order_qty_change_logs",
                        "procurement_order_source_revision_allocations",
                        "procurement_order_source_revision_peg_changes",
                        "procurement_order_source_revisions",
                        "procurement_receipt_consideration_parts",
                        "production_daily_report_material_release_events",
                        "production_daily_report_target_events",
                        "production_execution_segment_events",
                        "production_execution_segment_splits",
                        "production_finished_arrival_registration_reversals",
                        "production_finished_in_confirm_batch_items",
                        "production_finished_in_confirm_batches",
                        "production_finished_in_confirmation_reversal_items",
                        "production_finished_in_confirmation_reversals",
                        "production_fqc_cancellation_events",
                        "production_fqc_contribution_adjustments",
                        "production_fqc_decision_events", "production_fqc_pass_all_batch_items",
                        "production_fqc_pass_all_batches",
                        "production_fqc_recovery_allocation_events",
                        "production_fqc_recovery_authorizations",
                        "production_fqc_recovery_cancellation_events",
                        "production_fqc_replenishment_cycle_cancellations",
                        "production_fqc_replenishment_ready_events",
                        "production_fqc_replenishment_ready_reversals",
                        "production_material_return_receiving_confirmations",
                        "production_material_return_request_cancellations",
                        "production_material_settlement_events",
                        "production_material_settlement_postings",
                        "production_material_stock_events", "production_material_stock_postings",
                        "production_workshop_custody_handoff_reversals",
                        "production_workshop_custody_reverse_preparations",
                        "production_workshop_direct_source_events",
                        "production_workshop_direct_transfer_reversals",
                        "production_workshop_material_custody_handoffs",
                        "production_workshop_material_custody_moves",
                        "production_workshop_material_custody_preparations",
                        "production_workshop_material_custody_reversals",
                        "production_workshop_material_return_slices",
                        "production_workshop_return_preplan_events", "sales_order_qty_change_logs",
                        "sales_order_revision_logs", "sales_return_disposition_events",
                        "sales_return_quality_events", "sales_shipment_finance_release_events",
                        "sales_shipment_submission_events", "sales_shipment_warehouse_events",
                        "stock_movements", "stock_value_acquisition_sources", "stock_value_events",
                        "stock_value_legacy_balance_case_events", "stock_value_openings",
                        "stock_value_position_transfers", "stock_value_postings",
                        "stock_value_production_cost_inputs",
                        "stock_value_production_cost_revisions", "subcontract_loss_events",
                        "subcontract_short_delivery_case_events",
                        "supplier_settlement_batch_events",
                        "warehouse_arrival_exception_stock_in_batch_items",
                        "warehouse_arrival_exception_stock_in_batches")),
            new NoneGroup("legacy",
                    "老系统导入的只读数据与迁移核对证据: 由导入对账脚本核对, 不经在线写路径",
                    Set.of(
                        "client_default_settlement_migration_issues", "legacy_departments",
                        "legacy_finance_import_sources", "legacy_measurement_exceptions",
                        "legacy_measurement_profile_snapshots",
                        "legacy_measurement_source_registry",
                        "legacy_procurement_receipt_import_sources",
                        "legacy_subcontract_order_import_sources",
                        "legacy_warehouse_workshop_links", "production_fqc_legacy_exemptions",
                        "production_plan_costs", "production_workshop_direct_legacy_anomalies",
                        "stock_value_legacy_balance_cases")));

    /**
     * 「ledger」组只收只追加的表: 应用代码与 V646 之后的迁移里不许出现对它们的 UPDATE, 下面逐条写明的
     * 一次性完成回填除外(带状态/空值守卫, 只发生一次, 人的决定在插入行里)。会被人工改状态的表不能放进
     * ledger, 应归 COLUMN_SCOPED 或 FULL(例如物料改挪记录)。
     */
    static final Map<String, String> LEDGER_WRITE_ONCE_STAMPS = Map.of(
            "employee_offboarding_events",
            "离职交接执行结束时 EXECUTING -> COMPLETED 回填一次结果摘要; 发起交接的人和原因在插入行里",
            "production_material_settlement_events",
            "日报审核时回填一次所属日报(仅 daily_report_id 为空时); 结算事件本身不变",
            "warehouse_arrival_exception_stock_in_batches",
            "同一条到货异常入库命令内 PENDING -> COMPLETED 回填一次结果; 发起人与请求在插入行里");
    private static final Pattern UPDATE_TARGET = Pattern.compile(
            "(?i)\\bUPDATE\\s+(?:ONLY\\s+)?(?:\"?public\"?\\s*\\.\\s*)?\"?([a-z_][a-z0-9_]*)\"?");

    static Map<String, String> fullTables() {
        Map<String, String> result = new LinkedHashMap<>();
        FULL.forEach(group -> group.tables().forEach(table -> result.put(table, group.category())));
        return result;
    }

    static Set<String> redactedFullTables() {
        return FULL.stream().filter(FullGroup::redacted)
                .flatMap(group -> group.tables().stream()).collect(Collectors.toSet());
    }

    static Map<String, ScopedTable> scopedTables() {
        Map<String, ScopedTable> result = new LinkedHashMap<>();
        COLUMN_SCOPED.forEach(scoped -> result.put(scoped.table(), scoped));
        return result;
    }

    static Set<String> noneTables() {
        return NONE.stream().flatMap(group -> group.tables().stream()).collect(Collectors.toSet());
    }

    @Test
    void everyListedEntryHasAReasonAndBelongsToExactlyOneList() {
        Map<String, List<String>> owners = new HashMap<>();
        FULL.forEach(group -> {
            assertFalse(group.reason().isBlank(), group.key() + " needs a reviewable reason");
            assertTrue(CATEGORIES.contains(group.category()), group.key() + " category");
            group.tables().forEach(table ->
                    owners.computeIfAbsent(table, ignored -> new ArrayList<>()).add("FULL/" + group.key()));
        });
        COLUMN_SCOPED.forEach(scoped -> {
            assertFalse(scoped.reason().isBlank(), scoped.table() + " needs a reviewable reason");
            assertFalse(scoped.columns().isEmpty(), scoped.table() + " must name its audited columns");
            assertTrue(CATEGORIES.contains(scoped.category()), scoped.table() + " category");
            owners.computeIfAbsent(scoped.table(), ignored -> new ArrayList<>()).add("COLUMN_SCOPED");
        });
        NONE.forEach(group -> {
            assertFalse(group.reason().isBlank(), group.key() + " needs a reviewable reason");
            group.tables().forEach(table ->
                    owners.computeIfAbsent(table, ignored -> new ArrayList<>()).add("NONE/" + group.key()));
        });
        List<String> duplicated = owners.entrySet().stream()
                .filter(entry -> entry.getValue().size() > 1)
                .map(entry -> entry.getKey() + "=" + entry.getValue())
                .sorted().toList();
        assertEquals(List.of(), duplicated, "A table belongs to exactly one audit list");
        assertTrue(noneTables().containsAll(Set.of("audit_log", "audit_log_archive")),
                "The audit sink never audits itself");
    }

    @Test
    void ledgerTablesAreAppendOnlyExceptTheDeclaredWriteOnceStamps() throws IOException {
        Set<String> ledger = NONE.stream().filter(group -> group.key().equals("ledger"))
                .findFirst().orElseThrow().tables();
        assertTrue(ledger.containsAll(LEDGER_WRITE_ONCE_STAMPS.keySet()),
                "write-once stamps are an exception inside the ledger group only");
        Map<String, Set<String>> updates = new java.util.TreeMap<>();
        try (Stream<Path> files = Files.walk(Path.of("src/main/java"))) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).toList()) {
                Matcher update = UPDATE_TARGET.matcher(Files.readString(file, StandardCharsets.UTF_8));
                while (update.find()) {
                    String table = update.group(1).toLowerCase(Locale.ROOT);
                    if (ledger.contains(table)) {
                        updates.computeIfAbsent(table, ignored -> new TreeSet<>()).add(file.getFileName().toString());
                    }
                }
            }
        }
        for (MigrationSource migration : migrations()) {
            if (migration.version() <= POLICY_BASELINE_VERSION) {
                continue;
            }
            Matcher update = UPDATE_TARGET.matcher(stripSqlComments(migration.sql()));
            while (update.find()) {
                String table = update.group(1).toLowerCase(Locale.ROOT);
                if (ledger.contains(table)) {
                    updates.computeIfAbsent(table, ignored -> new TreeSet<>())
                            .add(migration.path().getFileName().toString());
                }
            }
        }
        Set<String> staleStamps = new TreeSet<>(LEDGER_WRITE_ONCE_STAMPS.keySet());
        staleStamps.removeAll(updates.keySet());
        assertEquals(Set.of(), staleStamps, "a declared write-once stamp that no longer exists must be removed");
        updates.keySet().removeAll(LEDGER_WRITE_ONCE_STAMPS.keySet());
        assertEquals(Map.of(), updates,
                "ledger 组的表被更新了: 改归 COLUMN_SCOPED/FULL, 或确属一次性完成回填时登记理由");
    }

    @Test
    void everyTableInTheMigratedSchemaIsClassified() throws IOException {
        Set<String> live = new TreeSet<>(liveTableVersions().keySet());
        live.addAll(CREATED_OUTSIDE_MIGRATIONS);
        Set<String> classified = new TreeSet<>(fullTables().keySet());
        classified.addAll(scopedTables().keySet());
        classified.addAll(noneTables());

        Set<String> unclassified = new TreeSet<>(live);
        unclassified.removeAll(classified);
        assertEquals(Set.of(), unclassified,
                "新建表必须归入 FULL / COLUMN_SCOPED / NONE 之一并写明理由"
                        + "(FULL/COLUMN_SCOPED 还要在建表迁移里调用 fn_audit_track_table)");
        Set<String> stale = new TreeSet<>(classified);
        stale.removeAll(live);
        assertEquals(Set.of(), stale, "Listed tables must exist in the migrated schema");
    }

    @Test
    void policyBaselineAppliesExactlyTheDeclaredFullAndScopedLists() throws IOException {
        String sql = stripSqlComments(Files.readString(POLICY_BASELINE, StandardCharsets.UTF_8));
        Map<String, String> declaredFull = new LinkedHashMap<>();
        Set<String> declaredRedacted = new HashSet<>();
        Matcher full = FULL_CALL.matcher(sql);
        while (full.find()) {
            Matcher table = QUOTED.matcher(full.group(3));
            while (table.find()) {
                assertEquals(null, declaredFull.put(table.group(1), full.group(1)),
                        table.group(1) + " is applied twice");
                if (Boolean.parseBoolean(full.group(2))) {
                    declaredRedacted.add(table.group(1));
                }
            }
        }
        // 基线之后新建的 FULL 表由各自建表迁移调用 fn_audit_track_table 登记(见下一个用例), 不在 V646 里。
        Map<String, Integer> created = liveTableVersions();
        Map<String, String> baselineFull = new LinkedHashMap<>(fullTables());
        baselineFull.keySet().removeIf(t -> created.getOrDefault(t, 0) > POLICY_BASELINE_VERSION);
        Set<String> baselineRedacted = new HashSet<>(redactedFullTables());
        baselineRedacted.removeIf(t -> created.getOrDefault(t, 0) > POLICY_BASELINE_VERSION);
        // V646 之后被整表删除的(如 V655 删除的角色四表)在 V646 登记过, 但不再出现在清单里。
        declaredFull.keySet().removeIf(t -> !created.containsKey(t));
        declaredRedacted.removeIf(t -> !created.containsKey(t));
        assertEquals(baselineFull, declaredFull, "V646 FULL calls must equal the FULL list and categories");
        assertEquals(baselineRedacted, declaredRedacted, "Payroll-class redaction flags must match");

        Map<String, ScopedTable> declaredScoped = new LinkedHashMap<>();
        Matcher scoped = SCOPED_CALL.matcher(sql);
        while (scoped.find()) {
            List<String> columns = new ArrayList<>();
            Matcher column = QUOTED.matcher(scoped.group(4));
            while (column.find()) {
                columns.add(column.group(1));
            }
            ScopedTable expected = scopedTables().get(scoped.group(1));
            assertTrue(expected != null, scoped.group(1) + " is scoped in V646 but not listed");
            declaredScoped.put(scoped.group(1), new ScopedTable(scoped.group(1), scoped.group(2),
                    Boolean.parseBoolean(scoped.group(5)), columns, expected.reason()));
        }
        assertEquals(scopedTables(), declaredScoped, "V646 COLUMN_SCOPED calls must equal the list");

        String normalized = sql.replaceAll("\\s+", " ").toLowerCase(Locale.ROOT);
        assertTrue(normalized.contains("when (old.* is distinct from new.*)"),
                "FULL updates must skip no-op rows before calling the audit function");
        assertTrue(normalized.contains("current_setting('app.legacy_import', true) = 'on'"),
                "Offline legacy imports bypass row auditing");
        assertTrue(normalized.contains("drop function public.fn_audit_classify("),
                "Classification is computed once at write time, not by a database trigger");
        assertTrue(normalized.contains("'updated_at', 'updated_by', 'version', 'lock_version'")
                        && normalized.contains("'last_login_at'")
                        && normalized.contains("'quantity_unit_locked'"),
                "Volatile columns never produce an update audit row");
        assertTrue(normalized.contains("v_action := 'delete'"),
                "Soft deletes keep delete meaning");
        assertTrue(normalized.contains("app.audit_device_context")
                        && normalized.contains("device_profile_hash"),
                "Database audit rows keep the device correlation");
        assertTrue(normalized.contains("fn_audit_mask_account"),
                "Stored accounts are masked");
    }

    @Test
    void tablesCreatedAfterTheBaselineRegisterTheirPolicyInMigrations() throws IOException {
        Map<String, Integer> created = liveTableVersions();
        Map<String, String> registered = new HashMap<>();
        for (MigrationSource migration : migrations()) {
            if (migration.version() <= POLICY_BASELINE_VERSION) {
                continue;
            }
            Matcher registration = REGISTRATION.matcher(stripSqlComments(migration.sql()));
            while (registration.find()) {
                registered.put(registration.group(1), registration.group(2));
            }
        }
        List<String> missing = new ArrayList<>();
        created.forEach((table, version) -> {
            if (version <= POLICY_BASELINE_VERSION) {
                return;
            }
            String expected = fullTables().containsKey(table) ? "FULL"
                    : scopedTables().containsKey(table) ? "COLUMN_SCOPED" : "NONE";
            if (!"NONE".equals(expected) && !expected.equals(registered.get(table))) {
                missing.add(table + "@V" + version + " needs fn_audit_track_table('" + table + "', '"
                        + expected + "', ...)");
            }
        });
        assertEquals(List.of(), missing);
    }

    @Test
    void laterMigrationsNeverHandWriteAuditTriggersOrFullTableSweeps() throws IOException {
        for (MigrationSource migration : migrations()) {
            if (migration.version() <= POLICY_BASELINE_VERSION) {
                continue;
            }
            String sql = stripSqlComments(migration.sql()).replaceAll("\\s+", " ").toLowerCase(Locale.ROOT);
            assertFalse(sql.contains("create trigger trg_audit_"),
                    migration.path().getFileName() + " must attach audit triggers through fn_audit_track_table");
            assertFalse(sql.contains("execute function fn_audit()")
                            || sql.contains("execute function public.fn_audit()"),
                    migration.path().getFileName() + " must not bind fn_audit without the three-list policy");
            assertFalse(migration.path().getFileName().toString().contains("refresh_audit_trigger_coverage"),
                    "Full-table audit sweeps are retired by ADR-105");
        }
    }

    @Test
    void createTableParserHandlesQuotedUnquotedAndDynamicIdentifiers() {
        Matcher plain = CREATE_TABLE.matcher("CREATE TABLE public.goods (id UUID)");
        assertTrue(plain.find());
        assertEquals("goods", plain.group(1));

        String quote = Character.toString(34);
        Matcher quoted = CREATE_TABLE.matcher("CREATE TABLE IF NOT EXISTS "
                + quote + "public" + quote + "." + quote + "Goods_Audit" + quote
                + " (id UUID)");
        assertTrue(quoted.find());
        assertEquals("Goods_Audit", quoted.group(1));

        Matcher partition = CREATE_TABLE.matcher("CREATE TABLE audit_log_p202609 PARTITION OF audit_log");
        assertTrue(partition.find());
        assertTrue(partition.group(2) != null, "partitions are not separate policy tables");

        assertFalse(CREATE_TABLE.matcher("EXECUTE format('CREATE TABLE IF NOT EXISTS %I', name)").find()
                        && "if".equalsIgnoreCase(firstCreated("EXECUTE format('CREATE TABLE IF NOT EXISTS %I', name)")),
                "dynamic names are not tables");
    }

    @Test
    void optionalIdentityMigrationsAreTablelessConstraintHardening()
            throws IOException {
        for (String filename : List.of(
                "V286__employee_sensitive_optional_primary_identity.sql",
                "V287__employee_sensitive_optional_identity_invariants.sql")) {
            String sql = stripSqlComments(Files.readString(
                    MIGRATION_ROOT.resolve(filename), StandardCharsets.UTF_8));
            assertFalse(CREATE_TABLE.matcher(sql).find(),
                    filename + " must stay tableless");
        }
    }

    @Test
    void v425BytesTouchOnlyAuditTablesAfterFreshChainGuardAllowsExecution()
            throws IOException {
        String sql = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve("V425__audit_log_fresh_start.sql"),
                        StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ")
                .toLowerCase(Locale.ROOT);
        assertTrue(sql.contains(
                "truncate table audit_log, audit_log_archive restart identity"),
                "Only after the fresh-chain guard allows V425, its frozen bytes must "
                        + "touch only the hot audit table and cold archive");
        assertFalse(sql.contains("delete from") || sql.contains("truncate table business"),
                "V425 must not touch business tables");
        String migrator = Files.readString(Path.of(
                "src/main/java/com/uten/imp/migration/UtenImpMigrator.java"),
                StandardCharsets.UTF_8);
        assertTrue(migrator.contains("new AuditFreshStartGuardCallback()"),
                "standalone migration must register the V425 fresh-chain guard");
    }

    @Test
    void v289BorrowGuardsStayAtTheDatabaseBoundary() throws IOException {
        String v288Sql = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve("V288__production_material_analysis_borrows.sql"),
                StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ")
                .toLowerCase(Locale.ROOT);
        assertTrue(v288Sql.contains(
                        "foreign key (analysis_id, from_material_id) references "
                                + "production_material_analysis_materials(analysis_id, id)")
                        && v288Sql.contains(
                        "foreign key (analysis_id, to_material_id) references "
                                + "production_material_analysis_materials(analysis_id, id)"),
                "V288 must bind both borrow endpoints to their declared analysis");
        String sql = stripSqlComments(Files.readString(
                MIGRATION_ROOT.resolve("V289__refresh_audit_trigger_coverage.sql"),
                StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ")
                .toLowerCase(Locale.ROOT);
        assertTrue(sql.contains(
                        "create function fn_guard_production_material_analysis_borrow_mutation")
                        && sql.contains("new.status not in ('active', 'revoked')")
                        && sql.contains("deferrable initially deferred"),
                "V289 keeps the borrow lifecycle guards; its audit sweep is superseded by V646");
        assertTrue(fullTables().containsKey("production_material_analysis_borrows"),
                "A human borrow decision stays fully audited");
    }

    private static String firstCreated(String sql) {
        Matcher matcher = CREATE_TABLE.matcher(sql);
        return matcher.find() ? matcher.group(1) : "";
    }

    /** 迁移链结束时存在的表 -> 首次创建的版本(按建表/删表/改名依次回放)。 */
    static Map<String, Integer> liveTableVersions() throws IOException {
        Map<String, Integer> live = new LinkedHashMap<>();
        for (MigrationSource migration : migrations()) {
            String sql = stripSqlComments(migration.sql());
            List<Object[]> events = new ArrayList<>();
            Matcher create = CREATE_TABLE.matcher(sql);
            while (create.find()) {
                if (create.group(2) == null) {
                    events.add(new Object[]{create.start(), "create", create.group(1).toLowerCase(Locale.ROOT), null});
                }
            }
            Matcher drop = DROP_TABLE.matcher(sql);
            while (drop.find()) {
                for (String name : drop.group(1).split(",")) {
                    String[] parts = name.trim().split("\\.");
                    String table = parts[parts.length - 1].replace("\"", "").toLowerCase(Locale.ROOT);
                    events.add(new Object[]{drop.start(), "drop", table, null});
                }
            }
            Matcher rename = RENAME_TABLE.matcher(sql);
            while (rename.find()) {
                events.add(new Object[]{rename.start(), "rename",
                        rename.group(1).toLowerCase(Locale.ROOT), rename.group(2).toLowerCase(Locale.ROOT)});
            }
            events.sort(Comparator.comparingInt(event -> (Integer) event[0]));
            for (Object[] event : events) {
                String table = (String) event[2];
                switch ((String) event[1]) {
                    case "create" -> live.putIfAbsent(table, migration.version());
                    case "drop" -> live.remove(table);
                    default -> {
                        Integer version = live.remove(table);
                        if (version != null) {
                            live.put((String) event[3], version);
                        }
                    }
                }
            }
        }
        return live;
    }

    static List<MigrationSource> migrations() throws IOException {
        List<MigrationSource> result = new ArrayList<>();
        try (Stream<Path> files = Files.list(MIGRATION_ROOT)) {
            for (Path path : files.filter(Files::isRegularFile).toList()) {
                Matcher matcher = MIGRATION_FILE.matcher(path.getFileName().toString());
                if (matcher.matches()) {
                    result.add(new MigrationSource(Integer.parseInt(matcher.group(1)), path,
                            Files.readString(path, StandardCharsets.UTF_8)));
                }
            }
        }
        result.sort(Comparator.comparingInt(MigrationSource::version));
        return result;
    }

    /** Removes SQL comments so documentation examples cannot look like DDL. */
    static String stripSqlComments(String sql) {
        StringBuilder result = new StringBuilder(sql.length());
        boolean lineComment = false;
        boolean blockComment = false;
        boolean quoted = false;
        for (int index = 0; index < sql.length(); index++) {
            char current = sql.charAt(index);
            char next = index + 1 < sql.length() ? sql.charAt(index + 1) : '\0';
            if (lineComment) {
                if (current == '\n') {
                    lineComment = false;
                    result.append(current);
                }
                continue;
            }
            if (blockComment) {
                if (current == '*' && next == '/') {
                    blockComment = false;
                    index++;
                }
                continue;
            }
            if (!quoted && current == '-' && next == '-') {
                lineComment = true;
                index++;
                continue;
            }
            if (!quoted && current == '/' && next == '*') {
                blockComment = true;
                index++;
                continue;
            }
            if (current == '\'') {
                if (quoted && next == '\'') {
                    result.append(current).append(next);
                    index++;
                    continue;
                }
                quoted = !quoted;
            }
            result.append(current);
        }
        return result.toString();
    }

    record MigrationSource(int version, Path path, String sql) {
    }
}
