package com.uten.imp.config;

import org.junit.jupiter.api.Test;
import org.springframework.boot.env.YamlPropertySourceLoader;
import org.springframework.core.io.ClassPathResource;
import org.springframework.core.env.PropertySource;

import java.io.IOException;
import java.util.Arrays;
import java.util.Set;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

class HealthProbeConfigurationContractTest {

    @Test
    void livenessAvoidsDependencyRestartStormsWhileReadinessClosesTheEntry() throws IOException {
        for (String profile : new String[]{"prod", "cloud"}) {
            PropertySource<?> source = new YamlPropertySourceLoader()
                    .load("application-" + profile,
                            new ClassPathResource("application-" + profile + ".yml"))
                    .getFirst();

            assertThat(indicators(source, "liveness"))
                    .as(profile + " liveness group")
                    .containsExactly("livenessState");
            assertThat(indicators(source, "readiness"))
                    .as(profile + " readiness group")
                    .containsExactlyInAnyOrder(
                            "readinessState",
                            "db",
                            "diskSpace",
                            "attachmentSafety");
        }
    }

    private static Set<String> indicators(PropertySource<?> source, String group) {
        Object configured = source.getProperty(
                "management.endpoint.health.group." + group + ".include");
        assertThat(configured).as(group + " health group").isInstanceOf(String.class);
        return Arrays.stream(configured.toString().split(","))
                .map(String::trim)
                .filter(value -> !value.isEmpty())
                .collect(Collectors.toSet());
    }
}
