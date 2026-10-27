package com.uten.imp.support;

import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.platform.engine.discovery.DiscoverySelectors;
import org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder;
import org.junit.platform.launcher.core.LauncherFactory;
import org.junit.platform.launcher.listeners.SummaryGeneratingListener;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Executes the actual Jupiter condition in a fresh environment, without a database. */
class DatabaseTestGateContractTest {
    private static int fixtureStarts;

    @ParameterizedTest
    @ValueSource(strings = {"false", "0", "true", "TRUE"})
    void inheritedGateKeepsDiscoveryCompleteAndOnlyStartsApprovedFixtures(String enabled) throws Exception {
        check(enabled, "true".equalsIgnoreCase(enabled));
    }

    @Test
    void missingOptInNeverStartsTheInheritedFixture() throws Exception {
        check(null, false);
    }

    private static void check(String enabled, boolean expectedEnabled) throws Exception {
        String executable = System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java";
        var builder = new ProcessBuilder(Path.of(System.getProperty("java.home"), "bin", executable).toString(),
                "-cp", System.getProperty("java.class.path"), ProbeMain.class.getName());
        builder.redirectErrorStream(true);
        if (enabled == null) {
            builder.environment().remove("UTEN_RUN_DB_TESTS");
        } else {
            builder.environment().put("UTEN_RUN_DB_TESTS", enabled);
        }
        Process process = builder.start();
        if (!process.waitFor(45, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new IllegalStateException("Isolated Jupiter database gate probe timed out");
        }
        final String output;
        try (var input = process.getInputStream()) {
            output = new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
        assertEquals(0, process.exitValue(), output);
        var result = Pattern.compile("GATE found=(\\d+) started=(\\d+) fixtures=(\\d+) failed=(\\d+)").matcher(output);
        assertTrue(result.find(), output);
        assertEquals("2", result.group(1), "The full DB inventory must still discover both tests");
        assertEquals(expectedEnabled ? "2" : "0", result.group(2), output);
        assertEquals(expectedEnabled ? "1" : "0", result.group(3), output);
        assertEquals("0", result.group(4), output);
    }

    @RequiresDatabaseTests
    abstract static class GatedBase {
        @BeforeAll static void databaseFixture() {
            fixtureStarts++;
        }
    }

    static class InheritedProbe extends GatedBase {
        @Test void firstDatabaseTest() {}
        @Test void secondDatabaseTest() {}
    }

    public static final class ProbeMain {
        private ProbeMain() {}
        public static void main(String[] arguments) {
            var listener = new SummaryGeneratingListener();
            Class<?> selected = arguments.length == 0 ? InheritedProbe.class : DatabaseTestGateContractTest.class;
            var request = LauncherDiscoveryRequestBuilder.request().selectors(DiscoverySelectors.selectClass(selected)).build();
            try (var session = LauncherFactory.openSession()) {
                session.getLauncher().execute(request, listener);
            }
            var summary = listener.getSummary();
            System.out.printf("GATE found=%d started=%d fixtures=%d failed=%d%n", summary.getTestsFoundCount(),
                    summary.getTestsStartedCount(), fixtureStarts, summary.getTestsFailedCount());
            summary.printFailuresTo(new PrintWriter(System.out, true));
            if (summary.getTestsFailedCount() != 0) {
                throw new IllegalStateException("Isolated Jupiter database gate contract failed");
            }
        }
    }
}
