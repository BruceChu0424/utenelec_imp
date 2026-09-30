package com.uten.imp.support;

import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.platform.engine.discovery.DiscoverySelectors;
import org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder;
import org.junit.platform.launcher.core.LauncherFactory;

import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class BackendTestInventoryTest {
    @Test
    void temporaryFilesUseTheJvmStartupDirectory() throws Exception {
        Path expected = Path.of(System.getProperty("java.io.tmpdir")).toRealPath();
        Path created = Files.createTempDirectory("uten-inventory-temp-");
        try {
            // A late Surefire system-property update can disagree with the JDK's cached directory.
            assertThat(created.toRealPath().getParent()).isEqualTo(expected);
        } finally {
            Files.deleteIfExists(created);
        }
    }

    @Test
    @SuppressWarnings("unchecked")
    void discoversInheritedNestedParameterizedAndDynamicMethodsWithoutExecutingFixtures() {
        var request = LauncherDiscoveryRequestBuilder.request()
                .selectors(DiscoverySelectors.selectClass(DiscoveryFixture.class)).build();
        var rows = BackendTestInventory.describe(LauncherFactory.create().discover(request), "surefire");
        assertThat(rows).hasSize(1);
        assertThat(rows.getFirst().get("name")).isEqualTo(DiscoveryFixture.class.getName());
        var methods = (List<Map<String, Object>>) rows.getFirst().get("methods");
        assertThat(methods).extracting(row -> row.get("method"))
                .containsExactlyInAnyOrder("inherited", "plain", "parameters", "generated", "nested");
        assertThat(methods.stream().filter(row -> row.get("kind").equals("template")))
                .extracting(row -> row.get("method")).containsExactlyInAnyOrder("parameters", "generated");
        assertThat(methods.stream().filter(row -> row.get("method").equals("nested")).findFirst().orElseThrow().get("class"))
                .isEqualTo(DiscoveryFixture.Child.class.getName());
        assertThat(methods).allSatisfy(row -> assertThat((List<String>) row.get("environment_gates"))
                .contains("UTEN_RUN_DB_TESTS"));
        assertThat(methods.stream().filter(row -> row.get("method").equals("inherited")).findFirst().orElseThrow().get("id"))
                .isEqualTo(DiscoveryFixture.class.getName() + "#inherited");
        assertThat(methods).allSatisfy(row -> assertThat((List<Map<String, Object>>) row.get("system_property_gates"))
                .containsExactly(Map.of("named", "fixture.optional.workbook", "matches", ".+")));
        var nested = methods.stream().filter(row -> row.get("method").equals("nested")).findFirst().orElseThrow();
        assertThat((List<Map<String, Object>>) nested.get("enabled_on_os"))
                .containsExactly(Map.of("value", List.of("LINUX"), "architectures", List.of()));
        assertThat((List<Map<String, Object>>) methods.stream().filter(row -> row.get("method").equals("plain"))
                .findFirst().orElseThrow().get("enabled_on_os")).isEmpty();
    }

    // Not @Nested: Surefire excludes this fixture; discovery below is deliberately explicit.
    static class ParentFixture {
        @Test void inherited() { throw new AssertionError("Discovery must never execute tests"); }
    }

    @EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
    @EnabledIfSystemProperty(named = "fixture.optional.workbook", matches = ".+")
    static class DiscoveryFixture extends ParentFixture {
        DiscoveryFixture() { throw new AssertionError("Discovery must never construct fixtures"); }
        @Test void plain() { throw new AssertionError("not executed"); }
        @ParameterizedTest @ValueSource(ints = {1, 2})
        void parameters(int value) { throw new AssertionError("not executed"); }
        @TestFactory Stream<DynamicTest> generated() { throw new AssertionError("Factory must not run in discovery"); }
        @Nested class Child {
            @EnabledOnOs(OS.LINUX)
            @Test void nested() { throw new AssertionError("not executed"); }
        }
    }
}
