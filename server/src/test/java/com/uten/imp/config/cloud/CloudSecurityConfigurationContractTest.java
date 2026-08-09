package com.uten.imp.config.cloud;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

class CloudSecurityConfigurationContractTest {

    @Test
    void cloudProfileKeepsProductionSecurityDefaultsExplicit() throws IOException {
        String yaml = Files.readString(cloudConfig(), StandardCharsets.UTF_8);

        assertTrue(yaml.contains("address: ${UTEN_SERVER_ADDRESS:127.0.0.1}"));
        assertTrue(yaml.contains("port: ${UTEN_SERVER_PORT:8080}"));
        assertTrue(yaml.contains("${UTEN_TRUSTED_PROXY_REGEX:127\\..*|::1}"));
        assertTrue(yaml.contains("issuer: ${UTEN_JWT_ISSUER}"));
        assertTrue(yaml.contains("cors-allowed-origins: ${UTEN_CORS_ORIGINS}"));
        assertTrue(yaml.contains("require-https: ${UTEN_REQUIRE_HTTPS:true}"));
        assertTrue(yaml.contains("swagger-enabled: false"));
        assertTrue(yaml.contains("api-docs:"));
        assertTrue(yaml.contains("swagger-ui:"));

        String productionYaml = Files.readString(productionConfig(), StandardCharsets.UTF_8);
        assertTrue(productionYaml.contains("${UTEN_TRUSTED_PROXY_REGEX:127\\..*|::1}"));
    }

    private Path cloudConfig() {
        Path moduleRelative = Path.of("src", "main", "resources", "application-cloud.yml");
        if (Files.isRegularFile(moduleRelative)) {
            return moduleRelative;
        }
        return Path.of("server", "src", "main", "resources", "application-cloud.yml");
    }

    private Path productionConfig() {
        Path moduleRelative = Path.of("src", "main", "resources", "application-prod.yml");
        if (Files.isRegularFile(moduleRelative)) {
            return moduleRelative;
        }
        return Path.of("server", "src", "main", "resources", "application-prod.yml");
    }
}
