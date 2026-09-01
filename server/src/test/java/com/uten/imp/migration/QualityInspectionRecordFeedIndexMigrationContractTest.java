package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class QualityInspectionRecordFeedIndexMigrationContractTest {

    @Test
    void v444AddsReadOnlyNewestFirstIndexesWithoutDuplicatingFacts()
            throws Exception {
        String sql = Files.readString(Path.of(
                        "src/main/resources/db/migration/"
                                + "V444__quality_inspection_record_feed_indexes.sql"))
                .toLowerCase();

        assertThat(sql)
                .contains("idx_procurement_inspection_events_record_feed")
                .contains("on procurement_inspection_events (occurred_at desc, id desc)")
                .contains("where action in ('pass', 'fail', 'receipt_reversed')")
                .contains("idx_production_fqc_decision_events_record_feed")
                .contains("on production_fqc_decision_events (decided_at desc, id desc)")
                .contains("idx_production_fqc_cancellation_events_record_feed")
                .contains("on production_fqc_cancellation_events (created_at desc, id desc)")
                .doesNotContain("create table")
                .doesNotContain("update ")
                .doesNotContain("delete ");
    }
}
