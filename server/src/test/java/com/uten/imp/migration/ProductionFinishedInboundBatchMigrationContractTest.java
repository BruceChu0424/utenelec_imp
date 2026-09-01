package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFinishedInboundBatchMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V434__production_finished_in_confirm_batches.sql");

    @Test
    void v434OwnsAppendOnlyAuditedBatchHeaderAndFrozenItems()
            throws Exception {
        String sql = Files.readString(MIGRATION).toLowerCase();

        assertThat(sql)
                .contains("create table production_finished_in_confirm_batches")
                .contains("create table production_finished_in_confirm_batch_items")
                .contains("unique (actor_user_id, idempotency_key)")
                .contains("request_hash          char(64) not null")
                .contains("response_snapshot     jsonb not null")
                .contains("confirmed_count between 1 and 50")
                .contains("confirmation_id       uuid not null unique")
                .contains("stock_document_id     uuid not null unique")
                .contains("bill_no_snapshot")
                .contains("status_snapshot = 1")
                .contains("fn_guard_production_finished_in_confirmation()")
                .contains("trg_audit_production_finished_in_confirm_batches")
                .contains("trg_audit_production_finished_in_confirm_batch_items")
                .doesNotContain("alter table production_finished_in_confirmations")
                .doesNotContain("update stock_documents");
    }
}
