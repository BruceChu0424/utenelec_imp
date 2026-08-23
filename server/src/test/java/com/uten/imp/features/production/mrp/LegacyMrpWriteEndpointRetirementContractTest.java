package com.uten.imp.features.production.mrp;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class LegacyMrpWriteEndpointRetirementContractTest {

    @Test
    void manualDrawAndFinishedInboundEndpointsStayRetired() throws Exception {
        String controller = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/mrp/MrpController.java"),
                StandardCharsets.UTF_8);
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/mrp/MrpService.java"),
                StandardCharsets.UTF_8);

        assertThat(controller)
                .doesNotContain("/mrp/generate-draw")
                .doesNotContain("/mrp/generate-finished-in")
                .doesNotContain("GenerateDrawBody");
        assertThat(service)
                .doesNotContain("generateDraw(")
                .doesNotContain("generateFinishedIn(");
    }
}
