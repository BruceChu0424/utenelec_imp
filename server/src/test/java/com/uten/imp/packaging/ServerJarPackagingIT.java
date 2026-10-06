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
            // ADR-153: whitelisted design documents are packaged read-only for the AI assistant's knowledge;
            // administration, security and AI-assistant documents are not.
            assertThat(entries)
                    .contains("BOOT-INF/classes/ai-knowledge/99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md",
                            "BOOT-INF/classes/ai-knowledge/00-项目准则/14-徽章与计数口径.md")
                    .noneMatch(name -> name.startsWith("BOOT-INF/classes/ai-knowledge/")
                            && (name.contains("登录页") || name.contains("AI服务设置页") || name.contains("ADR-150")
                            || name.contains("代码总结") || name.contains("10-安全准则") || name.contains("99-项目治理")
                            || !name.matches("BOOT-INF/classes/ai-knowledge/(?:(?:99-决策记录-ADR|03-页面|07-业务链路|00-项目准则)(?:/.*)?)?")));
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
                            "com/uten/imp/migration/AuditFreshStartGuardCallback.class",
                            "org/postgresql/util/LazyCleaner.class")
                    .noneMatch(name -> name.startsWith("BOOT-INF/"))
                    .noneMatch(name -> name.startsWith("ai-knowledge/"))
                    .noneMatch(name -> name.startsWith("org/springframework/"));
            assertThat(entries.stream()
                    .filter(name -> name.startsWith("db/migration/") && name.endsWith(".sql"))
                    .sorted()
                    .toList())
                    .containsExactlyElementsOf(expectedMigrations);
            // The shaded migrator must preserve both PostgreSQL and Jackson notices,
            // rather than silently picking one dependency's overlapping license file.
            assertThat(entries.stream().filter("META-INF/LICENSE"::equals)).hasSize(1);
            String licenses = new String(jar.getInputStream(jar.getJarEntry("META-INF/LICENSE")).readAllBytes(),
                    java.nio.charset.StandardCharsets.UTF_8);
            assertThat(licenses).contains("PostgreSQL Global Development Group", "Apache License");
            assertThat(entries.stream().filter("META-INF/NOTICE"::equals)).hasSize(1);
            String notices = new String(jar.getInputStream(jar.getJarEntry("META-INF/NOTICE")).readAllBytes(),
                    java.nio.charset.StandardCharsets.UTF_8);
            assertThat(notices).contains("Jackson");
        }
    }

    /**
     * ADR-153 revision: the packaged design documents load through the executable jar's own nested-jar class loader
     * (not only from exploded target/classes), so a release never silently answers every rule question with "no
     * description found".
     */
    @Test
    void theAssistantsKnowledgeLoadsFromTheExecutableJar() throws Exception {
        Path applicationJar = configuredPath(APPLICATION_JAR_PROPERTY);
        assertThat(applicationJar).isRegularFile();
        String javaBin = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        Process process = new ProcessBuilder(javaBin, "-Dfile.encoding=UTF-8", "-cp", applicationJar.toString(),
                "-Dloader.main=com.uten.imp.features.ai.chat.AiKnowledgeIndexCheck",
                "org.springframework.boot.loader.launch.PropertiesLauncher")
                .redirectErrorStream(true).start();
        String output = new String(process.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        assertThat(process.waitFor(120, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
        assertThat(process.exitValue()).as(output).isZero();
        var counts = java.util.regex.Pattern.compile("documents=(\\d+) chunks=(\\d+)").matcher(output);
        assertThat(counts.find()).as(output).isTrue();
        assertThat(Integer.parseInt(counts.group(1))).as(output).isGreaterThan(150);
        assertThat(Integer.parseInt(counts.group(2))).as(output).isGreaterThan(1000);
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
