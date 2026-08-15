package com.uten.imp.config;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class InternalTestConfigurationContractTest {

    @Test
    void profilePinsTheProductionLikeRuntimeAndNvmeLocalStorage() throws IOException {
        String yaml = Files.readString(profileConfig(), StandardCharsets.UTF_8);

        assertTrue(yaml.contains("address: 127.0.0.1"));
        assertTrue(yaml.contains("lazy-initialization: false"));
        assertTrue(yaml.contains("url: ${UTEN_DB_URL}"));
        assertTrue(yaml.contains("username: ${UTEN_DB_USER}"));
        assertTrue(yaml.contains("password: ${UTEN_DB_PASSWORD}"));
        assertTrue(yaml.contains("local-allowed-cidrs: ${UTEN_LOCAL_ALLOWED_CIDRS}"));
        assertTrue(yaml.contains("cors-allowed-origins: ${UTEN_CORS_ORIGINS}"));
        assertTrue(yaml.contains("require-https: true"));
        assertTrue(yaml.contains("swagger-enabled: false"));
        assertTrue(yaml.contains("provider: local"));
        assertTrue(yaml.contains("uploads-enabled: false"));
        assertTrue(yaml.contains("local-dir: /data/uten-imp/attachments"));
        assertTrue(yaml.contains("path: /data"));
        assertTrue(yaml.contains("threshold: 10GB"));
        assertTrue(yaml.contains("enabled: false"));
        assertFalse(yaml.contains("UTEN_STORAGE_LOCAL_DIR"));
        assertFalse(yaml.contains("UTEN_OSS_"));
    }

    @Test
    void productionProfilesStillRequireOss() throws IOException {
        String production = Files.readString(productionConfig(), StandardCharsets.UTF_8);
        String cloud = Files.readString(cloudConfig(), StandardCharsets.UTF_8);

        assertTrue(production.contains("provider: ${UTEN_STORAGE_PROVIDER:oss}"));
        assertTrue(production.contains("require-versioning: ${UTEN_OSS_REQUIRE_VERSIONING:true}"));
        assertTrue(cloud.contains("provider: ${UTEN_STORAGE_PROVIDER:oss}"));
        assertTrue(cloud.contains("require-versioning: ${UTEN_OSS_REQUIRE_VERSIONING:true}"));
    }

    private static Path profileConfig() {
        return resource("application-internal-test.yml");
    }

    private static Path productionConfig() {
        return resource("application-prod.yml");
    }

    private static Path cloudConfig() {
        return resource("application-cloud.yml");
    }

    private static Path resource(String name) {
        Path moduleRelative = Path.of("src", "main", "resources", name);
        if (Files.isRegularFile(moduleRelative)) {
            return moduleRelative;
        }
        return Path.of("server", "src", "main", "resources", name);
    }
}
