package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractLossClaimOutboxContractTest {
    @Test
    void openDecisionFulfillmentAndReverseAppendOutboxAfterBusinessEvents() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/payables/"
                        + "SubcontractLossClaimService.java"));

        assertThat(source)
                .contains("SUBCONTRACT_LOSS_CLAIM_OPENED")
                .contains("SUBCONTRACT_LOSS_CLAIM_DECIDED")
                .contains("SUBCONTRACT_LOSS_CLAIM_FULFILLED")
                .contains("SUBCONTRACT_LOSS_CLAIM_REVERSED")
                .contains("events.publishOnce(")
                .contains("appendEvent(caseId, \"DECIDED\", reason);")
                .contains("appendEvent(caseId, \"FULFILLED\", evidence);");
    }
}
