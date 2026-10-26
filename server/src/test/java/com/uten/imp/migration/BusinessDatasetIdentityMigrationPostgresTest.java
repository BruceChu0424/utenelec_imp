package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** Dedicated synthetic container: no application database or credentials are used. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessDatasetIdentityMigrationPostgresTest {
    @Test
    void migrationCreatesOneIdentityWithoutChangingHistoryAndFencesEveryReplacement() throws Exception {
        try (var postgres = new PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            var source = new DriverManagerDataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
            var db = new JdbcTemplate(source);
            TestFlyway.configure().dataSource(source).locations("classpath:db/migration").target("934").load().migrate();
            var before = db.queryForMap("SELECT epoch,business_reset_generation,updated_at FROM authorization_state WHERE singleton_id=1");
            var upgrade = TestFlyway.configure().dataSource(source).locations("classpath:db/migration").target("935").load();

            assertThat(upgrade.migrate().migrationsExecuted).isEqualTo(1);
            UUID identity = db.queryForObject("SELECT business_dataset_id FROM authorization_state WHERE singleton_id=1", UUID.class);
            assertThat(identity).isNotNull();
            assertThat(db.queryForMap("SELECT epoch,business_reset_generation,updated_at FROM authorization_state WHERE singleton_id=1")).isEqualTo(before);
            upgrade.validate();
            assertThat(upgrade.migrate().migrationsExecuted).isZero();
            assertThat(db.queryForObject("SELECT business_dataset_id FROM authorization_state WHERE singleton_id=1", UUID.class)).isEqualTo(identity);
            assertThat(db.queryForObject("SELECT column_default FROM information_schema.columns WHERE table_schema='public' AND table_name='authorization_state' AND column_name='business_dataset_id'", String.class)).isNull();
            db.update("UPDATE authorization_state SET epoch=epoch+1 WHERE singleton_id=1");
            db.update("UPDATE authorization_state SET business_dataset_id=business_dataset_id WHERE singleton_id=1");
            assertThat(db.queryForObject("SELECT business_dataset_id FROM authorization_state WHERE singleton_id=1", UUID.class)).isEqualTo(identity);

            // A role with the old broad runtime table grant still cannot replace identity.
            db.execute("CREATE ROLE dataset_runtime LOGIN NOSUPERUSER NOINHERIT PASSWORD 'synthetic-dataset-only'");
            db.execute("GRANT USAGE ON SCHEMA public TO dataset_runtime");
            db.execute("GRANT SELECT,UPDATE,DELETE,TRUNCATE ON authorization_state TO dataset_runtime");
            try (Connection runtime = new DriverManagerDataSource(postgres.getJdbcUrl(), "dataset_runtime", "synthetic-dataset-only").getConnection()) {
                assertRejectedReplacements(runtime);
            }
            // ENABLE ALWAYS also fences accidental replica-mode maintenance writes.
            try (Connection maintenance = source.getConnection(); var stmt = maintenance.createStatement()) {
                stmt.execute("SET session_replication_role='replica'");
                assertRejectedReplacements(maintenance);
            }
            assertThat(db.queryForObject("SELECT business_dataset_id FROM authorization_state WHERE singleton_id=1", UUID.class)).isEqualTo(identity);
            assertThat(db.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class)).isEqualTo(before.get("business_reset_generation"));

            // A second fresh dataset can have the same historical generation
            // behind the same server address, but must receive a different ID.
            db.execute("CREATE DATABASE dataset_second");
            var secondSource = new DriverManagerDataSource(
                    "jdbc:postgresql://" + postgres.getHost() + ":" + postgres.getMappedPort(5432) + "/dataset_second",
                    postgres.getUsername(), postgres.getPassword());
            TestFlyway.configure().dataSource(secondSource).locations("classpath:db/migration").target("935").load().migrate();
            var secondDb = new JdbcTemplate(secondSource);
            assertThat(secondDb.queryForObject("SELECT business_dataset_id FROM authorization_state WHERE singleton_id=1", UUID.class))
                    .isNotNull().isNotEqualTo(identity);
            assertThat(secondDb.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class))
                    .isEqualTo(before.get("business_reset_generation"));
        }
    }

    private static void assertRejectedReplacements(Connection connection) throws SQLException {
        try (var statement = connection.createStatement()) {
            for (String sql : List.of(
                    "UPDATE authorization_state SET business_dataset_id=gen_random_uuid() WHERE singleton_id=1",
                    "UPDATE authorization_state SET business_dataset_id=NULL WHERE singleton_id=1",
                    "DELETE FROM authorization_state WHERE singleton_id=1",
                    "TRUNCATE authorization_state")) {
                assertThat(assertThrows(SQLException.class, () -> statement.execute(sql)).getSQLState())
                        .as(sql).isEqualTo("55000");
            }
        }
    }
}
