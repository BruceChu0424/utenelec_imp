package com.uten.imp.migration;

import com.uten.imp.UtenImpApplication;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.web.servlet.mvc.method.annotation.RequestMappingHandlerMapping;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Path;
import java.time.Duration;

import static org.assertj.core.api.Assertions.assertThat;

/** Full real schema and real dev HTTP startup. Only a newly created disposable database. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class LocalRuntimePrivilegesPostgresTest {
    @TempDir Path temporary;

    @Test
    void freshSplitRolesNoOpMigrationAndRealHttpStartupKeepResetRetired() throws Exception {
        String password = "runtime-acl-isolated-fixture-only";
        try (var postgres = new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("uten_imp")) {
            postgres.start();
            var admin = new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(),
                    postgres.getUsername(), postgres.getPassword()));
            admin.execute("CREATE ROLE uten LOGIN NOSUPERUSER NOINHERIT PASSWORD '" + password + "'");
            admin.execute("CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOINHERIT PASSWORD '" + password + "'");
            admin.execute("ALTER DATABASE uten_imp OWNER TO uten_migrator");
            admin.execute("ALTER SCHEMA public OWNER TO uten_migrator");
            admin.execute("REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM PUBLIC,uten");
            admin.execute("GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator");
            var owner = new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(), "uten_migrator", password));
            owner.execute("ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC");
            Flyway flyway = Flyway.configure().dataSource(postgres.getJdbcUrl(), "uten_migrator", password)
                    .locations("classpath:db/migration").defaultSchema("public").schemas("public")
                    .cleanDisabled(true).callbacks(new AppliedMigrationCompatibilityCallback(),
                            new AuditFreshStartGuardCallback(), new LocalRuntimePrivilegesCallback("uten")).load();
            assertThat(flyway.migrate().migrationsExecuted).isGreaterThan(800);
            var runtime = new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(), "uten", password));
            assertThat(runtime.queryForObject("SELECT count(*) FROM permission_surfaces", Integer.class)).isPositive();
            owner.execute("REVOKE SELECT ON permission_surfaces,permission_surface_permissions,permissions FROM uten");
            assertThat(flyway.migrate().migrationsExecuted).isZero();
            assertThat(runtime.queryForObject("SELECT count(*) FROM permission_surfaces", Integer.class)).isPositive();
            assertThat(admin.queryForObject("SELECT to_regprocedure('business_data_reset()') IS NULL", Boolean.class)).isTrue();
            assertThat(admin.queryForObject("SELECT count(*) FROM permissions WHERE code='system:business_data_reset'", Integer.class)).isZero();
            assertThat(admin.queryForObject("SELECT has_function_privilege('uten','fn_require_runtime_refresh()','EXECUTE')", Boolean.class)).isFalse();
            assertThat(admin.queryForObject("SELECT has_table_privilege('uten','legacy_production_plan_counter_import_sources','UPDATE')", Boolean.class)).isFalse();
            for (String name : new String[]{"finance_ar_ap", "production_monthly", "purchase_monthly", "sales_monthly", "stock_monthly", "subcontract_monthly"}) {
                runtime.execute("SELECT refresh_" + name + "_mv()");
            }
            // Prove Spring discovers the dev callback automatically, rather than
            // relying on the explicitly registered Flyway instance above.
            owner.execute("REVOKE SELECT ON permission_surfaces,permission_surface_permissions,permissions FROM uten");
            try (var application = new SpringApplicationBuilder(UtenImpApplication.class).profiles("dev").run(
                    "--spring.profiles.active=dev", "--spring.flyway.enabled=true",
                    "--server.address=127.0.0.1", "--server.port=0",
                    "--uten.deployment.site=local", "--uten.deployment.local-allowed-cidrs=127.0.0.1/32,::1/128",
                    "--spring.datasource.url=" + postgres.getJdbcUrl(), "--spring.datasource.username=uten",
                    "--spring.datasource.password=" + password, "--spring.flyway.url=" + postgres.getJdbcUrl(),
                    "--spring.flyway.user=uten_migrator", "--spring.flyway.password=" + password,
                    "--uten.storage.provider=disabled", "--uten.storage.uploads-enabled=false",
                    "--uten.storage.local-dir=" + temporary.resolve("attachments"),
                    "--uten.jwt.secret=runtime-acl-isolated-fixture-secret-at-least-32-bytes",
                    "--uten.crypto.pgp-master-key=runtime-acl-isolated-fixture-pgp-key",
                    "--uten.crypto.hmac-key=runtime-acl-isolated-fixture-hmac-key-at-least-32-bytes",
                    "--uten.bootstrap.admin-login=19900000123", "--uten.bootstrap.admin-password=RuntimeAclFixture789!",
                    "--uten.sms.provider=log", "--uten.crypto.rotation.enabled=false")) {
                assertThat(application.getEnvironment().getActiveProfiles()).containsExactly("dev");
                assertThat(application.getBean(JdbcTemplate.class).queryForObject("SELECT current_user", String.class)).isEqualTo("uten");
                assertThat(application.getBean(PermissionSurfaceRegistry.class).knownKeys()).isNotEmpty();
                var mappings = application.getBean("requestMappingHandlerMapping", RequestMappingHandlerMapping.class);
                assertThat(mappings.getHandlerMethods().keySet()).noneMatch(mapping ->
                        mapping.getPatternValues().stream().anyMatch(path -> path.contains("/system-test")));
                int port = ((WebServerApplicationContext)application).getWebServer().getPort();
                var response = HttpClient.newHttpClient().send(HttpRequest.newBuilder(
                                URI.create("http://127.0.0.1:" + port + "/actuator/health/readiness"))
                        .timeout(Duration.ofSeconds(20)).GET().build(), HttpResponse.BodyHandlers.ofString());
                assertThat(response.statusCode()).isEqualTo(200);
                assertThat(response.body()).contains("UP");
            }
        }
    }
}
