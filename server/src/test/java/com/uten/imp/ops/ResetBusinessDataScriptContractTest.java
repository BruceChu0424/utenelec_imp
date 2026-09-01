package com.uten.imp.ops;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class ResetBusinessDataScriptContractTest {

    private static final Pattern POLICY_ROW = Pattern.compile(
            "(?m)^\\s*\\('([^']+)'\\s*,\\s*'(CLEAR|PRESERVE)'\\)[,;]?$");
    private String sql;

    @BeforeEach
    void loadScript() throws IOException {
        Path direct = Path.of("ops", "reset_business_data.sql");
        Path path = Files.exists(direct)
                ? direct : Path.of("server", "ops", "reset_business_data.sql");
        sql = Files.readString(path, StandardCharsets.UTF_8);
    }

    @Test
    void destructiveResetRequiresIdentityQuiescenceAndAttachmentGates() {
        assertThat(sql)
                .contains("confirm=CLEAR_BUSINESS")
                .contains("expected_database")
                .contains("expected_system_identifier")
                .contains("pg_control_system()")
                .contains("pg_stat_activity")
                .contains("pid <> pg_backend_pid()")
                .contains("backend_type = 'client backend'")
                .contains("business_outbox")
                .contains("status IN (0, 2)")
                .contains("attachment_upload_sessions")
                .contains("'EMPLOYEE', 'EMPLOYEE_CONTRACT'");
    }

    @Test
    void currentPolicyClassifiesEveryKnownParentTableAndPreservesEvidence() {
        Map<String, String> policy = policy();

        assertThat(policy).hasSize(314);
        assertThat(policy.values().stream().filter("CLEAR"::equals).count())
                .isEqualTo(219);
        assertThat(policy.values().stream().filter("PRESERVE"::equals).count())
                .isEqualTo(95);

        assertThat(policy).containsAllEntriesOf(Map.of(
                "preplan_analysis_stock_exact_pegs", "CLEAR",
                "preplan_material_reallocations", "CLEAR",
                "preplan_stock_entitlement_events", "CLEAR",
                "subcontract_material_plans", "CLEAR",
                "subcontract_material_plan_items", "CLEAR",
                "subcontract_outbound_preparation_commands", "CLEAR",
                "subcontract_outbound_issue_reservation_allocations", "CLEAR"));
        assertThat(policy).containsAllEntriesOf(Map.of(
                "procurement_iqc_rejection_cases", "CLEAR",
                "procurement_iqc_rejection_commands", "CLEAR",
                "procurement_iqc_rejection_events", "CLEAR",
                "procurement_iqc_replacement_allocations", "CLEAR"));
        assertThat(policy).containsAllEntriesOf(Map.of(
                "procurement_iqc_stock_in_batches", "CLEAR",
                "procurement_iqc_stock_in_batch_items", "CLEAR"));
        assertThat(policy).containsAllEntriesOf(Map.of(
                "preplan_subcontract_requirement_handoffs", "CLEAR",
                "preplan_subcontract_requirement_handoff_items", "CLEAR",
                "preplan_subcontract_requirement_supply_claims", "CLEAR",
                "preplan_subcontract_entitlement_handoff_slices", "CLEAR",
                "preplan_subcontract_requirement_handoff_events", "CLEAR"));
        assertThat(policy).containsAllEntriesOf(Map.of(
                "measurement_capture_profiles", "CLEAR",
                "measurement_capture_line_snapshots", "CLEAR",
                "measurement_capture_evidence", "CLEAR",
                "measurement_capture_decision_events", "CLEAR"));
        assertThat(policy).containsAllEntriesOf(Map.ofEntries(
                Map.entry("account_balance_adjustment_batches", "CLEAR"),
                Map.entry("account_balance_adjustment_items", "CLEAR"),
                Map.entry("customer_open_item_offset_batches", "CLEAR"),
                Map.entry("customer_open_item_offsets", "CLEAR"),
                Map.entry("finance_receipt_source_allocations", "CLEAR"),
                Map.entry("subcontract_loss_cases", "CLEAR"),
                Map.entry("subcontract_loss_fulfillment_allocations", "CLEAR"),
                Map.entry("supplier_claim_receivables", "CLEAR"),
                Map.entry("supplier_open_item_offsets", "CLEAR"),
                Map.entry("supplier_settlement_batches", "CLEAR"),
                Map.entry("sales_shipment_finance_release_events", "CLEAR")));
        Set.of(
                "account_flow_monthly_summaries",
                "production_daily_report_commands",
                "production_daily_report_workers",
                "production_finished_arrival_registration_items",
                "production_finished_arrival_registrations",
                "production_finished_in_confirm_batch_items",
                "production_finished_in_confirm_batches",
                "production_fqc_cancellation_events",
                "production_fqc_contribution_adjustments",
                "production_fqc_decision_events",
                "production_fqc_inspections",
                "production_fqc_pass_all_batch_items",
                "production_fqc_pass_all_batches",
                "production_fqc_legacy_exemptions",
                "production_fqc_recovery_allocation_events",
                "production_fqc_recovery_authorizations",
                "production_fqc_recovery_cancellation_events",
                "production_fqc_release_allocations",
                "production_fqc_release_commands",
                "production_fqc_replenishment_analysis_links",
                "production_fqc_replenishment_attempts",
                "production_fqc_replenishment_cycle_cancellations",
                "production_fqc_replenishment_cycles",
                "production_fqc_replenishment_draw_links",
                "production_fqc_replenishment_ready_events",
                "production_fqc_replenishment_ready_reversals",
                "production_fqc_replenishment_supply_gaps",
                "production_fqc_replenishment_tasks",
                "warehouse_arrival_registration_commands",
                "warehouse_arrival_exception_stock_in_batch_items",
                "warehouse_arrival_exception_stock_in_batches",
                "warehouse_goods_place_preferences"
        ).forEach(table -> assertThat(policy).containsEntry(table, "CLEAR"));

        Set<String> protectedEvidence = Set.of(
                "audit_log", "audit_log_archive",
                "attachments", "attachment_object_outbox",
                "attachment_upload_sessions", "attachment_reconciliation_findings",
                "goods_import_batches", "goods_import_creations",
                "legacy_migration_checkpoints",
                "legacy_migration_reconciliation_items",
                "legacy_migration_rejects", "legacy_migration_run_files",
                "legacy_migration_runs",
                "legacy_measurement_exceptions",
                "legacy_measurement_profile_snapshots",
                "legacy_measurement_source_registry",
                "unit_measurement_profiles",
                "client_default_settlement_migration_issues",
                "profile_change_requests",
                "client_access_change_events", "client_visibility_grants",
                "employee_data_handovers", "employee_data_handover_scopes",
                "employee_offboarding_events",
                "doc_number_sequences", "business_document_sequences");
        protectedEvidence.forEach(table ->
                assertThat(policy).containsEntry(table, "PRESERVE"));
        assertThat(policy).containsEntry(
                "production_product_no_sequences", "CLEAR");
        assertThat(sql)
                .contains("measurement_table_count <> 8")
                .contains("v440_business_table_count <> 6")
                .contains("v443_business_table_count <> 1")
                .contains("v446_business_table_count NOT IN (0, 2)")
                .contains("v447_business_table_count NOT IN (0, 5)")
                .contains("(applied_max_version, applied_migration_count) NOT IN")
                .contains("(443, 405)")
                .contains("(446, 408)")
                .contains("(447, 409)")
                .contains("(448, 410)")
                .contains("(449, 411)")
                .contains("(450, 412)")
                .contains("(451, 413)")
                .contains("仅允许 V443/405、V446/408、V447/409、V448/410、V449/411、V450/412 或 V451/413 目录")
                .contains("V448 合并页读路径索引缺失 %/5")
                .contains("V448 目录必须完整包含 V446 IQC 入库事实表与 V447 交接事实表")
                .contains("V451 库位学习来源泛化构件缺失 %/4")
                .contains("V451 只泛化库位学习表来源维度")
                .contains("V443/V446 要求 V436/V440 业务表完整存在")
                .contains("V443 财审事件表必须存在")
                .contains("V446 IQC 入库表只出现 %/2")
                .contains("v446_business_table_count = 0")
                .contains("v447_business_table_count = 0 AND clear_count = 212")
                .contains("v446_business_table_count = 2")
                .contains("v447_business_table_count = 0 AND clear_count = 214")
                .contains("v447_business_table_count = 5 AND clear_count = 219")
                .contains("V443/V446/V447 白名单数量异常")
                .contains("V447 委外前置自制权益交接表只出现 %/5")
                .contains("V447新增五张交接事实表后为219张")
                .contains("dependency.classid = 'pg_class'::regclass")
                .contains("dependency.deptype = 'e'")
                .contains("extension.extconfig")
                .contains("c.relname <> 'spatial_ref_sys'")
                .contains("to_regclass")
                .contains("PRESERVE 95 张");
        assertThat(sql.indexOf("('warehouse_goods_place_preferences', 'CLEAR')"))
                .isBetween(
                        sql.indexOf("('warehouse_arrival_registration_commands', 'CLEAR')") + 1,
                        sql.indexOf("('website_inquiries', 'CLEAR')") - 1);
    }

    @Test
    void resetFailsClosedOnCatalogDriftAndChecksEveryTable() {
        String executable = sql
                .replaceAll("(?m)--.*$", "")
                .replaceAll("(?s)/\\*.*?\\*/", "");
        assertThat(executable.toUpperCase()).doesNotContain("CASCADE");
        assertThat(sql)
                .contains("reset_business_table_policy")
                .contains("c.relkind IN ('r', 'p')")
                .contains("c.relispartition = FALSE")
                .contains("存在未分类 public 表")
                .contains("表分类重复/重叠")
                .contains("reset_business_preserve_counts")
                .contains("WHERE disposition = 'CLEAR'")
                .contains("WHERE disposition = 'PRESERVE'")
                .contains("EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY'")
                .contains("清空校验失败")
                .contains("保留校验失败")
                .contains("物化视图清空校验失败");
    }

    @Test
    void auditedOpeningSafetyCostAndAccountMoneyResetRunsBeforePreserveBaselineAndMustFinishAtZero() {
        assertThat(policy())
                .containsEntry("accounts", "PRESERVE")
                .containsEntry("goods", "PRESERVE")
                .containsEntry("goods_bom_items", "PRESERVE");
        assertThat(sql)
                .contains("'app.actor_account'")
                .contains("'ops:reset_business_data'")
                .contains("'app.audit_request_id'")
                .contains("gen_random_uuid()::text")
                .contains("UPDATE accounts")
                .contains("init_balance = 0")
                .contains("receipts_total = 0")
                .contains("payments_total = 0")
                .contains("balance_adjustments_total = 0")
                .contains("balance_current = 0")
                .contains("UPDATE clients")
                .contains("init_total = 0")
                .contains("init_total2 = 0")
                .contains("UPDATE suppliers")
                .contains("UPDATE goods")
                .contains("init_stock = 0")
                .contains("init_count = 0")
                .contains("init_weight = 0")
                .contains("UPDATE payment_styles")
                .contains("init_balance = 0")
                .contains("遗留期初归零校验失败")
                .contains("货品安全库存/成本预算归零校验失败")
                .contains("账户金额归零校验失败")
                .doesNotContain("DISABLE TRIGGER");

        Set<String> goodsZeroColumns = Set.of(
                "min_qty",
                "source_e", "work_e", "lacquer_e", "incidental_e",
                "plating_e", "casing_e", "manage_e", "polish_e",
                "electric_e", "machining_e", "lost_e", "rent_e", "make_e",
                "work_rate", "lost_rate", "make_rate", "rent_rate",
                "total", "c_total", "g_total"
        );
        goodsZeroColumns.forEach(column -> assertThat(sql)
                .as(column + " zero-baseline reset")
                .contains(column + " = 0")
                .contains(column + " IS DISTINCT FROM 0"));

        assertThat(Pattern.compile("(?m)^UPDATE goods\\s*$")
                .matcher(sql)
                .results()
                .count()).isEqualTo(1);

        int truncate = sql.indexOf("TRUNCATE TABLE");
        int accountReset = sql.indexOf("UPDATE accounts");
        int clientReset = sql.indexOf("UPDATE clients");
        int supplierReset = sql.indexOf("UPDATE suppliers");
        int goodsReset = sql.indexOf("UPDATE goods");
        int paymentStyleReset = sql.indexOf("UPDATE payment_styles");
        int preserveBaseline = sql.indexOf(
                "INSERT INTO reset_business_preserve_counts");
        int commit = sql.indexOf("\nCOMMIT;");
        assertThat(truncate).isNotNegative();
        assertThat(accountReset).isGreaterThan(truncate);
        assertThat(clientReset).isGreaterThan(accountReset);
        assertThat(supplierReset).isGreaterThan(clientReset);
        assertThat(goodsReset).isGreaterThan(supplierReset);
        assertThat(paymentStyleReset).isGreaterThan(goodsReset);
        assertThat(preserveBaseline).isGreaterThan(paymentStyleReset);
        assertThat(sql.substring(clientReset, supplierReset))
                .contains("version = version + 1")
                .contains("updated_at = CURRENT_TIMESTAMP");
        assertThat(sql.substring(supplierReset, goodsReset))
                .contains("version = version + 1")
                .contains("updated_at = CURRENT_TIMESTAMP");

        String goodsResetSql = sql.substring(goodsReset, paymentStyleReset);
        assertThat(goodsResetSql)
                .contains("version = version + 1")
                .contains("updated_at = CURRENT_TIMESTAMP")
                .doesNotContain(
                        "max_qty = 0", "price = 0", "a_price = 0", "price2 = 0",
                        "category_id =", "unit_id =");

        Matcher goodsAssignments = Pattern.compile(
                        "(?s)UPDATE goods\\s+SET\\s+(.*?)\\s+WHERE\\s+COALESCE\\(init_stock, 0\\) <> 0")
                .matcher(sql);
        assertThat(goodsAssignments.find()).isTrue();
        Set<String> goodsAssignmentColumns = new LinkedHashSet<>();
        Matcher assignment = Pattern.compile("(?m)^\\s*([a-z][a-z0-9_]*)\\s*=")
                .matcher(goodsAssignments.group(1));
        int assignmentCount = 0;
        while (assignment.find()) {
            goodsAssignmentColumns.add(assignment.group(1));
            assignmentCount++;
        }
        assertThat(assignmentCount).isEqualTo(26);
        assertThat(goodsAssignmentColumns).containsExactlyInAnyOrder(
                "init_stock", "init_count", "init_weight", "min_qty",
                "source_e", "work_e", "lacquer_e", "incidental_e",
                "plating_e", "casing_e", "manage_e", "polish_e",
                "electric_e", "machining_e", "lost_e", "rent_e", "make_e",
                "work_rate", "lost_rate", "make_rate", "rent_rate",
                "total", "c_total", "g_total", "version", "updated_at");

        Matcher goodsPostcondition = Pattern.compile(
                        "(?s)SELECT count\\(\\*\\)\\s+INTO n\\s+FROM goods\\s+WHERE\\s+(.*?);"
                                + "\\s+IF n <> 0 THEN\\s+RAISE EXCEPTION\\s+"
                                + "'货品安全库存/成本预算归零校验失败")
                .matcher(sql);
        assertThat(goodsPostcondition.find()).isTrue();
        Set<String> postconditionColumns = new LinkedHashSet<>();
        Matcher postconditionColumn = Pattern.compile(
                        "([a-z][a-z0-9_]*)\\s+IS DISTINCT FROM 0")
                .matcher(goodsPostcondition.group(1));
        int postconditionCount = 0;
        while (postconditionColumn.find()) {
            postconditionColumns.add(postconditionColumn.group(1));
            postconditionCount++;
        }
        assertThat(postconditionCount).isEqualTo(21);
        assertThat(postconditionColumns)
                .containsExactlyInAnyOrderElementsOf(goodsZeroColumns);
        assertThat(sql.lastIndexOf("账户金额归零校验失败"))
                .isBetween(preserveBaseline, commit - 1);
        assertThat(sql.lastIndexOf("遗留期初归零校验失败"))
                .isBetween(preserveBaseline, commit - 1);
        assertThat(sql.lastIndexOf("货品安全库存/成本预算归零校验失败"))
                .isBetween(preserveBaseline, commit - 1);
    }

    @Test
    void allMaterializedViewsRefreshAndValidateBeforeCommit() {
        int commit = sql.indexOf("\nCOMMIT;");
        assertThat(commit).isPositive();
        for (String view : Set.of(
                "purchase_monthly_mv", "production_monthly_mv",
                "stock_monthly_mv", "finance_ar_ap_mv",
                "sales_monthly_mv", "subcontract_monthly_mv")) {
            int refresh = sql.indexOf("REFRESH MATERIALIZED VIEW " + view + ";");
            assertThat(refresh).as(view + " refresh").isBetween(0, commit - 1);
        }
        assertThat(sql.lastIndexOf("物化视图清空校验失败"))
                .isBetween(0, commit - 1);
    }

    private Map<String, String> policy() {
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
