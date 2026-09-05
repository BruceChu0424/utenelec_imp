package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFinishedArrivalPartialRegistrationMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V469__production_finished_arrival_partial_registration.sql");

    @Test
    void v469AllowsReportBatchesButKeepsExactLineAndAppendOnlyHistory()
            throws Exception {
        String sql = Files.readString(MIGRATION).toLowerCase();

        assertThat(sql)
                .contains("drop constraint\n        production_finished_arrival_registrations_source_report_id_key")
                .contains("idx_finished_arrival_registration_report_created")
                .contains("source_report_id, created_at desc, id desc")
                .contains("drop trigger trg_require_complete_production_finished_arrival")
                .contains("create or replace function fn_require_complete_production_finished_arrival()")
                .contains("not exists (\n           select 1\n           from production_finished_arrival_registration_items")
                .contains("finished arrival registration must contain exact report lines")
                .contains("deferrable initially deferred")
                .doesNotContain("update production_finished_arrival_registrations")
                .doesNotContain("update production_finished_arrival_registration_items")
                .doesNotContain("insert into production_finished_arrival_registrations")
                .doesNotContain("insert into production_finished_arrival_registration_items")
                .doesNotContain("drop constraint production_finished_arrival_registration_items")
                .doesNotContain("drop trigger trg_guard_production_finished_arrival_registration_items")
                .doesNotContain("drop trigger trg_audit_production_finished_arrival");
    }
}
