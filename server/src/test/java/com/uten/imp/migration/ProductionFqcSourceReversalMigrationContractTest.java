package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcSourceReversalMigrationContractTest {

    @Test
    void reversalIsAppendOnlyAndRequiresNoActiveFinishedInbound()
            throws Exception {
        String sql = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V412__production_fqc_source_reversal.sql"));

        assertThat(sql)
                .contains("production_fqc_cancellation_events")
                .contains("'CANCELLED'")
                .contains("SOURCE_REPORT_REVERSED")
                .contains("report_status <> -1")
                .contains("item.source_daily_report_item_id")
                .contains("document.status <> -1")
                .contains("fn_guard_production_fqc_append_only")
                .contains("production_fqc_cancelled_release_guard")
                .doesNotContain("DELETE FROM production_fqc");
    }
}
