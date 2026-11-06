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
    static String canonicalVersion(Object value) {
        if (!(value instanceof String text) || text.length()>50
                || !text.matches("(?:0|[1-9][0-9]*)(?:\\.(?:0|[1-9][0-9]*))*")
                || (text.contains(".") && text.endsWith(".0"))
                || MigrationVersion.fromVersion(text).compareTo(MigrationVersion.fromVersion("0"))<=0) {
            throw new IllegalArgumentException("Flyway version must be canonical positive component text");
        }
        return text;
    }

    static String versionFromFilename(String filename) {
        if (!MIGRATION_FILE.matcher(filename).matches()) {
            throw new IllegalArgumentException("Unexpected Flyway SQL filename: " + filename);
        }
        return MigrationRehearsalSupport.migrationVersionForScript(filename).getVersion();
    }

    static String rawVersionFromFilename(String filename) {
        String canonical=versionFromFilename(filename);
        var match=MIGRATION_FILE.matcher(filename);
        if(!match.matches()) throw new IllegalArgumentException("Unexpected Flyway SQL filename");
        return match.group("version").matches("0[1-9]") ? match.group("version") : canonical;
    }

    static String validateHistoryVersion(Object raw,String filename) {
        String canonical=versionFromFilename(filename);
        if(!(raw instanceof String text) || (!canonical.equals(text) && !rawVersionFromFilename(filename).equals(text))) {
            throw new IllegalArgumentException("Installed raw version does not match the exact script");
        }
        return canonical;
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
        assertEquals(MigrationVersion.fromVersion(CURRENT_HEAD_VERSION), migrations.getLast().version(), "unexpected exact semantic head");
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
        var mapper=new ObjectMapper();
        Path fixture=Path.of("../contracts/flyway-version/fixtures.json");
        if(!Files.isRegularFile(fixture)) fixture=Path.of("contracts/flyway-version/fixtures.json");
        var cases=mapper.readTree(Files.readString(fixture,StandardCharsets.UTF_8));
        var ordered=new ArrayList<String>();cases.get("canonicalOrder").forEach(v->{
            String value=v.textValue();assertEquals(value,canonicalVersion(value));ordered.add(value);
        });
        for(var invalid:cases.get("invalidCanonical")) {
            Object value=mapper.convertValue(invalid,Object.class);
            assertThrows(IllegalArgumentException.class,()->canonicalVersion(value));
        }
        var reversed=new ArrayList<>(ordered);java.util.Collections.reverse(reversed);
        reversed.sort(Comparator.comparing(MigrationVersion::fromVersion));assertEquals(ordered,reversed);
        for(var sample:cases.get("scripts")) {
            assertEquals(sample.get("version").textValue(),versionFromFilename(sample.get("file").textValue()));
            assertEquals(sample.get("flywayDescription").textValue(),historyDescriptionFromFilename(sample.get("file").textValue(),sample.get("rawDescription").textValue()));
        }
        for(var invalid:cases.get("invalidScripts")) assertThrows(IllegalArgumentException.class,()->versionFromFilename(invalid.textValue()),invalid.textValue());
        for(var sample:cases.get("legacyHistory")) {
            String file=sample.get("file").textValue();
            assertEquals(sample.get("canonical").textValue(),validateHistoryVersion(sample.get("raw").textValue(),file));
            assertEquals(sample.get("canonical").textValue(),validateHistoryVersion(sample.get("canonical").textValue(),file));
        }
        assertThrows(IllegalArgumentException.class,()->validateHistoryVersion("001","V01__enable_pgcrypto.sql"));
        assertThrows(IllegalArgumentException.class,()->validateHistoryVersion("01","V1__forged.sql"));
        assertThrows(IllegalArgumentException.class,()->historyDescriptionFromFilename("V999_1__first_decimal.sql","forged"));
        assertThrows(IllegalArgumentException.class,()->requireIntegerHead(List.of("999.1","999.1","1079")));
        assertThrows(IllegalArgumentException.class,()->requireIntegerHead(List.of("999.1")));
        assertEquals(new BigInteger("1079"),requireIntegerHead(List.of("999.10","1079")));
    }

    private record MigrationChecksum(MigrationVersion version, String filename, int checksum) { }
}
