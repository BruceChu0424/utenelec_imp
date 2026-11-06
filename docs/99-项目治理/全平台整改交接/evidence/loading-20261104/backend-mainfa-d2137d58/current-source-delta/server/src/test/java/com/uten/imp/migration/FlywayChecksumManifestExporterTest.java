package com.uten.imp.migration;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.flywaydb.core.api.Location;
import org.flywaydb.core.api.MigrationVersion;
import org.flywaydb.core.api.resource.LoadableResource;
import org.flywaydb.core.internal.resolver.ChecksumCalculator;
import org.flywaydb.core.internal.resource.classpath.ClassPathResource;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.math.BigInteger;
import java.net.URISyntaxException;
import java.net.URL;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.*;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_HEAD_VERSION;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT;

class FlywayChecksumManifestExporterTest {
    private static final String EXPORT_PROPERTY = "uten.exportFlywayChecksums";
    private static final String OUTPUT_NAME = "uten-imp-flyway-checksums.tsv";
    private static final String HEADER = "# uten-imp-flyway-checksums-v1";
    private static final Pattern MIGRATION_FILE = Pattern.compile(
            "V(?<version>[0-9]+(?:[._][0-9]+)*)__(?<description>[A-Za-z0-9_]+)\\.sql");
    private static final Pattern CANONICAL_VERSION = Pattern.compile(
            "[1-9][0-9]*(?:\\.(?:0|[1-9][0-9]*))*");

    static String canonicalVersion(Object value) {
        if (!(value instanceof String text) || !CANONICAL_VERSION.matcher(text).matches()
                || text.endsWith(".0")) {
            throw new IllegalArgumentException("Flyway version must be canonical ASCII component text");
        }
        return text;
    }

    static String versionFromFilename(String filename) {
        var match = MIGRATION_FILE.matcher(filename);
        if (!match.matches()) throw new IllegalArgumentException("Unexpected Flyway SQL filename: " + filename);
        String raw = match.group("version");
        // Retain the immutable V01..V09 integer filenames and the original TSV
        // identities 1..9. Compound filenames keep strict component spelling.
        if (!raw.contains("_") && !raw.contains(".")) return canonicalVersion(new BigInteger(raw).toString());
        return canonicalVersion(raw.replace('_', '.'));
    }

    static String rawVersionFromFilename(String filename) {
        versionFromFilename(filename); // Preserve the caller's existing filename qualification.
        var match = MIGRATION_FILE.matcher(filename);assertTrue(match.matches());
        return MigrationVersion.fromVersion(match.group("version")).getVersion();
    }

    static String validateHistoryVersion(Object raw, String filename) {
        if (!(raw instanceof String text) || !rawVersionFromFilename(filename).equals(text)) {
            throw new IllegalArgumentException("Installed raw version does not match the original script token");
        }
        return versionFromFilename(filename);
    }

    static String historyDescriptionFromFilename(String filename, String signedDescription) {
        versionFromFilename(filename);
        var match = MIGRATION_FILE.matcher(filename);assertTrue(match.matches());
        String declared = match.group("description");
        if (signedDescription != null && !declared.equals(signedDescription)) {
            throw new IllegalArgumentException("Signed description does not match original filename");
        }
        return declared.replace('_', ' ');
    }

    static BigInteger requireIntegerHead(List<String> versions) {
        Set<MigrationVersion> unique = new HashSet<>();
        for (String version : versions) {
            if (!unique.add(MigrationVersion.fromVersion(canonicalVersion(version)))) {
                throw new IllegalArgumentException("Duplicate canonical Flyway version");
            }
        }
        if (unique.isEmpty()) throw new IllegalArgumentException("Flyway inventory is empty");
        String head = unique.stream().max(MigrationVersion::compareTo).orElseThrow().toString();
        if (head.contains(".")) throw new IllegalArgumentException("Flyway receipt head must be an integer");
        return new BigInteger(head);
    }

    static String manifestContents(ClassLoader classLoader) throws IOException, URISyntaxException {
        URL migrationUrl = classLoader.getResource("db/migration");
        assertNotNull(migrationUrl, "compiled Flyway migration directory is missing");
        assertEquals("file", migrationUrl.getProtocol(), "checksum export requires compiled filesystem resources");
        List<MigrationChecksum> migrations = new ArrayList<>();
        Set<MigrationVersion> versions = new HashSet<>();
        try (var paths = Files.list(Path.of(migrationUrl.toURI()))) {
            for (Path migrationPath : paths.filter(Files::isRegularFile).toList()) {
                String filename = migrationPath.getFileName().toString();
                if (!filename.endsWith(".sql")) continue;
                MigrationVersion version = MigrationVersion.fromVersion(versionFromFilename(filename));
                assertTrue(versions.add(version), () -> "duplicate Flyway version: " + version);
                LoadableResource migration = new ClassPathResource(
                        Location.fromPath("classpath:", "db/migration"), "db/migration/" + filename,
                        classLoader, StandardCharsets.UTF_8);
                migrations.add(new MigrationChecksum(version, filename, ChecksumCalculator.calculate(migration)));
            }
        }
        migrations.sort(Comparator.comparing(MigrationChecksum::version));
        assertEquals(CURRENT_MIGRATION_COUNT, migrations.size(), "checksum inventory must cover every version");
        assertEquals(new BigInteger(CURRENT_HEAD_VERSION), requireIntegerHead(
                migrations.stream().map(m -> m.version().toString()).toList()), "unexpected exact integer head");
        StringBuilder output = new StringBuilder(32_768).append(HEADER).append('\n');
        for (MigrationChecksum migration : migrations) {
            output.append(migration.version()).append('\t').append(migration.filename())
                    .append('\t').append(migration.checksum()).append('\n');
        }
        return output.toString();
    }

