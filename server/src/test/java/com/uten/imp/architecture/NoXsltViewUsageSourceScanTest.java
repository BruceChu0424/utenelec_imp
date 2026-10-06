package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Keeps the OSV exception for GHSA-pc63-qcmh-9cmg (CVE-2026-47884, Spring MVC XsltView path limitation)
 * true: the server only serves JSON and never renders XSLT views. Spring 6.2.x has no open-source fix
 * (only 7.0.9), so the advisory is accepted in osv-scanner.toml with an expiry date; the moment any
 * source or resource starts using XSLT views this test fails and the exception has to be revisited.
 */
class NoXsltViewUsageSourceScanTest {

    private static final List<Path> ROOTS = List.of(Path.of("src/main/java"), Path.of("src/main/resources"));

    @Test
    void serverNeverUsesXsltViews() throws IOException {
        for (Path root : ROOTS) {
            try (Stream<Path> files = Files.walk(root)) {
                List<Path> offenders = files.filter(Files::isRegularFile)
                        .filter(NoXsltViewUsageSourceScanTest::usesXslt)
                        .toList();
                assertThat(offenders).as("XSLT views/templates under %s", root).isEmpty();
            }
        }
    }

    private static boolean usesXslt(Path file) {
        String name = file.getFileName().toString().toLowerCase(Locale.ROOT);
        if (name.endsWith(".xsl") || name.endsWith(".xslt")) {
            return true;
        }
        if (!name.endsWith(".java") && !name.endsWith(".yml") && !name.endsWith(".yaml")
                && !name.endsWith(".properties")) {
            return false;
        }
        try {
            String text = Files.readString(file, StandardCharsets.UTF_8).toLowerCase(Locale.ROOT);
            return text.contains("xsltview") || text.contains("servlet.view.xslt");
        } catch (IOException unreadable) {
            throw new IllegalStateException("Cannot read " + file, unreadable);
        }
    }
}
