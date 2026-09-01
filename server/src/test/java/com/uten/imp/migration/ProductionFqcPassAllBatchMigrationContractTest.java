package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcPassAllBatchMigrationContractTest {

    @Test
    void v432CreatesImmutableActorScopedBatchResultLedger()
            throws Exception {
        String sql = Files.readString(Path.of(
                        "src/main/resources/db/migration/"
                                + "V432__production_fqc_pass_all_batches.sql"))
                .toLowerCase();

        assertThat(sql)
                .contains("create table production_fqc_pass_all_batches")
                .contains("create table production_fqc_pass_all_batch_items")
                .contains("unique (\n        created_by, idempotency_key)")
                .contains("request_hash")
                .contains("inspection_count between 1 and 100")
                .contains("foreign key (inspection_id, decision_event_id)")
                .contains("references production_fqc_decision_events(inspection_id, id)")
                .contains("unique (\n        decision_event_id)")
                .contains("deferrable initially deferred")
                .contains("production_fqc_pass_all_batch_total_guard")
                .contains("fn_guard_production_fqc_append_only()")
                .contains("enable always trigger")
                .contains("trg_audit_production_fqc_pass_all_batches")
                .contains("trg_audit_production_fqc_pass_all_batch_items");
    }
}
