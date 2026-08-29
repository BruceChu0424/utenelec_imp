package com.uten.imp.config;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class MetricsUriTagBudgetContractTest {

    @Test
    void applicationBudgetCoversTheRouteCatalogWhileNormalizerBoundsDynamicIds()
            throws Exception {
        String yaml = Files.readString(
                Path.of("src/main/resources/application.yml"),
                StandardCharsets.UTF_8);
        String config = Files.readString(
                Path.of("src/main/java/com/uten/imp/config/MetricsConfig.java"),
                StandardCharsets.UTF_8);

        assertThat(yaml)
                .contains("max-uri-tags: ${UTEN_METRICS_MAX_URI_TAGS:1024}");
        assertThat(config)
                .contains("replaceAll(")
                .contains("\"/{id}\"");
    }
}
