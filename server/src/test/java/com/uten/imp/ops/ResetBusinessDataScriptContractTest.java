package com.uten.imp.ops;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class ResetBusinessDataScriptContractTest {

    private static final Pattern POLICY_ROW = Pattern.compile(
            "(?m)^\\s*\\('([^']+)'\\s*,\\s*'(CLEAR|PRESERVE)'\\)[,;]$");
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
    void v328PolicyClassifiesEveryKnownParentTableAndPreservesEvidence() {
        Map<String, String> policy = policy();

        assertThat(policy).hasSize(240);
        assertThat(policy.values().stream().filter("CLEAR"::equals).count())
                .isEqualTo(153);
        assertThat(policy.values().stream().filter("PRESERVE"::equals).count())
                .isEqualTo(87);

        assertThat(policy).containsAllEntriesOf(Map.of(
                "preplan_analysis_stock_exact_pegs", "CLEAR",
                "preplan_material_reallocations", "CLEAR",
                "preplan_stock_entitlement_events", "CLEAR",
                "subcontract_material_plans", "CLEAR",
                "subcontract_material_plan_items", "CLEAR"));

        Set<String> protectedEvidence = Set.of(
                "audit_log", "audit_log_archive",
                "attachments", "attachment_object_outbox",
                "attachment_upload_sessions", "attachment_reconciliation_findings",
                "goods_import_batches", "goods_import_creations",
                "legacy_migration_checkpoints",
                "legacy_migration_reconciliation_items",
                "legacy_migration_rejects", "legacy_migration_run_files",
                "legacy_migration_runs",
                "client_default_settlement_migration_issues",
                "profile_change_requests",
                "doc_number_sequences", "business_document_sequences");
        protectedEvidence.forEach(table ->
                assertThat(policy).containsEntry(table, "PRESERVE"));
        assertThat(policy).containsEntry(
                "production_product_no_sequences", "CLEAR");
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
                .contains("清空校验失败")
                .contains("保留校验失败")
                .contains("物化视图清空校验失败");
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
