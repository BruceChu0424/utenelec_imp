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

    /** 去掉块注释与行注释后再找注解，避免 javadoc 里的 {@code @Scheduled} 误伤。 */
    private static String stripComments(String source) {
        return source
                .replaceAll("(?s)/\\*.*?\\*/", " ")
                .replaceAll("(?m)//.*$", " ");
    }

    private boolean containsScheduledMethod(Path source) {
        try {
            // 只认真正的注解使用：javadoc / 注释里提到 @Scheduled 的类（如
            // ScheduledTaskRunRegistry 这种「记录别人执行情况」的组件）不是调度组件，
            // 不该被要求挂 @Profile("!cloud")（2026-09-11）。
            return stripComments(Files.readString(source, StandardCharsets.UTF_8))
                    .contains("@Scheduled");
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
