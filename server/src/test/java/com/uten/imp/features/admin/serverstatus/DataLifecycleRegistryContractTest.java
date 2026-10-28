package com.uten.imp.features.admin.serverstatus;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 数据生命周期清册（V954）源码合同：
 * 每类数据的策略键、留存合同与维护任务登记齐全；两处仍按年龄硬删的个人暂态
 * （AI 确认卡/操作记忆）必须显式登记 EPHEMERAL_PERSONAL_STATE，不允许无清册删除。
 */
class DataLifecycleRegistryContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/V954__data_lifecycle_registry_and_task_run_evidence.sql");

    private static String migration() throws IOException {
        return Files.readString(MIGRATION);
    }

    @Test
    void registryCoversEveryRetentionContractAndCoreDataDomain() throws IOException {
        String sql = migration();
        for (String expected : new String[]{
                "'audit_online'", "'audit_archive'", "'business_outbox'",
                "'business_outbox_payload_history'", "'notices'", "'ai_jobs'",
                "'ai_input_originals'", "'ai_chat_action_proposals'",
                "'ai_chat_operation_memory'", "'sales_learning_receipts'",
                "'quote_template_candidates'", "'attachments'", "'upload_staging_scratch'",
                "'attachment_previews'", "'report_export_files'", "'refresh_tokens'",
                "'visitor_sms_codes'", "'business_record_history'", "'lifecycle_versions'",
                "'stock_flow_ledger'", "'stock_monthly_summaries'", "'party_monthly_summaries'",
                "'report_materialized_views'", "'reconciliation_findings'", "'client_drafts'",
                "'scheduled_task_runs'", "'data_lifecycle_policies'"}) {
            assertThat(sql).as("清册必须登记 %s", expected).contains(expected);
        }
        // 全部枚举合同值都在种子中出现（约束与种子一致）。
        for (String contract : new String[]{
                "'PERMANENT_RETAIN'", "'PERMANENT_RETAIN_TIERED'", "'SOFT_ARCHIVE'",
                "'EPHEMERAL_PERSONAL_STATE'", "'REGENERABLE_CACHE'", "'CREDENTIAL_LIFECYCLE'",
                "'TRANSIENT_IO'", "'REBUILDABLE_PROJECTION'"}) {
            assertThat(sql).contains(contract);
        }
    }

    @Test
    void ephemeralHardDeletesAreExplicitlyRegisteredNotSilent() throws IOException {
        String sql = migration();
        // 仍按年龄硬删的只有两处个人暂态, 且都在清册登记 EPHEMERAL_PERSONAL_STATE。
        // 种子行里合同值后紧跟无空格逗号; CHECK 约束枚举逗号后带空格, 以此区分。
        assertThat(countOccurrences(sql, "'EPHEMERAL_PERSONAL_STATE','")).isEqualTo(2);
        for (String key : new String[]{"ai_chat_action_proposals", "ai_chat_operation_memory"}) {
            int rowStart = sql.indexOf("('" + key + "'");
            assertThat(rowStart).as("清册缺少 %s", key).isGreaterThanOrEqualTo(0);
            int nextRow = sql.indexOf("\n ('", rowStart);
            String row = sql.substring(rowStart, nextRow < 0 ? sql.length() : nextRow);
            assertThat(row).contains("'EPHEMERAL_PERSONAL_STATE'");
        }
    }

    private static int countOccurrences(String text, String needle) {
        int count = 0;
        int index = 0;
        while ((index = text.indexOf(needle, index)) >= 0) {
            count++;
            index += needle.length();
        }
        return count;
    }

    @Test
    void taskRunEvidenceTableRegistersOnlyCompletionFacts() throws IOException {
        String sql = migration();
        assertThat(sql).contains("CREATE TABLE scheduled_task_runs");
        assertThat(sql).contains("CHECK (outcome IN ('SUCCESS', 'FAILURE'))");
        assertThat(sql).contains(
                "SELECT fn_audit_track_table('scheduled_task_runs','NONE','system',true)");
        assertThat(sql).contains(
                "SELECT fn_audit_track_table('data_lifecycle_policies','FULL','system',false)");
    }

    @Test
    void catalogDescriptionsMatchSoftArchiveReality() {
        // 目录文案不得再宣称“删除”已改为软归档的对象（V773/V778 行为）。
        var ai = ScheduledTaskCatalog.describe("AiJobHousekeeping.purge").orElseThrow();
        assertThat(ai.purpose()).contains("转入归档状态");
        assertThat(ai.purpose()).doesNotContain("调用记录删除").doesNotContain("任务与 180 天前的调用记录删除");
        var templates = ScheduledTaskCatalog.describe(
                "SalesQuoteTemplateCleanupScheduler.purgeExpired").orElseThrow();
        assertThat(templates.purpose()).contains("转入归档状态");
        var learning = ScheduledTaskCatalog.describe(
                "SalesLearningEvidenceCleanupScheduler.purgeExpiredEvidence").orElseThrow();
        assertThat(learning.purpose()).contains("转入归档状态");
        var audit = ScheduledTaskCatalog.describe(
                "AuditRetentionScheduler.runScheduled").orElseThrow();
        assertThat(audit.purpose()).contains("永久保留不销毁");
    }
}
