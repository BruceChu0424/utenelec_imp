package com.uten.imp.packaging;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.jar.Attributes;
import java.util.jar.JarFile;
import java.util.zip.ZipEntry;

import static org.assertj.core.api.Assertions.assertThat;

class ServerJarPackagingIT {

    private static final String APPLICATION_JAR_PROPERTY = "uten.packaging.application-jar";
    private static final String MIGRATOR_JAR_PROPERTY = "uten.packaging.migrator-jar";
    private static final String MIGRATION_SOURCE_PROPERTY = "uten.packaging.migration-source";

    @Test
    void executableApplicationAndStandaloneMigratorKeepSeparateDependencyLayouts() throws IOException {
        Path applicationJar = configuredPath(APPLICATION_JAR_PROPERTY);
        Path migratorJar = configuredPath(MIGRATOR_JAR_PROPERTY);
        Path migrationSource = configuredPath(MIGRATION_SOURCE_PROPERTY);

        assertThat(applicationJar).isRegularFile();
        assertThat(migratorJar).isRegularFile();
        assertThat(migrationSource).isDirectory();

        try (JarFile jar = new JarFile(applicationJar.toFile())) {
            List<String> entries = entryNames(jar);
            assertThat(entries)
                    .contains("BOOT-INF/classes/com/uten/imp/UtenImpApplication.class")
                    .noneMatch(name -> name.startsWith("BOOT-INF/classes/org/postgresql/"));
            List<String> postgresDrivers = entries.stream()
                    .filter(name -> name.matches("BOOT-INF/lib/postgresql-[^/]+\\.jar"))
                    .toList();
            assertThat(postgresDrivers).hasSize(1);
        }

        List<String> expectedMigrations;
        try (var files = Files.list(migrationSource)) {
            expectedMigrations = files
                    .filter(Files::isRegularFile)
                    .map(path -> path.getFileName().toString())
                    .filter(name -> name.endsWith(".sql"))
                    .map(name -> "db/migration/" + name)
                    .sorted()
                    .toList();
        }

        try (JarFile jar = new JarFile(migratorJar.toFile())) {
            assertThat(jar.getManifest()).isNotNull();
            assertThat(jar.getManifest().getMainAttributes().getValue(Attributes.Name.MAIN_CLASS))
                    .isEqualTo("com.uten.imp.migration.UtenImpMigrator");

            List<String> entries = entryNames(jar);
            assertThat(entries)
                    .contains(
                            "com/uten/imp/migration/UtenImpMigrator.class",
                            "com/uten/imp/migration/AppliedMigrationCompatibilityCallback.class",
                            "org/postgresql/util/LazyCleaner.class")
                    .noneMatch(name -> name.startsWith("BOOT-INF/"))
                    .noneMatch(name -> name.startsWith("org/springframework/"));
            assertThat(entries.stream()
                    .filter(name -> name.startsWith("db/migration/") && name.endsWith(".sql"))
                    .sorted()
                    .toList())
                    .containsExactlyElementsOf(expectedMigrations);
        }
    }

    @Test
    void standaloneMigratorConfigurationLoadsOnlyFromThePackagedJar() throws Exception {
        Path migratorJar = configuredPath(MIGRATOR_JAR_PROPERTY);
        assertThat(migratorJar).isRegularFile();

        try (URLClassLoader loader = new URLClassLoader(
                new java.net.URL[]{migratorJar.toUri().toURL()},
                ClassLoader.getPlatformClassLoader())) {
            Class<?> migrator = Class.forName(
                    "com.uten.imp.migration.UtenImpMigrator",
                    true,
                    loader);
            var configurationFactory = migrator.getDeclaredMethod(
                    "configuredFlyway",
                    String.class);
            configurationFactory.setAccessible(true);

            Object flyway = configurationFactory.invoke(null, "a".repeat(64));
            assertThat(flyway.getClass().getName()).isEqualTo("org.flywaydb.core.Flyway");
            assertThat(flyway.getClass().getClassLoader()).isSameAs(loader);
        }
    }

    private static Path configuredPath(String property) {
        String value = System.getProperty(property);
        assertThat(value).as("Maven property %s", property).isNotBlank();
        return Path.of(value).toAbsolutePath().normalize();
    }

    private static List<String> entryNames(JarFile jar) {
        return jar.stream().map(ZipEntry::getName).toList();
    }

}
