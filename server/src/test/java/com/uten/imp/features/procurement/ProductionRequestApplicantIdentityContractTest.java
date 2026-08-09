package com.uten.imp.features.procurement;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionRequestApplicantIdentityContractTest {

    @Test
    void everyProductionCallerPassesEmployeeIdentityAsApplicant() throws IOException {
        String execution = source(
                "features/production/mrp/ProductionExecutionPackageCommandService.java");
        assertThat(execution).containsSubsequence(
                "purchaseFacade.createProductionDraft(",
                "lines,",
                "currentUser.requireEmployeeId(),",
                "currentUser.requireEmployeeId());");

        String subcontract = source(
                "features/production/fulfillment/ProductionSubcontractApplicationCoordinator.java");
        assertThat(subcontract).containsSubsequence(
                "subcontractRequests.createProductionDraft(",
                "lines,",
                "currentUser.requireEmployeeId(),",
                "currentUser.requireEmployeeId());");
    }

    private static String source(String relativePath) throws IOException {
        return Files.readString(Path.of("src/main/java/com/uten/imp").resolve(relativePath));
    }
}
