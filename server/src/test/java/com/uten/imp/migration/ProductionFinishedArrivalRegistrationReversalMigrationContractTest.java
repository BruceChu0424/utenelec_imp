package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V548 产成品送检登记撤回：只追加撤回记录、有效登记行/未取消 inspection 部分唯一、
 * 待登记视图统一口径、FQC 取消事件新原因与延迟完整性守卫（静态契约）。
 */
class ProductionFinishedArrivalRegistrationReversalMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V548__production_finished_arrival_registration_reversal.sql");

    @Test
    void v548AddsAppendOnlyReversalAndRelaxesLifetimeUniquenessToActiveRows()
            throws Exception {
        String sql = Files.readString(MIGRATION).toLowerCase();

        assertThat(sql)
                .contains("create table production_finished_arrival_registration_reversals")
                .contains("registration_id  uuid not null unique")
                .contains("length(reason) between 2 and 500")
                .contains("production_finished_arrival_reversal_actor_key_uk unique (\n        created_by, idempotency_key)")
                .contains("add column if not exists reversal_id uuid")
                .contains("production_finished_arrival_registration_item_active_uk")
                .contains("on production_finished_arrival_registration_items(source_report_item_id)\n    where reversal_id is null")
                .contains("production_fqc_inspection_active_report_item_uk")
                .contains("on production_fqc_inspections(source_report_item_id)\n    where status <> 'cancelled'")
                .contains("or con.conname = 'production_fqc_inspection_report_pair_uk'")
                .contains("idx_production_daily_report_items_goods_color")
                // 视图是唯一「未登记」口径。
                .contains("create or replace view v_production_report_items_pending_registration")
                .contains("and registered_item.reversal_id is null")
                .contains("and inspection.status <> 'cancelled'")
                .contains("from production_fqc_legacy_exemptions exemption")
                // 登记行守卫：INSERT 走视图；UPDATE 只允许撤回事务标记 reversal_id。
                .contains("from v_production_report_items_pending_registration pending")
                .contains("current_setting('app.production_finished_arrival_reversal_id', true)")
                .contains("(to_jsonb(new) - 'reversal_id')")
                // FQC 来源守卫只认有效登记行。
                .contains("and registration_item.reversal_id is null\n    join production_finished_arrival_registrations registration")
                // FQC 取消事件新原因与守卫。
                .contains("reason_code in ('source_report_reversed', 'registration_reversed')")
                .contains("if new.reason_code = 'registration_reversed' then")
                .contains("production_fqc_cancellation_registration_guard")
                .contains("from production_fqc_recovery_authorizations recovery_auth")
                // 撤回记录守卫/落地/延迟完整性 + 审计 + 清空策略。
                .contains("production_finished_arrival_reversal_command_guard")
                .contains("production_finished_arrival_reversal_state_guard")
                .contains("set reversal_id = new.id")
                .contains("production_finished_arrival_reversal_complete_guard")
                .contains("deferrable initially deferred")
                .contains("enable always trigger\n        trg_guard_production_finished_arrival_registration_reversals")
                .contains("create trigger trg_audit_production_finished_arrival_registration_reversals")
                .contains("(''production_finished_arrival_registration_reversals'', ''clear'')")
                // 不改写历史事实。
                .doesNotContain("update production_finished_arrival_registrations")
                .doesNotContain("update production_fqc_inspections")
                .doesNotContain("delete from")
                .doesNotContain("drop trigger trg_audit");
    }
}
