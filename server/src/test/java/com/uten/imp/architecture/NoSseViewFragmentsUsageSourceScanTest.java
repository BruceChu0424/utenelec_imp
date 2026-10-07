package com.uten.imp.architecture;

import com.uten.imp.UtenImpApplication;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Keeps the time-limited GHSA-j9f9-w8pj-32f8 / CVE-2026-47890 non-applicability
 * assessment true. The dependency is not patched: our JSON-only application has
 * neither SSE endpoints nor view fragments. Introducing either requires reviewing
 * the exception against https://spring.io/security/cve-2026-47890/ first.
 */
class NoSseViewFragmentsUsageSourceScanTest {
    private static final List<String> MARKERS = List.of(
            "sseemitter", "serversentevent", "fragmentsrendering", "renderingresponse",
            "modelandview", "responsebodyemitter", "streamingresponsebody",
            "text/event-stream", "text_event_stream");
    private static final Set<String> TEXT_EXTENSIONS = Set.of(
            "java", "yml", "yaml", "properties", "xml", "json", "html", "htm",
            "ftl", "mustache", "jsp", "jspx", "js");

    @Test
    void productionSourcesResourcesAndCompiledClassesHaveNoSseOrViewFragments() throws Exception {
        Path classes = Path.of(UtenImpApplication.class.getProtectionDomain()
                .getCodeSource().getLocation().toURI());
        assertThat(Files.isDirectory(classes)).as("actual production class output").isTrue();
        for (Path root : List.of(Path.of("src/main/java"), Path.of("src/main/resources"), classes)) {
            assertThat(Files.isDirectory(root)).as("required production input %s", root).isTrue();
            try (Stream<Path> files = Files.walk(root)) {
                List<Path> offenders = files.filter(Files::isRegularFile)
                        .filter(NoSseViewFragmentsUsageSourceScanTest::usesSseOrViewFragments)
                        .toList();
                assertThat(offenders).as("SSE/view use requires reassessing CVE-2026-47890 under %s", root)
                        .isEmpty();
            }
        }
        try (Stream<Path> files = Files.walk(classes)) {
            assertThat(files.anyMatch(path -> path.toString().endsWith(".class")))
                    .as("the compiled-code guard must not silently scan an empty output").isTrue();
        }
    }

    @Test
    void rejectsFutureSourceAndResourceEntrypoints(@TempDir Path root) throws IOException {
        List<String> forbidden = List.of(
                "SseEmitter stream;", "ServerSentEvent<String> event;",
                "FragmentsRendering fragments;", "RenderingResponse response;",
                "ModelAndView fragment;", "ResponseBodyEmitter response;",
                "StreamingResponseBody response;", "produces = MediaType.TEXT_EVENT_STREAM_VALUE",
                "media-type: text/event-stream", "ServerResponse . sse(builder -> {});",
                "import static org.springframework.web.servlet.function.ServerResponse.sse;");
        for (String extension : List.of("java", "yml", "xml", "html", "properties", "json")) {
            Path file = root.resolve("future." + extension);
            for (String text : forbidden) {
                Files.writeString(file, text, StandardCharsets.UTF_8);
                assertThat(usesSseOrViewFragments(file)).as("%s: %s", extension, text).isTrue();
            }
            Files.writeString(file, "application/json", StandardCharsets.UTF_8);
            assertThat(usesSseOrViewFragments(file)).isFalse();
        }
    }

    @Test
    void rejectsActualCompiledTypesReflectionNamesAndFunctionalSse() throws IOException {
        for (Class<?> fixture : List.of(SseTypeFixture.class, ReflectionNameFixture.class, FunctionalSseFixture.class)) {
            try (var stream = fixture.getResourceAsStream(fixture.getSimpleName() + ".class")) {
                // Nested classes use their binary name, not their simple name.
                byte[] bytes;
                if (stream != null) {
                    bytes = stream.readAllBytes();
                } else {
                    String resource = "/" + fixture.getName().replace('.', '/') + ".class";
                    try (var binary = fixture.getResourceAsStream(resource)) {
                        assertThat(binary).as(resource).isNotNull();
                        bytes = binary.readAllBytes();
                    }
                }
                assertThat(forbiddenConstants(classConstants(bytes))).as(fixture.getSimpleName()).isTrue();
            }
        }
    }

    private static boolean usesSseOrViewFragments(Path file) {
        String name = file.getFileName().toString().toLowerCase(Locale.ROOT);
        try {
            if (name.endsWith(".class")) return forbiddenConstants(classConstants(Files.readAllBytes(file)));
            int dot = name.lastIndexOf('.');
            if (dot < 0 || !TEXT_EXTENSIONS.contains(name.substring(dot + 1))) return false;
            return forbiddenText(Files.readString(file, StandardCharsets.UTF_8));
        } catch (IOException unreadable) {
            throw new IllegalStateException("Cannot inspect production file " + file, unreadable);
        }
    }

    private static boolean forbiddenText(String text) {
        String normalized = text.toLowerCase(Locale.ROOT);
        return MARKERS.stream().anyMatch(normalized::contains)
                || normalized.replaceAll("\\s+", "").contains("serverresponse.sse");
    }

    private static boolean forbiddenConstants(List<String> constants) {
        return constants.stream().anyMatch(NoSseViewFragmentsUsageSourceScanTest::forbiddenText)
                || (constants.contains("org/springframework/web/servlet/function/ServerResponse")
                    && constants.contains("sse"));
    }

    /** Read real JVM UTF-8 constants, including descriptors and folded reflection strings. */
    private static List<String> classConstants(byte[] bytes) throws IOException {
        try (var input = new DataInputStream(new ByteArrayInputStream(bytes))) {
            if (input.readInt() != 0xCAFEBABE) throw new IOException("Not a class file");
            input.skipNBytes(4); // minor and major version
            int count = input.readUnsignedShort();
            List<String> constants = new ArrayList<>();
            for (int index = 1; index < count; index++) {
                switch (input.readUnsignedByte()) {
                    case 1 -> constants.add(input.readUTF());
                    case 3, 4, 9, 10, 11, 12, 17, 18 -> input.skipNBytes(4);
                    case 5, 6 -> { input.skipNBytes(8); index++; }
                    case 7, 8, 16, 19, 20 -> input.skipNBytes(2);
                    case 15 -> input.skipNBytes(3);
                    default -> throw new IOException("Unknown class constant tag");
                }
            }
            return constants;
        }
    }

    private static final class SseTypeFixture {
        org.springframework.web.servlet.mvc.method.annotation.SseEmitter emitter;
    }

    private static final class ReflectionNameFixture {
        final String type = "org.springframework.web.servlet.mvc.method.annotation." + "Sse\u0045mitter";
    }

    private static final class FunctionalSseFixture {
        Object response() {
            return org.springframework.web.servlet.function.ServerResponse.sse(builder -> {});
        }
    }
}
