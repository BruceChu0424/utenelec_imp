package com.uten.imp.ops;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;

/**
 * The single object rule migration (V798, renumbered at merge) patches business_data_reset() by anchors
 * and replaces two small functions only after a byte check. The migration versions are located by
 * content, so renumbering needs no change here: P = the version just before it, R = the migration.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class BusinessDataResetV798PreconditionPostgresTest {
    private PostgreSQLContainer<?> postgres;
    private String previous;
    private String current;
    private int clones;

    @BeforeAll
    void migrateToTheVersionBefore() throws Exception {
        int[] versions = TestResetCurrentOwnerPostgresTest.singleObjectRuleVersions();
        previous = Integer.toString(versions[0]);
        current = Integer.toString(versions[1]);
        postgres = new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("precondition_base");
        postgres.start();
        Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration").target(previous).load().migrate();
    }

    @AfterAll
    void stop() {
        if (postgres != null) postgres.stop();
    }

    @Test
    void byteConstantsInTheMigrationMatchTheInstalledFunctionsBeforeIt() throws Exception {
        List<String> constants = constants();
        JdbcTemplate base = jdbc(postgres.getDatabaseName());
        assertThat(base.queryForObject("SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid='public.fn_clear_business_test_object_metadata()'::regprocedure", String.class))
                .isEqualTo(constants.get(0));
        assertThat(base.queryForObject("SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid='public.fn_attachment_retained_identity_guard()'::regprocedure", String.class))
                .isEqualTo(constants.get(1));
    }

    @Test
    void anotherMigrationsChangeOutsideTheAnchorsIsKept() throws Exception {
        String database = cloneOfPrevious();
        JdbcTemplate jdbc = jdbc(database);
        String line = "    -- Goods safety stock and cost settings remain master configuration.";
        String changed = "    -- Goods safety stock and cost settings remain master configuration (probe kept by V798).";
        patchResetFunction(jdbc, line, changed);
        assertThat(migrate(database)).isNull();
        assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure)", String.class))
                .contains(changed).contains("fn_business_data_reset_refusals()");
    }

    @Test
    void aChangedAnchorFailsClosedAndNamesTheEdit() throws Exception {
        String database = cloneOfPrevious();
        JdbcTemplate jdbc = jdbc(database);
        patchResetFunction(jdbc, "    PERFORM public.fn_clear_business_test_object_metadata();",
                "    PERFORM  public.fn_clear_business_test_object_metadata();");
        Throwable failure = migrate(database);
        assertThat(failure).isNotNull();
        assertThat(failure.getMessage()).contains("V798 edit E2 expected 1 occurrence(s)").contains("found 0");
        assertThat(jdbc.queryForObject("SELECT to_regprocedure('public.fn_business_test_reset_objects()') IS NULL", Boolean.class))
                .as("the whole migration rolled back").isTrue();
    }

    @Test
    void aChangedReplacedFunctionFailsClosedWithBothHashes() throws Exception {
        String database = cloneOfPrevious();
        JdbcTemplate jdbc = jdbc(database);
        String definition = jdbc.queryForObject("SELECT pg_get_functiondef('public.fn_clear_business_test_object_metadata()'::regprocedure)", String.class);
        assertThat(definition).containsOnlyOnce("END $function$");
        jdbc.execute(definition.replace("END $function$", "    -- probe: another migration changed this body\nEND $function$"));
        String actual = jdbc.queryForObject("SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid='public.fn_clear_business_test_object_metadata()'::regprocedure", String.class);
        Throwable failure = migrate(database);
        assertThat(failure).isNotNull();
        assertThat(failure.getMessage()).contains(constants().get(0)).contains(actual)
                .contains("fn_clear_business_test_object_metadata()");
    }

    private static void patchResetFunction(JdbcTemplate jdbc, String from, String to) {
        String definition = jdbc.queryForObject("SELECT replace(pg_get_functiondef('public.business_data_reset()'::regprocedure), E'\\r\\n', E'\\n')", String.class);
        assertThat(definition).containsOnlyOnce(from);
        jdbc.execute(definition.replace(from, to));
    }

    private Throwable migrate(String database) {
        String url = com.uten.imp.support.MigratedSchemaBaseline.jdbcUrlFor(postgres, database);
        return catchThrowable(() -> Flyway.configure().dataSource(url, postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration").target(current).load().migrate());
    }

    private synchronized String cloneOfPrevious() throws Exception {
        String name = "precondition_case_" + (++clones);
        var result = postgres.execInContainer("createdb", "-U", postgres.getUsername(), "-T", postgres.getDatabaseName(), name);
        assertThat(result.getExitCode()).as(result.getStderr()).isZero();
        return name;
    }

    private JdbcTemplate jdbc(String database) {
        return new JdbcTemplate(new DriverManagerDataSource(
                com.uten.imp.support.MigratedSchemaBaseline.jdbcUrlFor(postgres, database), postgres.getUsername(), postgres.getPassword()));
    }

    /** The two md5 constants of section 0, in order: fn_clear first, then the attachment guard. */
    private static List<String> constants() throws Exception {
        String migration = BusinessDataResetSqlContractTest.singleObjectRuleMigration();
        Matcher matcher = Pattern.compile("IF actual IS DISTINCT FROM '([0-9a-f]{32})' THEN").matcher(migration);
        List<String> found = new ArrayList<>();
        while (matcher.find()) found.add(matcher.group(1));
        assertThat(found).hasSize(2);
        return found;
    }
}
