package com.uten.imp.packaging;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.DriverManager;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.jar.JarFile;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/** Launches only the packaged runtime, without Maven's test classpath. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ServerRuntimeFlywayIT {
    @TempDir Path directory;

    @Test
    void devRuntimeMigratesAnEmptyPrivateDatabaseBeforeBecomingReady() throws Exception {
        MigrationInventory expected = migrationInventory();
        try (var postgres = new PostgreSQLContainer("postgres:16-alpine").withReuse(false)) {
            postgres.start();
            Path output = directory.resolve("runtime-startup.log");
            Process process = start(postgres, output, List.of());
            try {
                awaitStartup(process, output);
                try (var connection = DriverManager.getConnection(postgres.getJdbcUrl(),
                        postgres.getUsername(), postgres.getPassword());
                     var statement = connection.createStatement();
                     var row = statement.executeQuery("""
                             SELECT to_regprocedure('public.fn_begin_goods_history_request()') IS NOT NULL,
                                    (SELECT count(*) FROM public.flyway_schema_history WHERE success),
                                    (SELECT max(version::numeric) FROM public.flyway_schema_history WHERE success)
                             """)) {
                    assertThat(row.next()).isTrue();
                    assertThat(row.getBoolean(1)).isTrue();
                    assertThat(row.getInt(2)).isEqualTo(expected.count());
                    assertThat(row.getInt(3)).isEqualTo(expected.head());
                }
                String log = Files.readString(output);
                assertThat(log).contains("Successfully applied", "Started UtenImpApplication");
                assertThat(log.indexOf("Successfully applied"))
                        .isLessThan(log.indexOf("Started UtenImpApplication"));
            } finally {
                stop(process);
            }
        }
    }

    @Test
    void devRuntimeRejectsAFailedMigrationBeforeServingRequests() throws Exception {
        Path migrations = Files.createDirectory(directory.resolve("invalid-migration"));
        Files.writeString(migrations.resolve("V1__intentional_failure.sql"),
                "SELECT runtime_migration_regression_function_that_does_not_exist();\n");
        try (var postgres = new PostgreSQLContainer("postgres:16-alpine").withReuse(false)) {
            postgres.start();
            Path output = directory.resolve("runtime-migration-failure.log");
            Process process = start(postgres, output,
                    List.of("--spring.flyway.locations=filesystem:" + migrations.toAbsolutePath()));
            try {
                assertThat(process.waitFor(120, TimeUnit.SECONDS))
                        .as("Packaged runtime must reject the failed migration").isTrue();
                assertThat(process.exitValue()).isNotZero();
                assertThat(Files.readString(output))
                        .contains("runtime_migration_regression_function_that_does_not_exist")
                        .doesNotContain("Started UtenImpApplication", "Tomcat started on port");
            } finally {
                stop(process);
            }
        }
    }

    private Process start(PostgreSQLContainer postgres, Path output, List<String> overrides) throws Exception {
        Path jar = applicationJar();
        assertThat(jar).isRegularFile();
        // This JAR/Flyway smoke neither exercises reset nor ships a forecast runtime payload.
        List<String> command = new ArrayList<>(List.of(
                Path.of(System.getProperty("java.home"), "bin", "java").toString(),
                "-Xmx512m", "-Dfile.encoding=UTF-8", "-jar", jar.toString(),
                "--spring.profiles.active=dev", "--server.address=127.0.0.1", "--server.port=0",
                "--uten.features.business-data-reset-enabled=false",
                "--uten.material-forecast.manage-runtime=false",
                "--spring.datasource.url=" + postgres.getJdbcUrl(),
                "--spring.datasource.username=" + postgres.getUsername(),
                "--spring.datasource.password=" + postgres.getPassword(),
                "--spring.flyway.enabled=true", "--spring.flyway.url=" + postgres.getJdbcUrl(),
                "--spring.flyway.user=" + postgres.getUsername(),
                "--spring.flyway.password=" + postgres.getPassword(),
                "--uten.jwt.secret=runtime-packaging-test-only-jwt-01234567890123456789",
                "--uten.crypto.pgp-master-key=runtime-packaging-test-only-pgp-01234567890123456789",
                "--uten.crypto.hmac-key=runtime-packaging-test-only-hmac-01234567890123456789",
                "--uten.bootstrap.admin-login=runtime-packaging-test",
                "--uten.bootstrap.admin-password=RuntimePackagingTest-1!",
                "--uten.storage.local-dir=" + directory.resolve("attachments"),
                "--uten.storage.uploads-enabled=true", "--uten.storage.malware-scan.provider=test-only",
                "--uten.audit.retention.enabled=false", "--uten.reporting.materialized-view-refresh.enabled=false",
                "--uten.production.readiness-reconcile.enabled=false", "--logging.file.name=" + output.resolveSibling("runtime.log")));
        command.addAll(overrides);
        return new ProcessBuilder(command).directory(directory.toFile())
                .redirectErrorStream(true).redirectOutput(output.toFile()).start();
    }

    private record MigrationInventory(int count, int head) { }

    private static MigrationInventory migrationInventory() throws Exception {
        // V990_1/V999_13 一类点分文件（Flyway 版本 990.1/999.13）同样是已应用迁移，
        // 必须数进清单；此前 V(\d+)__ 漏数点分文件，条数比 flyway_schema_history 实际成功行少。
        Pattern migration = Pattern.compile("BOOT-INF/classes/db/migration/V(\\d+)(?:_(\\d+))?__[^/]+\\.sql");
        try (var jar = new JarFile(applicationJar().toFile())) {
            // 版本对 {主版本, 点分段}：唯一性按完整版本判断，仅按主版本去重会把 V990 与 V990_1 误判为重复。
            List<int[]> versions = jar.stream().map(entry -> migration.matcher(entry.getName()))
                    .filter(matcher -> matcher.matches())
                    .map(matcher -> new int[] {
                            com.uten.imp.testsupport.FixtureNumbers.integer(matcher.group(1)),
                            matcher.group(2) == null
                                    ? 0
                                    : com.uten.imp.testsupport.FixtureNumbers.integer(matcher.group(2))})
                    .toList();
            assertThat(versions).isNotEmpty();
            assertThat(versions.stream().map(version -> version[0] + "." + version[1]).toList())
                    .doesNotHaveDuplicates();
            int[] head = versions.stream()
                    .max(java.util.Comparator.comparingInt((int[] version) -> version[0])
                            .thenComparingInt(version -> version[1]))
                    .orElseThrow();
            // 迁移头不能落在点分文件上，否则 max(version::numeric) 与整数头推导失真；真出现时在此报出。
            assertThat(head[1]).as("migration head must stay on an integral version").isZero();
            return new MigrationInventory(versions.size(), head[0]);
        }
    }

    private static Path applicationJar() {
        return Path.of(System.getProperty("uten.packaging.application-jar")).toAbsolutePath().normalize();
    }

    private static void awaitStartup(Process process, Path output) throws Exception {
        // A private empty database replays the full migration inventory before
        // readiness (811 migrations took 350s in the integrated PG16 run).
        // This test bound does not relax application or interaction assertions.
        long deadline = System.nanoTime() + Duration.ofSeconds(480).toNanos();
        while (System.nanoTime() < deadline) {
            String log = Files.readString(output);
            if (log.contains("Started UtenImpApplication")) return;
            assertThat(process.isAlive()).as("Packaged runtime startup failed: %s", log).isTrue();
            process.waitFor(200, TimeUnit.MILLISECONDS);
        }
        throw new AssertionError("Packaged runtime startup timed out: " + Files.readString(output));
    }

    private static void stop(Process process) throws InterruptedException {
        if (!process.isAlive()) return;
        process.destroy();
        if (!process.waitFor(15, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            assertThat(process.waitFor(15, TimeUnit.SECONDS)).isTrue();
        }
    }
}
