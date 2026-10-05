package com.uten.imp.ops;

import com.uten.imp.migration.MigrationRehearsalSupport;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 工作台「系统测试 · 清空业务数据」两处事实的同步锁(ADR-155)：
 * <ol>
 *   <li>迁移函数 business_data_reset() 是 CLEAR/PRESERVE 分类唯一的家(V464 为最后一次整函数重发，
 *       此后的迁移只按锚点补丁增删分类行，登记在下面几张表里)。{@link #expectedCurrentPolicy()}
 *       由冻结的 V464 加登记的变化独立推导，是评审用的神谕；安装后的函数与它逐表相等由
 *       BusinessDataResetCatalogPostgresTest 在真实库里核对；</li>
 *   <li>BusinessDataResetService 只做编排(检查、删除测试文件、绑定 actor、调函数)，不内联清空 SQL。</li>
 * </ol>
 * 迁移新增表后必须在这里登记，否则神谕与安装后的函数不一致；运行时未分类的表同样拒绝清空。
 */
public class BusinessDataResetSqlContractTest {

    private static final Pattern POLICY_ROW = Pattern.compile(
            "\\('([a-z][a-z0-9_]*)'\\s*,\\s*'(CLEAR|PRESERVE)'\\)");

    /**
     * V474 起经「读取已安装函数定义 + 失败关闭锚点替换」插入孪生函数的扩展行。
     * 表名 -> 引入迁移版本号；新增扩展时同步登记。
     */
    private static final Map<String, Integer> RUNTIME_RESET_EXTENSIONS = Map.ofEntries(
            Map.entry("preplan_public_supply_events", 474),
            Map.entry("preplan_root_output_events", 478),
            Map.entry("sales_order_qty_change_logs", 484),
            Map.entry("procurement_order_qty_change_logs", 486),
            Map.entry("sales_order_revision_logs", 492),
            Map.entry("preplan_subcontract_make_batch_reversals", 496),
            Map.entry("stock_value_pools", 504),
            Map.entry("stock_value_events", 504),
            Map.entry("stock_value_nodes", 504),
            Map.entry("stock_value_edges", 504),
            Map.entry("stock_value_jobs", 504),
            Map.entry("stock_value_tasks", 504),
            Map.entry("stock_value_node_revisions", 504),
            Map.entry("stock_value_postings", 504),
            Map.entry("procurement_order_source_revisions", 504),
            Map.entry("procurement_order_source_revision_allocations", 504),
            Map.entry("procurement_order_source_revision_peg_changes", 504),
            Map.entry("stock_value_openings", 506),
            Map.entry("stock_value_legacy_balance_cases", 506),
            Map.entry("stock_value_legacy_balance_case_events", 506),
            Map.entry("sales_shipment_submission_events", 519),
            Map.entry("production_material_movement_links", 514),
            Map.entry("production_material_return_requests", 560),
            Map.entry("production_material_return_request_items", 560),
            Map.entry("production_material_return_request_cancellations", 560),
            Map.entry("subcontract_short_delivery_cases", 636),
            Map.entry("subcontract_short_delivery_case_events", 636),
            Map.entry("subcontract_component_stock_handoffs", 646),
            Map.entry("production_execution_segment_growth_events", 647),
            Map.entry("production_execution_segment_splits", 561),
            Map.entry("preplan_reallocation_make_supplements", 568),
            Map.entry("preplan_future_supply_transfers", 569),
            Map.entry("preplan_future_supply_transfer_cancellations", 569),
            Map.entry("stock_value_acquisition_sources", 517),
            Map.entry("stock_value_position_transfers", 517),
            Map.entry("stock_value_production_cost_dirty", 517),
            Map.entry("stock_value_production_cost_inputs", 517),
            Map.entry("stock_value_production_cost_objects", 517),
            Map.entry("stock_value_production_cost_outputs", 517),
            Map.entry("stock_value_production_cost_revisions", 517),
            Map.entry("stock_value_production_cost_shares", 517),
            Map.entry("stock_value_production_cost_tasks", 517),
            Map.entry("procurement_iqc_consideration_reversals", 518),
            Map.entry("procurement_iqc_consideration_review_approvals", 518),
            Map.entry("procurement_iqc_credit_case_allocations", 518),
            Map.entry("procurement_iqc_credit_documents", 518),
            Map.entry("procurement_iqc_credit_slices", 518),
            Map.entry("procurement_iqc_funding_settlements", 518),
            Map.entry("procurement_iqc_funding_slices", 518),
            Map.entry("procurement_iqc_quality_consideration_parts", 518),
            Map.entry("procurement_iqc_stock_consideration_parts", 518),
            Map.entry("procurement_receipt_consideration_parts", 518),
            Map.entry("subcontract_receipt_material_consumptions", 522),
            Map.entry("production_fqc_inspection_sheets", 547),
            Map.entry("production_fqc_inspection_sheet_items", 547),
            Map.entry("production_finished_arrival_registration_reversals", 548),
            // V583/V584 建表时漏登记，V586 统一补进清库策略（四张都是纯业务事实）。
            Map.entry("production_daily_report_material_usages", 586),
            Map.entry("production_workshop_direct_transfer_items", 586),
            Map.entry("production_workshop_direct_transfer_reversals", 586),
            Map.entry("production_workshop_direct_transfers", 586),
            Map.entry("expense_claim_events", 608),
            Map.entry("expense_claim_invoices", 608),
            Map.entry("production_daily_report_target_events", 614),
            Map.entry("production_daily_report_material_release_events", 614),
            Map.entry("production_workshop_direct_source_allocations", 615),
            Map.entry("production_workshop_direct_source_events", 615),
            Map.entry("production_workshop_direct_legacy_anomalies", 615),
            Map.entry("production_material_return_receiving_confirmations", 618),
            Map.entry("production_workshop_material_return_slices", 619),
            Map.entry("production_workshop_material_custody_preparations", 619),
            Map.entry("production_workshop_material_custody_moves", 619),
            Map.entry("production_workshop_material_custody_reversals", 619),
            Map.entry("production_workshop_material_custody_handoffs", 619),
            Map.entry("production_workshop_custody_handoff_reversals", 619),
            Map.entry("production_workshop_custody_reverse_preparations", 619),
            Map.entry("production_workshop_return_preplan_events", 619),
            // V680 服务端会话与再认证失败计数 (ADR-110)：清空业务数据本就全员下线, 会话随之清空。
            Map.entry("auth_sessions", 680),
            Map.entry("auth_step_up_states", 680),
            Map.entry("production_overproduction_rate_requests", 698),
            Map.entry("production_overproduction_rate_decisions", 698),
            Map.entry("production_actual_output_supplement_requests", 700),
            Map.entry("production_actual_output_supplement_proofs", 700),
            Map.entry("production_actual_output_supplement_reversals", 700),
            Map.entry("production_actual_output_supplement_claims", 700),
            Map.entry("production_material_increment_requests", 702),
            Map.entry("production_material_increment_decisions", 702),
            Map.entry("production_material_increment_reversals", 702),
            // V703 车间催计划下单子层物料 (ADR-117)：催办提醒随业务流程数据清空。
            Map.entry("production_planning_urges", 703),
            Map.entry("production_material_discovery_requests", 710),
            Map.entry("production_draw_issue_batches", 727),
            Map.entry("stock_draw_issue_batches", 771),
            Map.entry("production_material_discovery_lines", 710),
            Map.entry("production_bom_learning_samples", 711),
            Map.entry("production_bom_learning_refresh_queue", 711),
            Map.entry("preplan_aggregate_batches", 712),
            Map.entry("preplan_aggregate_batch_events", 712),
            Map.entry("preplan_aggregate_material_aliases", 712),
            Map.entry("preplan_aggregate_direct_transfer_slices", 715),
            Map.entry("preplan_make_public_claims", 722),
            Map.entry("preplan_make_public_claim_cancellations", 722),
            // V740 +18 CLEAR / +3 PRESERVE (ADR-131): 车间内料仓进出、期间、盘点、结算与段用料随业务清空。
            Map.entry("workshop_material_settings", 740),
            Map.entry("production_execution_periodic_materials", 740),
            Map.entry("production_execution_material_changes", 740),
            Map.entry("workshop_material_commands", 740),
            Map.entry("workshop_material_requisitions", 740),
            Map.entry("workshop_material_requisition_lines", 740),
            Map.entry("workshop_material_stock_documents", 740),
            Map.entry("workshop_material_requisition_postings", 740),
            Map.entry("workshop_material_other_issues", 740),
            Map.entry("workshop_material_periods", 740),
            Map.entry("workshop_material_counts", 740),
            Map.entry("workshop_material_count_lines", 740),
            Map.entry("workshop_material_period_lines", 740),
            Map.entry("workshop_material_count_postings", 740),
            Map.entry("workshop_material_period_closes", 740),
            Map.entry("workshop_material_close_materials", 740),
            Map.entry("workshop_material_close_theory_lines", 740),
            Map.entry("workshop_material_close_allocations", 740),

            // V742 公共 AI 平台与销售客户文件识别(ADR-133/ADR-134)：识别任务、调用技术记录与
            // 报价核价修订记录随业务数据清空。
            Map.entry("ai_jobs", 742),
            Map.entry("ai_call_logs", 742),
            Map.entry("sales_quote_revision_logs", 742),
            // V743 仓库重量账(ADR-135)：只改重量的库存账行随库存业务数据清空。
            Map.entry("stock_weight_adjustments", 743),
            Map.entry("sales_quote_template_candidates", 745),
            Map.entry("sales_quote_template_evidence", 745),
            Map.entry("sales_document_learning_receipts", 751),
            Map.entry("sales_intake_layout_learning_evidence", 751),
            Map.entry("inventory_cost_gl_periods", 754),
            Map.entry("inventory_cost_gl_period_choices", 754),
            Map.entry("inventory_cost_gl_links", 754),
            Map.entry("stock_count_requests", 766),
            Map.entry("stock_count_request_lines", 766),
            Map.entry("stock_count_request_events", 766),
            Map.entry("workshop_material_count_adjustment_postings", 768),
            Map.entry("business_test_object_cleanup_intents", 782));

    /**
     * V579 起 PRESERVE 语义的运行时扩展(基础资料子表随主档保留)。
     * 同样走「读取已安装函数定义 + 锚点替换插入」补丁；与 CLEAR 扩展分开登记。
     */
    private static final Map<String, Integer> PRESERVE_RESET_EXTENSIONS = Map.ofEntries(
            Map.entry("legacy_subcontract_order_import_sources", 624),
            Map.entry("legacy_finance_import_sources", 626),
            Map.entry("legacy_procurement_receipt_import_sources", 627),
            Map.entry("expense_claim_settings", 617),
            Map.entry("party_activity_records", 579),
            Map.entry("party_addresses", 579),
            Map.entry("party_contact_methods", 579),
            // V686 总账附表行绑定(ADR-112): 报表配置随科目/部门主档保留。
            Map.entry("finance_report_line_bindings", 686),
            // V693 仓库负责人(ADR-115): 仓库的附属设置随主档保留。
            Map.entry("warehouse_keepers", 693),
            Map.entry("goods_bom_learning_profiles", 711),
            Map.entry("goods_bom_learning_material_totals", 711),
            // V739 / ADR-129：真实使用数量按 (父件, 组件, 单位) 累计，取代按颜色的累计表。
            Map.entry("goods_bom_actual_usages", 739),
            // V740 (ADR-131): 机台、机台容器与认料是车间和产品的配置, 随主档保留。
            Map.entry("workshop_machines", 740),
            Map.entry("workshop_machine_containers", 740),
            Map.entry("goods_periodic_material_choices", 740),

            // V742(ADR-133/ADR-134): AI 服务商配置、客户货品对照与客户文件版式是配置/学习知识。
            Map.entry("ai_providers", 742),
            Map.entry("client_goods_aliases", 742),
            Map.entry("sales_intake_layouts", 742),
            // V743 单重学习(ADR-135)：称重设置、称重观测与学习结果随主档保留。
            Map.entry("goods_weight_profiles", 743),
            Map.entry("goods_weight_observations", 743),
            Map.entry("goods_weight_estimates", 743),
            Map.entry("business_column_definitions", 744),
            Map.entry("sales_quote_customer_templates", 745),
            Map.entry("sales_quote_template_versions", 745),
            Map.entry("platform_column_definitions", 750),
            Map.entry("platform_record_fields", 750),
            Map.entry("platform_column_usage", 750),
            Map.entry("sales_alias_document_evidence", 752),
            Map.entry("goods_cost_sheets", 753),
            Map.entry("goods_cost_snapshots", 753),
            Map.entry("goods_cost_commands", 753),
            Map.entry("goods_cost_templates", 753),
            Map.entry("inventory_cost_gl_policy", 754),
            Map.entry("goods_cost_imports", 755),
            Map.entry("goods_cost_import_mappings", 755),
            Map.entry("ai_input_originals",773),Map.entry("ai_input_original_bindings",773),
            Map.entry("sales_quote_template_candidate_history",773),
            Map.entry("business_record_history",775),Map.entry("business_record_retention_registry",775),
            Map.entry("business_record_identities",775),
            Map.entry("notice_blessing_history",778),Map.entry("ai_provider_history",778),Map.entry("platform_record_field_versions",779));

    private static final java.util.Set<String> PERMANENT_POLICY_OVERRIDES=java.util.Set.of(
        "ai_jobs","ai_call_logs","sales_document_learning_receipts","sales_quote_template_candidates","sales_quote_template_evidence",
        "notices","notice_user_states","notice_acknowledgments","notice_blessings","visitor_sms_codes");

    /** Explicit testing exception; ordinary deletion and scheduled retention keep their guards. */
    private static final java.util.Set<String> TEST_RESET_CLEAR_OVERRIDES=java.util.Set.of(
        "ai_jobs","ai_call_logs","sales_document_learning_receipts","sales_quote_template_candidates","sales_quote_template_evidence",
        "notices","notice_user_states","notice_acknowledgments","notice_blessings","visitor_sms_codes",
        "ai_input_originals","ai_input_original_bindings","sales_quote_template_candidate_history",
        "business_record_history","business_record_identities","notice_blessing_history","ai_provider_history",
        "platform_record_field_versions","platform_column_usage");

    /**
     * V590 起整表废弃并从清空策略移除的表(「读取已安装定义 + 锚点替换删除」
     * 补丁)。新增删除时同步登记。
     * 表原来的 CLEAR/PRESERVE 归类取自冻结的 V464 基线，计数公式按归类分别扣减。
     */
    private static final Map<String, Integer> REMOVED_RESET_TABLES = Map.ofEntries(
            Map.entry("production_goods_workshop_preferences", 590),
            // V677 / ADR-109：角色体系删除，四张角色表从清单两侧同时移除。
            Map.entry("roles", 677),
            Map.entry("user_roles", 677),
            Map.entry("role_permissions", 677),
            Map.entry("department_roles", 677),
            // V739 / ADR-129：按颜色的学习累计表由 goods_bom_actual_usages 取代。
            Map.entry("goods_bom_learning_material_totals", 739),
            // V741 / ADR-133：政策情报 AI 退役，外部抓取的政策摘要表整表删除。
            Map.entry("official_policy_briefs", 741),
            // V743 / ADR-135：V442 采集偏好学习退役(四张 CLEAR 采集表 + 三张 PRESERVE 旧库计量证据)。
            Map.entry("measurement_capture_decision_events", 743),
            Map.entry("measurement_capture_evidence", 743),
            Map.entry("measurement_capture_line_snapshots", 743),
            Map.entry("measurement_capture_profiles", 743),
            Map.entry("legacy_measurement_exceptions", 743),
            Map.entry("legacy_measurement_profile_snapshots", 743),
            Map.entry("legacy_measurement_source_registry", 743),
            // V798 / ADR-155：签名意图票据整套机制删除(临时号，合并时随迁移改号)。
            Map.entry("business_test_object_cleanup_intents", 798));

    private String migrationSql;
    private String serviceSource;
    private String extensionSql;

    @BeforeEach
    void loadSources() throws IOException {
        migrationSql = read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V464__reset_twin_order_item_sources.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V464__reset_twin_order_item_sources.sql"));
        serviceSource = read(
                Path.of("src", "main", "java", "com", "uten", "imp", "features", "admin",
                        "systemtest", "BusinessDataResetService.java"),
                Path.of("server", "src", "main", "java", "com", "uten", "imp", "features",
                        "admin", "systemtest", "BusinessDataResetService.java"));
        // The reviewed table/version registry is also the source-file manifest.
        // A new registration must never be silently omitted from a second hand-maintained list.
        var versions = new java.util.TreeSet<Integer>();
        versions.addAll(RUNTIME_RESET_EXTENSIONS.values());
        versions.addAll(PRESERVE_RESET_EXTENSIONS.values());
        versions.addAll(REMOVED_RESET_TABLES.values());
        StringBuilder extensions = new StringBuilder();
        for (int version : versions) extensions.append(extensionSql(version)).append('\n');
        extensionSql = extensions.toString();
    }

    @Test
    void serviceOnlyOrchestratesTheSingleObjectRule() {
        assertThat(serviceSource).doesNotContain("requirePermanentRecordsPreserved()", "PERMANENT_RECORD_REFUSAL")
                .contains("featureGate.requireEnabled()", "files.check(", "files.purge(",
                        "set_config('app.business_test_reset_objects', ?, true)");
        assertThat(RUNTIME_RESET_EXTENSIONS)
                .containsEntry("preplan_root_output_events", 478)
                .containsEntry("sales_order_qty_change_logs", 484);
    }

    /** V798 patches business_data_reset() by anchors and replaces two small functions after a byte check. */
    @Test
    void singleObjectRuleMigrationPatchesByAnchorsAndFailsClosed() throws IOException {
        String migration = singleObjectRuleMigration();
        for (String edit : List.of("E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E9a", "E9b")) {
            assertThat(migration).as("edit " + edit + " must be named in the anchor patch").contains("ARRAY['" + edit + "',");
        }
        assertThat(migration)
                .contains("md5(replace(prosrc, chr(13), ''))")
                .contains("CREATE OR REPLACE FUNCTION public.fn_clear_business_test_object_metadata()")
                .contains("CREATE OR REPLACE FUNCTION public.fn_attachment_retained_identity_guard()")
                .contains("REVOKE ALL ON FUNCTION public.fn_business_test_reset_verify_purged(), public.fn_clear_business_test_object_metadata() FROM uten")
                .contains("DROP TABLE public.business_test_object_cleanup_intents;")
                .contains("V798 changed reset catalog rows other than business_test_object_cleanup_intents")
                .doesNotContain("CREATE OR REPLACE FUNCTION public.business_data_reset()")
                .doesNotContain("CASCADE;");
        assertThat(policy(migration)).as("tuples only as doubled-quote literals").isEmpty();
    }

    @Test
    void runtimeResetExtensionsPatchTheTwinFunctionFailClosed() throws IOException {
        // V474 的补丁构件：读取已安装定义、锚点替换插入、锚点缺失即失败关闭。
        assertThat(extensionSql)
                .contains("pg_get_functiondef('business_data_reset()'::regprocedure)")
                .contains("RAISE EXCEPTION 'V474 cannot extend business_data_reset policy safely'")
                .contains("(''preplan_supply_actions'', ''CLEAR'')");
        for (String table : RUNTIME_RESET_EXTENSIONS.keySet()) {
            assertThat(extensionSql(RUNTIME_RESET_EXTENSIONS.get(table))
                    .replace("'public.business_data_reset()'", "'business_data_reset()'"))
                    .as(table + " must be inserted by its registered runtime reset migration")
                    .contains("pg_get_functiondef('business_data_reset()'::regprocedure)")
                    .contains("'" + table + "'");
        }
        // V579：PRESERVE 语义扩展同样走补丁(基础资料子表随主档保留)。
        assertThat(extensionSql)
                .contains("RAISE EXCEPTION 'V579 cannot extend business_data_reset policy safely'")
                .contains("(''party_contact_methods'', ''PRESERVE'')");
        assertThat(extensionSql)
                .contains("RAISE EXCEPTION 'V686 cannot extend business-data reset policy safely'")
                .contains("(''finance_report_line_bindings'', ''PRESERVE'')");
        assertThat(extensionSql)
                .contains("RAISE EXCEPTION 'V693 cannot extend business-data reset policy safely'")
                .contains("(''warehouse_keepers'', ''PRESERVE'')");
        assertThat(extensionSql(742))
                .contains("RAISE EXCEPTION 'V742 cannot extend business-data reset policy safely'")
                .contains("(''ai_providers'', ''PRESERVE'')")
                .contains("(''client_goods_aliases'', ''PRESERVE'')")
                .contains("(''sales_intake_layouts'', ''PRESERVE'')")
                .contains("(''ai_jobs'', ''CLEAR'')")
                .contains("(''ai_call_logs'', ''CLEAR'')")
                .contains("(''sales_quote_revision_logs'', ''CLEAR'')");
        // V590：整表废弃走「读已安装定义 + 锚点替换删除」补丁；锚点单行无换行，
        // 不受迁移文件 CRLF/LF 差异影响（V588 教训）。
        assertThat(extensionSql)
                .contains("RAISE EXCEPTION 'V590 cannot drop retired preference policy row from business_data_reset'")
                .contains("(''production_goods_workshop_preferences'', ''PRESERVE''),");
        assertThat(extensionSql(741))
                .contains("RAISE EXCEPTION 'V741 cannot drop retired official_policy_briefs from business_data_reset'")
                .contains("(''official_policy_briefs'', ''PRESERVE''),")
                .contains("DROP TABLE official_policy_briefs;");
        // V743：同一个补丁块里先按单行 needle 删掉 V442 七行，再在 stock_movements 锚点后插入四行。
        assertThat(extensionSql(743))
                .contains("RAISE EXCEPTION 'V743 cannot drop retired measurement policy row % from business_data_reset'")
                .contains("RAISE EXCEPTION 'V743 cannot extend business-data reset policy safely'")
                .contains("(''measurement_capture_profiles'', ''CLEAR''),")
                .contains("(''legacy_measurement_source_registry'', ''PRESERVE''),")
                .contains("(''goods_weight_profiles'', ''PRESERVE'')")
                .contains("(''goods_weight_observations'', ''PRESERVE'')")
                .contains("(''goods_weight_estimates'', ''PRESERVE'')");
    }

    @Test
    void appTwinKeepsOpsFailClosedChecksAndAddsKickAll() {
        // 与 ops 版同款失败关闭构件
        assertThat(migrationSql)
                .contains("存在未分类 public 表")
                .contains("表分类重复/重叠")
                .contains("保留表仍引用待清业务表，禁止清空")
                .contains("EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY'")
                .contains("清空校验失败")
                .contains("保留校验失败")
                .contains("物化视图清空校验失败")
                .contains("账户金额归零校验失败")
                .contains("遗留期初归零校验失败")
                .contains("货品安全库存/成本预算归零校验失败")
                .contains("USING ERRCODE = 'UT900'")
                .contains("REFRESH MATERIALIZED VIEW purchase_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW production_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW stock_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW finance_ar_ap_mv")
                .contains("REFRESH MATERIALIZED VIEW sales_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW subcontract_monthly_mv")
                .contains("UPDATE accounts")
                .contains("balance_current = 0")
                .contains("UPDATE payment_styles")
                .contains("init_balance = 0")
                .doesNotContain("DISABLE TRIGGER");

        // 应用内孪生独有的收尾：全员强制重新登录（epoch + 1 / 断续期）
        assertThat(migrationSql)
                .contains("UPDATE authorization_state")
                .contains("epoch = epoch + 1")
                .contains("TRUNCATE TABLE refresh_tokens RESTART IDENTITY");

        // 摘要出参：服务层据此回显
        assertThat(migrationSql)
                .contains("cleared_table_count INT")
                .contains("cleared_rows BIGINT")
                .contains("preserved_table_count INT")
                .contains("authorization_epoch_after BIGINT");
    }

    @Test
    void serviceOrchestratesOnlyAndBindsActorParameters() {
        // 服务层只编排：调用函数、绑定 actor（? 参数）、设置事务级超时；
        // 清空 SQL 全部在迁移函数里（安全写入门不允许 Java 内联此类 SQL）。
        assertThat(serviceSource)
                .contains("FROM business_data_reset()")
                .contains("SELECT set_config('app.actor_id', ?, true)")
                .contains("SELECT set_config('lock_timeout', ?, true)")
                .contains("SET LOCAL statement_timeout = '30min'")
                .contains("SET LOCAL idle_in_transaction_session_timeout = '30min'")
                .doesNotContain("TRUNCATE TABLE")
                .doesNotContain("DO $$");
        // 编排门禁与排水
        assertThat(serviceSource)
                .contains("featureGate.requireEnabled()")
                .contains("drainGate.beginDrain")
                .contains("drainGate.endReset()");
    }

    /**
     * <b>迁移头一动，要人工同步的只剩 docs/数据迁移/README.md 的头行。</b>
     *
     * <p>迁移头与条数从迁移目录数出来(版本对是 (Flyway 版本号, 已应用迁移条数)，两者因跳号不相等)，
     * 再与 {@code MigrationRehearsalSupport} 和迁移总览文档比对；漏改就当场报出该改成什么。</p>
     */
    @Test
    void migrationHeadSyncPointsFollowTheDirectory() throws IOException {
        Path migrations = resolve(
                Path.of("src", "main", "resources", "db", "migration"),
                Path.of("server", "src", "main", "resources", "db", "migration"));
        int head = 0;
        int count = 0;
        try (var files = Files.list(migrations)) {
            for (Path file : files.toList()) {
                Matcher matcher = MIGRATION_FILE.matcher(file.getFileName().toString());
                if (!matcher.matches()) continue;
                count++;
                head = Math.max(head, Integer.parseInt(matcher.group(1)));
            }
        }
        assertThat(head).as("迁移目录里没找到任何 V*.sql").isGreaterThan(0);

        // MigrationRehearsalSupport 从 classpath db/migration 目录自动推导迁移头与条数(目录是唯一事实源)。
        String rehearsal = read(
                Path.of("src", "test", "java", "com", "uten", "imp", "migration",
                        "MigrationRehearsalSupport.java"),
                Path.of("server", "src", "test", "java", "com", "uten", "imp", "migration",
                        "MigrationRehearsalSupport.java"));
        assertThat(rehearsal)
                .as("MigrationRehearsalSupport 自动推导迁移头时条数也必须来自目录")
                .contains("CURRENT_HEAD_VERSION = Integer.toString(head)")
                .contains("CURRENT_MIGRATION_COUNT = count");
        assertThat(MigrationRehearsalSupport.CURRENT_HEAD_VERSION).isEqualTo(Integer.toString(head));
        assertThat(MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT).isEqualTo(count);

        // 迁移总览文档的「当前源码目录」(LegacyMigrationSafetyContractTest 同样锁这一行)。
        String migrationReadme = read(
                Path.of("..", "docs", "数据迁移", "README.md"),
                Path.of("docs", "数据迁移", "README.md"));
        assertThat(migrationReadme)
                .as("docs/数据迁移/README.md 的「当前正式目录」没跟上："
                        + "请改成 **当前源码目录：V%d/%d …**（并补一句新迁移做了什么）"
                                .formatted(head, count))
                .contains("当前源码目录：V" + head + "/" + count);
    }

    /** Expected complete policy derives from frozen V464 plus explicit reviewed changes, never the installed function. */
    public static java.util.Set<String> expectedOperationalTables() {
        return RUNTIME_RESET_EXTENSIONS.entrySet().stream()
                .filter(entry -> entry.getValue() >= 511)
                .map(Map.Entry::getKey).collect(java.util.stream.Collectors.toUnmodifiableSet());
    }

    public static Map<String, String> expectedCurrentPolicy() throws IOException {
        Map<String, String> expected = policy(extensionSql(464));
        RUNTIME_RESET_EXTENSIONS.forEach((table, version) -> {
            assertThat(expected.putIfAbsent(table, "CLEAR"))
                    .as(table + " must be a new CLEAR extension in V" + version).isNull();
        });
        PRESERVE_RESET_EXTENSIONS.forEach((table, version) -> {
            assertThat(expected.putIfAbsent(table, "PRESERVE"))
                    .as(table + " must be a new PRESERVE extension in V" + version).isNull();
        });
        REMOVED_RESET_TABLES.forEach((table, version) ->
                assertThat(expected.remove(table)).as(table + " must exist before retirement in V" + version).isNotNull());
        PERMANENT_POLICY_OVERRIDES.forEach(table -> {
            assertThat(expected).as(table + " must already be a registered table before its retention override")
                    .containsKey(table);
            expected.put(table,"PRESERVE");
        });
        TEST_RESET_CLEAR_OVERRIDES.forEach(table -> {
            assertThat(expected).as(table + " must already be registered before its explicit testing exception")
                    .containsKey(table);
            expected.put(table,"CLEAR");
        });
        return expected;
    }

    private static String extensionSql(int version) throws IOException {
        Path directory = resolve(Path.of("src/main/resources/db/migration"),
                Path.of("server/src/main/resources/db/migration"));
        List<Path> matches;
        try (var files = Files.list(directory)) {
            matches = files.filter(path -> path.getFileName().toString().startsWith("V" + version + "__"))
                    .filter(path -> path.getFileName().toString().endsWith(".sql")).toList();
        }
        assertThat(matches).as("registered reset migration V" + version + " must resolve exactly once").hasSize(1);
        return Files.readString(matches.getFirst(), StandardCharsets.UTF_8);
    }

    /** The migration that creates the single object rule, located by content (independent of its number). */
    public static String singleObjectRuleMigration() throws IOException {
        Path directory = resolve(Path.of("src/main/resources/db/migration"),
                Path.of("server/src/main/resources/db/migration"));
        List<Path> matches = new java.util.ArrayList<>();
        try (var files = Files.list(directory)) {
            for (Path file : files.filter(path -> path.getFileName().toString().endsWith(".sql")).toList()) {
                if (Files.readString(file, StandardCharsets.UTF_8).contains("CREATE FUNCTION public.fn_business_test_reset_objects()")) {
                    matches.add(file);
                }
            }
        }
        assertThat(matches).as("exactly one migration creates fn_business_test_reset_objects()").hasSize(1);
        return Files.readString(matches.getFirst(), StandardCharsets.UTF_8);
    }

    private static Path resolve(Path direct, Path fallback) {
        return Files.exists(direct) ? direct : fallback;
    }

    private static String read(Path direct, Path fallback) throws IOException {
        return Files.readString(resolve(direct, fallback), StandardCharsets.UTF_8);
    }

    /** {@code V552__xxx.sql} → 捕获版本号；R__/U__ 等非版本迁移不计。 */
    private static final Pattern MIGRATION_FILE =
            Pattern.compile("^V([0-9]+)__.*\\.sql$");

    public static Map<String, String> policy(String sql) {
        Map<String, String> result = new LinkedHashMap<>();
        Matcher matcher = POLICY_ROW.matcher(sql);
        while (matcher.find()) {
            String previous = result.put(matcher.group(1), matcher.group(2));
            assertThat(previous)
                    .as("duplicate policy row for " + matcher.group(1))
                    .isNull();
        }
        return result;
    }
}
