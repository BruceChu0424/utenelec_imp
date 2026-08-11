package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** Static safety contract for the additive V183 professional asset subledger migration. */
class ProfessionalAssetSubledgerMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/V183__professional_asset_and_deferral_subledger.sql");

    @Test
    void separatesObjectTypesPoliciesAndResponsibleEmployees() throws IOException {
        String sql = sql();

        assertThat(sql)
                .contains("CHECK (object_type IN ('FIXED_ASSET', 'DEFERRED_EXPENSE'))")
                .contains("UNIQUE (object_type, code, version)")
                .contains("WHERE status = 'ACTIVE' AND is_deleted = FALSE")
                .contains("custodian_employee_id UUID REFERENCES employees(id)")
                .contains("responsible_employee_id UUID REFERENCES employees(id)")
                .contains("operating_status VARCHAR(32)")
                .contains("benefit_end_on DATE")
                .contains("ux_fixed_assets_active_source_line")
                .contains("ux_deferred_expenses_active_source_line")
                .contains("fixed_assets_source_shape_chk")
                .contains("deferred_expenses_source_shape_chk")
                .contains("ux_fixed_assets_active_source_line_normalized")
                .contains("ux_deferred_expenses_active_external_source_line_normalized")
                .contains("upper(btrim(source_type))")
                .contains("lower(btrim(source_line_ref))")
                .contains("ux_fixed_assets_active_asset_tag_normalized")
                .contains("object_type = 'DEFERRED_EXPENSE'\n                    OR accumulated_style_id IS NOT NULL");
    }

    @Test
    void createsEveryProfessionalLedgerAndWorkflowTable() throws IOException {
        String sql = sql();

        for (String table : List.of(
                "finance_asset_categories",
                "finance_asset_books",
                "finance_deferral_schedule_versions",
                "finance_deferral_schedule_lines",
                "finance_asset_approval_steps",
                "finance_asset_events",
                "finance_asset_accounting_periods",
                "finance_asset_posting_runs",
                "finance_asset_posting_lines")) {
            assertThat(sql).contains("CREATE TABLE " + table);
            assertThat(sql).contains("trg_audit_" + table);
        }

        assertThat(sql)
                .contains("fn_validate_deferral_schedule_approval")
                .contains("v_line.opening_balance <> v_previous_closing")
                .contains("v_line.accumulated_amount <> v_running_amount")
                .contains("v_previous_closing <> 0")
                .contains("trg_append_only_finance_asset_approval_steps")
                .contains("trg_append_only_finance_asset_events");
    }

    @Test
    void replacesDeleteAndRebuildWithIdempotentReversibleFacts() throws IOException {
        String sql = sql();

        assertThat(sql)
                .contains("DROP CONSTRAINT fa_depreciation_log_asset_id_period_key")
                .contains("DROP CONSTRAINT da_amortization_log_deferred_id_period_key")
                .contains("posting_run_id UUID NOT NULL")
                .contains("opening_balance NUMERIC(18,4) NOT NULL")
                .contains("closing_balance NUMERIC(18,4) NOT NULL")
                .contains("entry_kind VARCHAR(16) NOT NULL DEFAULT 'NORMAL'")
                .contains("ux_fa_depreciation_log_active_period")
                .contains("ux_da_amortization_log_active_period")
                .contains("ux_finance_asset_runs_single_effective_posted")
                .contains("idempotency_key VARCHAR(160)")
                .contains("reversal_of_voucher_id UUID REFERENCES gl_vouchers(id)")
                .contains("fn_guard_asset_owned_gl_voucher")
                .contains("fn_guard_asset_owned_gl_entry")
                .contains("BEFORE INSERT OR UPDATE OR DELETE ON gl_entries")
                .contains("TG_OP = 'INSERT' AND v_voucher_status = 0")
                .contains("OLD.status = 0")
                .contains("NEW.status = 1")
                .contains("fn_guard_finance_asset_ledger_fact");
    }

    @Test
    void grantsOnlyLowRiskDefaultsAndSeedsNoEnterprisePolicy() throws IOException {
        String sql = sql();

        assertThat(sql)
                .contains("'finance_asset:view'")
                .contains("'finance_asset:edit'")
                .contains("'finance_asset:approve'")
                .contains("'finance_asset:post'")
                .contains("'finance_asset:dispose'")
                .contains("'finance_asset:export'")
                .contains("'finance_asset_period:manage'")
                .contains("p.code IN ('finance_asset:view', 'finance_asset:edit')")
                .doesNotContain("INSERT INTO finance_asset_categories")
                .doesNotContain("5000000")
                .doesNotContain("default_salvage_rate       NUMERIC(9,6) DEFAULT");
    }

    @Test
    void closeAndPostingShapeAreDatabaseGuarded() throws IOException {
        String sql = sql();

        assertThat(sql)
                .contains("depreciation_run_id IS NOT NULL")
                .contains("amortization_run_id IS NOT NULL")
                .contains("reconciliation_difference = 0")
                .contains("approved_by <> submitted_by")
                .contains("posted_by <> submitted_by")
                .contains("ux_finance_asset_posting_lines_run_asset")
                .contains("ux_finance_asset_posting_lines_run_schedule_line")
                .contains("status = 'SKIPPED' AND message IS NOT NULL")
                .contains("object_type = 'FIXED_ASSET'")
                .contains("object_type = 'DEFERRED_EXPENSE'");
    }

    private static String sql() throws IOException {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8);
    }
}
