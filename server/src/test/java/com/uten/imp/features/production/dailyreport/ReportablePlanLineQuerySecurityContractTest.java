package com.uten.imp.features.production.dailyreport;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ReportablePlanLineQuerySecurityContractTest {

    @Test
    void pickerOnlyExposesStartedSegmentsInsideProductionObjectScope()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ReportablePlanLineQueryService.java"));

        assertThat(source)
                .contains("segment.status = 'IN_PROGRESS'")
                .doesNotContain(
                        "segment.status IN ('DISPATCHED', 'IN_PROGRESS')")
                .contains("var readScope = access.scope()")
                .contains("p.maker_id IS NULL")
                .contains("p.maker_id IN (");
    }
}
