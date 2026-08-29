package com.uten.imp.common;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

class NativeSqlTextBlockWhitespaceContractTest {

    private static final Pattern RISKY_TOKEN_CONCATENATION = Pattern.compile(
            "\\b(?:AND|OR|WHERE|ON|HAVING)[ \\t]+\"\"\"[ \\t]*\\+");

    @Test
    void sqlKeywordsDoNotRelyOnTextBlockTrailingWhitespace() throws IOException {
        Path sourceRoot = sourceRoot();
        List<String> violations;
        try (Stream<Path> files = Files.walk(sourceRoot)) {
            violations = files
                    .filter(path -> path.toString().endsWith(".java"))
                    .filter(path -> RISKY_TOKEN_CONCATENATION
                            .matcher(read(path))
                            .find())
                    .map(path -> sourceRoot.relativize(path).toString())
                    .sorted()
                    .toList();
        }

        assertThat(violations)
                .as("Java text blocks strip trailing spaces; use a placeholder "
                        + "or an explicit separator before dynamic SQL")
                .isEmpty();
    }

    private static String read(Path path) {
        try {
            return Files.readString(path, StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new UncheckedIOException(error);
        }
    }

    private static Path sourceRoot() {
        Path moduleRelative = Path.of("src", "main", "java");
        if (Files.isDirectory(moduleRelative)) {
            return moduleRelative;
        }
        return Path.of("server", "src", "main", "java");
    }
}