    @Test void exportsCanonicalFlywayChecksumsOnlyWhenExplicitlyRequested() throws IOException, URISyntaxException {
        Assumptions.assumeTrue("true".equals(System.getProperty(EXPORT_PROPERTY)),
                () -> "Set -D" + EXPORT_PROPERTY + "=true only for an explicitly requested checksum export");
        String output = manifestContents(getClass().getClassLoader());
        Path testClasses = Path.of(getClass().getProtectionDomain().getCodeSource().getLocation().toURI());
        Path targetDirectory = testClasses.getParent();
        assertNotNull(targetDirectory, "cannot resolve Maven target directory");
        Path destination = targetDirectory.resolve(OUTPUT_NAME);
        Path temporary = Files.createTempFile(targetDirectory, "." + OUTPUT_NAME + ".", ".tmp");
        try {
            Files.writeString(temporary, output, StandardCharsets.UTF_8,
                    StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE);
            try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) { channel.force(true); }
            try {
                Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException failure) {
                throw new IOException("target filesystem cannot atomically publish checksum manifest", failure);
            }
        } finally { Files.deleteIfExists(temporary); }
        assertTrue(Files.isRegularFile(destination));
        assertEquals(output, Files.readString(destination, StandardCharsets.UTF_8));
    }

    @Test void canonicalVersionIdentityMatchesTheSharedPythonContract() throws Exception {
        var mapper = new ObjectMapper();
        try (var input = getClass().getClassLoader().getResourceAsStream("contracts/flyway-version-identity-v1.json")) {
            assertNotNull(input);
            var fixture = mapper.readTree(input);
            for (var sample : fixture.get("validVersions")) {
                String text = sample.get("text").textValue();
                assertEquals(text, canonicalVersion(text));
                assertEquals(text, MigrationVersion.fromVersion(text).toString());
                var actual = List.of(text.split("\\."));
                var expected = new ArrayList<String>();sample.get("parts").forEach(part -> expected.add(part.textValue()));
                assertEquals(expected, actual);
            }
            for (var sample : fixture.get("invalidVersions")) {
                Object value = mapper.convertValue(sample, Object.class);
                assertThrows(IllegalArgumentException.class, () -> canonicalVersion(value));
            }
            for (var sample : fixture.get("validFilenames")) {
                assertEquals(sample.get("canonical").textValue(), versionFromFilename(sample.get("file").textValue()));
            }
            for (var sample : fixture.get("invalidFilenames")) {
                assertThrows(IllegalArgumentException.class, () -> versionFromFilename(sample.textValue()));
            }
            for (var sample : fixture.get("validHistoryVersions")) {
                String file = sample.get("file").textValue();
                assertEquals(sample.get("raw").textValue(), rawVersionFromFilename(file));
                assertEquals(sample.get("canonical").textValue(), validateHistoryVersion(sample.get("raw").textValue(), file));
                assertEquals(sample.get("rawDescription").textValue(), historyDescriptionFromFilename(file, sample.get("manifestDescription").textValue()));
            }
            for (var sample : fixture.get("invalidHistoryVersions")) {
                assertThrows(IllegalArgumentException.class, () -> validateHistoryVersion(mapper.convertValue(sample.get("raw"), Object.class), sample.get("file").textValue()));
            }
            for (var sample : fixture.get("invalidSignedDescriptions")) {
                assertThrows(IllegalArgumentException.class, () -> historyDescriptionFromFilename(sample.get("file").textValue(), sample.get("signedDescription").textValue()));
            }
            var ordered = new ArrayList<String>();fixture.get("orderedVersions").forEach(v -> ordered.add(v.textValue()));
            var reverse = new ArrayList<>(ordered);java.util.Collections.reverse(reverse);
            reverse.sort(Comparator.comparing(MigrationVersion::fromVersion));assertEquals(ordered, reverse);
            for (var sample : fixture.get("integerHeadCases")) {
                var values = new ArrayList<String>();sample.get("versions").forEach(v -> values.add(v.textValue()));
                if (sample.path("reject").asBoolean()) assertThrows(IllegalArgumentException.class, () -> requireIntegerHead(values));
                else assertEquals(sample.get("head").bigIntegerValue(), requireIntegerHead(values));
            }
            for (var files : fixture.get("duplicateFilenameInventories")) {
                var values = new ArrayList<String>();files.forEach(v -> values.add(versionFromFilename(v.textValue())));
                values.add("1070"); // Isolate duplicate identity from the compound-head rejection.
                assertThrows(IllegalArgumentException.class, () -> requireIntegerHead(values));
            }
        }
    }

    private record MigrationChecksum(MigrationVersion version, String filename, int checksum) { }
}
