package com.uten.imp.features.production.quality;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcFinishedInboundIntegrationContractTest {

    @Test
    void passCreatesDraftThenAllocatesExactQualifiedLot()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcInspectionService.java"));

        int create = source.indexOf(
                "finishedInbound.createReleasedDraft(");
        int allocate = source.indexOf(
                "allocateReleasedQuantity(",
                create);
        int publish = source.indexOf(
                "EVENT_RELEASED",
                allocate);
        assertThat(create).isGreaterThan(0);
        assertThat(allocate).isGreaterThan(create);
        assertThat(publish).isGreaterThan(allocate);
        assertThat(source)
                .contains("FQC-FINISHED-IN:")
                .contains("stockDocumentItemId()");
    }
}
