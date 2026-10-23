package com.uten.imp.ops;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;

/** A real PostgreSQL grant boundary test; its reset fixture never deletes data. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessDataResetRetirementPostgresTest {
    @Test
    void migrationRevokesDirectAndInheritedRuntimeExecuteWithoutCallingReset() throws Exception {
        try (var pg = new PostgreSQLContainer("postgres:16-alpine")) {
            pg.start();
            var admin = new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(), pg.getUsername(), pg.getPassword()));
            admin.execute("""
                    CREATE ROLE reset_owner NOLOGIN;
                    CREATE ROLE reset_tools NOLOGIN;
                    CREATE ROLE uten LOGIN NOSUPERUSER NOINHERIT PASSWORD 'test-only-retirement';
                    GRANT reset_tools TO uten;
                    CREATE SEQUENCE reset_sentinel START 1;
                    GRANT USAGE ON SEQUENCE reset_sentinel TO reset_owner;
                    CREATE FUNCTION public.business_data_reset() RETURNS integer
                    LANGUAGE plpgsql SECURITY DEFINER AS $$
                    BEGIN RETURN nextval('public.reset_sentinel')::integer; END; $$;
                    ALTER FUNCTION public.business_data_reset() OWNER TO reset_owner;
                    GRANT EXECUTE ON FUNCTION public.business_data_reset() TO PUBLIC, uten, reset_tools;
                    """);
            String body = new ClassPathResource("db/migration/V915__retire_server_business_data_reset.sql")
                    .getContentAsString(StandardCharsets.UTF_8);
            admin.execute(body);
            admin.execute(body); // The privilege operation is safe to repeat.
            assertThat(admin.queryForObject("SELECT has_function_privilege('uten', 'public.business_data_reset()', 'EXECUTE')", Boolean.class)).isFalse();
            assertThat(admin.queryForObject("SELECT has_function_privilege('reset_tools', 'public.business_data_reset()', 'EXECUTE')", Boolean.class)).isFalse();
            assertThat(admin.queryForObject("SELECT has_function_privilege('reset_owner', 'public.business_data_reset()', 'EXECUTE')", Boolean.class)).isTrue();
            var runtime = new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(), "uten", "test-only-retirement"));
            Throwable refused = catchThrowable(() -> runtime.queryForObject("SELECT public.business_data_reset()", Integer.class));
            assertThat(refused).isNotNull();
            assertThat(org.springframework.core.NestedExceptionUtils.getMostSpecificCause(refused))
                    .isInstanceOf(java.sql.SQLException.class)
                    .extracting(value -> ((java.sql.SQLException) value).getSQLState()).isEqualTo("42501");
            assertThat(admin.queryForObject("SELECT is_called FROM reset_sentinel", Boolean.class)).isFalse();
            // An isolated local database owner can still restore its local test entry.
            admin.execute("GRANT EXECUTE ON FUNCTION public.business_data_reset() TO uten");
            assertThat(runtime.queryForObject("SELECT public.business_data_reset()", Integer.class)).isEqualTo(1);
            // A SUPERUSER runtime login bypasses REVOKE and must block deployment.
            admin.execute("ALTER ROLE uten SUPERUSER");
            Throwable unsafeRuntime = catchThrowable(() -> admin.execute(body));
            assertThat(unsafeRuntime).isNotNull().hasMessageContaining("runtime role uten still inherits business reset authority");
            assertThat(admin.queryForObject("SELECT last_value FROM reset_sentinel", Integer.class)).isEqualTo(1);
            admin.execute("ALTER ROLE uten NOSUPERUSER");
            admin.execute(body);
            assertThat(admin.queryForObject("SELECT has_function_privilege('uten', 'public.business_data_reset()', 'EXECUTE')", Boolean.class)).isFalse();
        }
    }
}
