package com.uten.imp.config;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SpringDocProfileConfigurationContractTest {

    @Test
    void baseFailsClosedAndDevelopmentExplicitlyOptsIn() throws IOException {
        String base = read("application.yml");
        String development = read("application-dev.yml");

        assertThat(base).contains("""
                springdoc:
                  api-docs:
                    enabled: false
                  swagger-ui:
                    enabled: false
                    path: /swagger-ui.html
                """);
        assertThat(development).contains("""
                springdoc:
                  api-docs:
                    enabled: ${UTEN_SWAGGER_ENABLED:true}
                  swagger-ui:
                    enabled: ${UTEN_SWAGGER_ENABLED:true}
                """);
    }

    private static String read(String name) throws IOException {
        Path moduleRelative = Path.of("src", "main", "resources", name);
        Path path = Files.isRegularFile(moduleRelative)
                ? moduleRelative
                : Path.of("server", "src", "main", "resources", name);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
