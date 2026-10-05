package com.uten.imp.ops;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.assertj.core.api.Assertions.assertThat;

/** The operator wrapper adds offline checks, never a second destructive implementation. */
class ResetBusinessDataScriptContractTest {
    private String sql;
    @BeforeEach void loadScript() throws Exception {
        Path direct=Path.of("ops/reset_business_data.sql");
        sql=Files.readString(Files.exists(direct)?direct:Path.of("server/ops/reset_business_data.sql"),StandardCharsets.UTF_8);
    }

    @Test void offlineResetRequiresExactIdentityAndNoOtherApplicationConnection() {
        assertThat(sql).startsWith("\\set ON_ERROR_STOP on")
                .contains("confirm=CLEAR_BUSINESS","expected_database","expected_system_identifier",
                        "pg_control_system()","pg_stat_activity","pid <> pg_backend_pid()",
                        "backend_type = 'client backend'","current_database() IS DISTINCT FROM",
                        "actual_system_identifier IS DISTINCT FROM","applied_max_version<784",
                        "public.fn_business_test_reset_active()");
        assertThat(sql.indexOf("END $offline_identity$;")).isLessThan(sql.indexOf("SELECT * FROM public.business_data_reset();"));
    }

    @Test void everyTableStillMatchesTheIndependentReviewedPolicy() throws Exception {
        var policy=BusinessDataResetSqlContractTest.policy(sql);
        assertThat(policy).containsExactlyInAnyOrderEntriesOf(BusinessDataResetSqlContractTest.expectedCurrentPolicy());
        assertThat(policy).containsEntry("goods","PRESERVE").containsEntry("employees","PRESERVE")
                .containsEntry("users","PRESERVE").containsEntry("platform_column_definitions","PRESERVE")
                .containsEntry("platform_record_fields","PRESERVE").containsEntry("business_record_retention_registry","PRESERVE")
                .containsEntry("sales_orders","CLEAR").containsEntry("business_record_history","CLEAR")
                .containsEntry("business_record_identities","CLEAR").containsEntry("platform_record_field_versions","CLEAR")
                .containsEntry("platform_column_usage","CLEAR").containsEntry("ai_jobs","CLEAR")
                .containsEntry("ai_input_originals","CLEAR").containsEntry("ai_input_original_bindings","CLEAR")
                .containsEntry("sales_quote_template_candidate_history","CLEAR")
                .containsEntry("subcontract_draw_notice_marks","CLEAR")
                .doesNotContainKeys("preplan_subcontract_make_tasks","subcontract_outbound_preparation_commands");
    }

    @Test void installedAndExecutedPolicyAreBothComparedInsideTheResetTransaction() {
        int begin=sql.indexOf("\nBEGIN;");
        int installed=sql.indexOf("DO $review_installed_policy$");
        int call=sql.indexOf("SELECT * FROM public.business_data_reset();");
        int actual=sql.indexOf("DO $review_executed_policy$");
        int commit=sql.indexOf("\nCOMMIT;");
        assertThat(begin).isNotNegative();assertThat(installed).isGreaterThan(begin);
        assertThat(call).isGreaterThan(installed);assertThat(actual).isGreaterThan(call);
        assertThat(commit).isGreaterThan(actual);
        assertThat(sql).contains("pg_get_functiondef('public.business_data_reset()'::regprocedure)",
                "FULL JOIN installed USING(table_name)",
                "FULL JOIN reset_business_table_policy actual USING(table_name)",
                "expected.disposition IS DISTINCT FROM installed.disposition",
                "expected.disposition IS DISTINCT FROM actual.disposition","HAVING count(*)<>1");
    }

    @Test void scriptCannotSilentlyDevelopAnotherTruncateOrMasterZeroingPath() {
        String executable=sql.replaceAll("(?m)--.*$","").replaceAll("(?s)/\\*.*?\\*/","");
        assertThat(executable.toUpperCase()).doesNotContain("TRUNCATE","UPDATE ACCOUNTS","UPDATE GOODS",
                "REFRESH MATERIALIZED VIEW","DISABLE TRIGGER","CASCADE");
        assertThat(executable.split("SELECT \\* FROM public\\.business_data_reset\\(\\);",-1)).hasSize(2);
    }

    @Test void operatorCompletionReceiptCommitsAtomicallyWithTheSameResult() {
        int call=sql.indexOf("SELECT * FROM public.business_data_reset();");
        int receipt=sql.indexOf("INSERT INTO public.audit_log");
        assertThat(receipt).isGreaterThan(call).isLessThan(sql.indexOf("\nCOMMIT;"));
        assertThat(sql).contains("'app.actor_account'","'ops:reset_business_data'","'app.audit_request_id'",
                "gen_random_uuid()::text","'business_data_reset','system_test'","FROM reset_business_operator_result;",
                "authorization_epoch_after");
    }
}
