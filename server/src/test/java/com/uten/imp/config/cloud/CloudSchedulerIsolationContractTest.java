package com.uten.imp.config.cloud;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertTrue;

class CloudSchedulerIsolationContractTest {

    @Test
    void cloudProfileRunsOnlyThePrimaryHealthSchedule() throws IOException {
        Path sourceRoot = sourceRoot();
        List<Path> scheduledSources;
        try (var paths = Files.walk(sourceRoot)) {
            scheduledSources = paths
                    .filter(path -> path.toString().endsWith(".java"))
                    .filter(this::containsScheduledMethod)
                    .toList();
        }

        assertTrue(scheduledSources.size() >= 8, "expected all current scheduled components");
        for (Path source : scheduledSources) {
            String content = Files.readString(source, StandardCharsets.UTF_8);
            if (source.endsWith("PrimaryHealthIndicator.java")) {
                assertTrue(content.contains("@Profile(\"cloud\")"), source.toString());
            } else {
                assertTrue(content.contains("@Profile(\"!cloud\")"),
                        source + " must be disabled in the cloud profile");
            }
        }
    }

    private boolean containsScheduledMethod(Path source) {
        try {
            return Files.readString(source, StandardCharsets.UTF_8).contains("@Scheduled");
        } catch (IOException ex) {
            throw new IllegalStateException("Cannot read " + source, ex);
        }
    }

    private Path sourceRoot() {
        Path moduleRelative = Path.of("src", "main", "java");
        if (Files.isDirectory(moduleRelative)) {
            return moduleRelative;
        }
        return Path.of("server", "src", "main", "java");
    }
}
