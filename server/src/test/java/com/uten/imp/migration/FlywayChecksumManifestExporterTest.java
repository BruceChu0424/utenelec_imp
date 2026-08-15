package com.uten.imp.migration;

import org.flywaydb.core.api.Location;
import org.flywaydb.core.api.resource.LoadableResource;
import org.flywaydb.core.internal.resolver.ChecksumCalculator;
import org.flywaydb.core.internal.resource.classpath.ClassPathResource;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
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
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_HEAD_VERSION;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT;

class FlywayChecksumManifestExporterTest {

    private static final String EXPORT_PROPERTY = "uten.exportFlywayChecksums";
    private static final String OUTPUT_NAME = "uten-imp-flyway-checksums.tsv";
    private static final String HEADER = "# uten-imp-flyway-checksums-v1";
    private static final Pattern MIGRATION_FILE = Pattern.compile(
            "^V(?<version>[0-9]+)__(?<description>[A-Za-z0-9_]+)\\.sql$");

    @Test
    void exportsCanonicalFlywayChecksumsOnlyWhenExplicitlyRequested()
            throws IOException, URISyntaxException {
        Assumptions.assumeTrue(
                "true".equals(System.getProperty(EXPORT_PROPERTY)),
                () -> "Set -D" + EXPORT_PROPERTY + "=true only in the signed-release CI job");

        ClassLoader classLoader = getClass().getClassLoader();
        URL migrationUrl = classLoader.getResource("db/migration");
        assertNotNull(migrationUrl, "compiled Flyway migration directory is missing");
        assertEquals("file", migrationUrl.getProtocol(),
                "checksum export must run from compiled filesystem resources, not a nested archive");

        Path migrationDirectory = Path.of(migrationUrl.toURI());
        List<MigrationChecksum> migrations = new ArrayList<>();
        Set<Integer> versions = new HashSet<>();
        try (var paths = Files.list(migrationDirectory)) {
            for (Path migrationPath : paths.filter(Files::isRegularFile).toList()) {
                String filename = migrationPath.getFileName().toString();
                if (!filename.endsWith(".sql")) {
                    continue;
                }
                Matcher matcher = MIGRATION_FILE.matcher(filename);
                assertTrue(matcher.matches(), () -> "unexpected Flyway SQL filename: " + filename);
                int version = Integer.parseInt(matcher.group("version"));
                assertTrue(versions.add(version), () -> "duplicate Flyway version: " + version);
                LoadableResource migration = new ClassPathResource(
                        new Location("classpath:db/migration"),
                        "db/migration/" + filename,
                        classLoader,
                        StandardCharsets.UTF_8);
                migrations.add(new MigrationChecksum(
                        version,
                        filename,
                        ChecksumCalculator.calculate(migration)));
            }
        }

        migrations.sort(Comparator.comparingInt(MigrationChecksum::version));
        assertEquals(CURRENT_MIGRATION_COUNT, migrations.size(),
                "signed-release checksum inventory must cover every versioned migration");
        assertEquals(Integer.parseInt(CURRENT_HEAD_VERSION), migrations.getLast().version(),
                "signed-release checksum inventory has an unexpected head version");

        StringBuilder output = new StringBuilder(32_768).append(HEADER).append('\n');
        for (MigrationChecksum migration : migrations) {
            output.append(migration.version())
                    .append('\t')
                    .append(migration.filename())
                    .append('\t')
                    .append(migration.checksum())
                    .append('\n');
        }

        Path testClasses = Path.of(
                getClass().getProtectionDomain().getCodeSource().getLocation().toURI());
        Path targetDirectory = testClasses.getParent();
        assertNotNull(targetDirectory, "cannot resolve Maven target directory");
        Path destination = targetDirectory.resolve(OUTPUT_NAME);
        Path temporary = Files.createTempFile(targetDirectory, "." + OUTPUT_NAME + ".", ".tmp");
        try {
            Files.writeString(
                    temporary,
                    output,
                    StandardCharsets.UTF_8,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE);
            try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                channel.force(true);
            }
            try {
                Files.move(
                        temporary,
                        destination,
                        StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException exception) {
                throw new IOException(
                        "target filesystem does not support atomic Flyway checksum manifest publication",
                        exception);
            }
        } finally {
            Files.deleteIfExists(temporary);
        }

        assertTrue(Files.isRegularFile(destination), "checksum manifest was not published");
        assertEquals(output.toString(), Files.readString(destination, StandardCharsets.UTF_8));
    }

    private record MigrationChecksum(int version, String filename, int checksum) {
    }
}
