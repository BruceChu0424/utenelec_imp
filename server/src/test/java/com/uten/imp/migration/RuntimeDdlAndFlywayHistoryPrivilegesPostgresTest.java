package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/** Genuine PostgreSQL 16 ACL behavior; only disposable synthetic databases exist here. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class RuntimeDdlAndFlywayHistoryPrivilegesPostgresTest {
    private static final String PASSWORD = "fixture-only-918";
    private static final String RESOURCE = "db/migration/V918__runtime_ddl_and_flyway_history_read_only.sql";

    @Test
    void realFlywayConvergesLegacyPublicAndColumnGrantsAndKeepsBusinessAndMaintenanceWorking() throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.exec(fixture.owner, """
                    GRANT ALL PRIVILEGES ON flyway_schema_history TO PUBLIC, uten;
                    GRANT UPDATE(checksum), INSERT(version), REFERENCES(installed_rank) ON flyway_schema_history TO PUBLIC;
                    GRANT SELECT(version), UPDATE(checksum), INSERT(version), REFERENCES(installed_rank)
                      ON flyway_schema_history TO uten WITH GRANT OPTION;
                    """);
            assertTrue(fixture.bool("SELECT has_any_column_privilege('uten','flyway_schema_history','UPDATE WITH GRANT OPTION')"));
            String original = fixture.history();
            fixture.addProposal();
            assertEquals(1, fixture.flyway().migrate().migrationsExecuted);
            fixture.flyway().validate();
            assertEquals(0, fixture.flyway().migrate().migrationsExecuted);
            assertEquals(original, fixture.firstHistoryRow());
            fixture.assertSealedRuntime();
            try (Connection app = fixture.app()) {
                fixture.exec(app, "INSERT INTO ordinary_business(value) VALUES ('runtime'); UPDATE ordinary_business SET value='changed';");
                assertEquals(1, fixture.number(app, "SELECT count(*) FROM ordinary_business WHERE value='changed'"));
                fixture.exec(app, "DELETE FROM ordinary_business; CREATE TEMP TABLE ordinary_scratch(id integer);");
                assertEquals(0, fixture.number(app, "SELECT count(*) FROM ordinary_business"));
                assertDenied(() -> fixture.exec(app, "CREATE TABLE public.unapproved_ddl(id integer)"));
                assertDenied(() -> fixture.exec(app, "UPDATE flyway_schema_history SET checksum=0"));
                assertDenied(() -> fixture.exec(app, "SELECT fixture_controlled_import('runtime denied')"));
            }
            assertEquals(1, fixture.number(fixture.owner, "SELECT fixture_controlled_import('maintenance import')"));
            Files.writeString(fixture.directory.resolve("V919__next_maintenance.sql"),
                    "CREATE TABLE next_maintenance(id integer);", StandardCharsets.UTF_8);
            assertEquals(1, fixture.flyway().migrate().migrationsExecuted);
            assertTrue(fixture.bool("SELECT to_regclass('public.next_maintenance') IS NOT NULL"));
            assertEquals("uten_migrator", fixture.text("SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid='flyway_schema_history'::regclass"));
        }
    }

    @Test
    void noinheritSetRoleWriterIsRejectedAndAllEarlierRevokesRollBack() throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.exec(fixture.admin, "CREATE ROLE fixture_writer NOLOGIN NOINHERIT; GRANT fixture_writer TO uten WITH INHERIT FALSE,SET TRUE;");
            fixture.exec(fixture.owner, "GRANT UPDATE ON flyway_schema_history TO fixture_writer;");
            fixture.assertRejectedWithoutPartialChanges();
            assertTrue(fixture.bool("SELECT pg_has_role('uten','fixture_writer','SET')"));
            assertTrue(fixture.bool("SELECT has_table_privilege('fixture_writer','flyway_schema_history','UPDATE')"));
        }
    }

    @Test
    void inheritedColumnGrantWithoutSetRoleIsRejectedAndRolledBack() throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.exec(fixture.admin, "CREATE ROLE fixture_writer NOLOGIN; GRANT fixture_writer TO uten WITH INHERIT TRUE,SET FALSE;");
            fixture.exec(fixture.owner, "GRANT UPDATE(checksum) ON flyway_schema_history TO fixture_writer;");
            fixture.assertRejectedWithoutPartialChanges();
            assertFalse(fixture.bool("SELECT pg_has_role('uten','fixture_writer','SET')"));
        }
    }

    @Test
    void setRoleColumnDelegationAndDdlPathsCannotBypassTheGuard() throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.exec(fixture.admin, "CREATE ROLE fixture_writer NOLOGIN; GRANT fixture_writer TO uten WITH INHERIT FALSE,SET TRUE;");
            for (String grant : List.of("GRANT SELECT(version) ON flyway_schema_history TO fixture_writer WITH GRANT OPTION",
                    "GRANT CREATE ON SCHEMA public TO fixture_writer")) {
                fixture.exec(fixture.owner, grant);
                fixture.assertRejectedWithoutPartialChanges();
                fixture.exec(fixture.owner, "REVOKE ALL PRIVILEGES (version) ON flyway_schema_history FROM fixture_writer; REVOKE CREATE ON SCHEMA public FROM fixture_writer;");
            }
        }
    }

    @Test
    void runtimeHistoryOwnerOrMaintenanceMembershipMustFailRatherThanPretendToRevokeOwnership() throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.exec(fixture.admin, "ALTER TABLE flyway_schema_history OWNER TO uten;");
            fixture.assertRejectedWithoutPartialChanges();
            fixture.exec(fixture.admin, "ALTER TABLE flyway_schema_history OWNER TO uten_migrator; GRANT ALL PRIVILEGES ON flyway_schema_history TO uten; GRANT uten_migrator TO uten WITH INHERIT FALSE,SET TRUE;");
            fixture.assertRejectedWithoutPartialChanges();
        }
    }

    @Test
    void roleAdminOptionsAndAssumableAdministrativeFlagsCannotReopenAuthority() throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.exec(fixture.admin, "CREATE ROLE fixture_writer NOLOGIN; GRANT fixture_writer TO uten WITH ADMIN TRUE,INHERIT FALSE,SET FALSE;");
            fixture.exec(fixture.owner, "GRANT UPDATE ON flyway_schema_history TO fixture_writer;");
            fixture.assertRejectedWithoutPartialChanges();
            fixture.exec(fixture.admin, "REVOKE fixture_writer FROM uten; CREATE ROLE fixture_creator NOLOGIN CREATEROLE; GRANT fixture_creator TO uten WITH INHERIT FALSE,SET TRUE;");
            fixture.assertRejectedWithoutPartialChanges();
        }
    }

    @Test
    void runtimeDatabaseOrSchemaOwnershipIsRejectedWithoutChangingTheOwner() throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.exec(fixture.admin, "ALTER SCHEMA public OWNER TO uten;");
            fixture.assertRejectedWithoutPartialChanges();
            assertEquals("uten", fixture.text("SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='public'"));
            fixture.exec(fixture.admin, "ALTER SCHEMA public OWNER TO uten_migrator; DO $$BEGIN EXECUTE format('ALTER DATABASE %I OWNER TO uten',current_database()); END$$;");
            fixture.assertRejectedWithoutPartialChanges();
            assertEquals("uten", fixture.text("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()"));
        }
    }

    @Test
    void administrativeRuntimeFlagsAndDependentDelegationsRefuseWithoutCascading() throws Exception {
        try (Fixture fixture = new Fixture()) {
            for (String flag : List.of("CREATEDB", "CREATEROLE", "SUPERUSER")) {
                fixture.exec(fixture.admin, "ALTER ROLE uten " + flag);
                fixture.assertRejectedWithoutPartialChanges();
                fixture.exec(fixture.admin, "ALTER ROLE uten NOSUPERUSER NOCREATEDB NOCREATEROLE;");
            }
            fixture.exec(fixture.admin, "CREATE ROLE fixture_reader NOLOGIN;");
            fixture.exec(fixture.owner, "GRANT SELECT(version) ON flyway_schema_history TO uten WITH GRANT OPTION;");
            try (Connection app = fixture.app()) {
                fixture.exec(app, "GRANT SELECT(version) ON flyway_schema_history TO fixture_reader;");
            }
            SQLException refused = assertThrows(SQLException.class, () -> fixture.exec(fixture.owner, fixture.proposal));
            assertEquals("2BP01", refused.getSQLState());
            assertTrue(fixture.bool("SELECT has_any_column_privilege('fixture_reader','flyway_schema_history','SELECT')"));
            assertTrue(fixture.bool("SELECT has_schema_privilege('uten','public','CREATE')"));
        }
    }

    @FunctionalInterface
    private interface SqlAction { void run() throws SQLException; }

    private static void assertDenied(SqlAction action) {
        SQLException denied = assertThrows(SQLException.class, action::run);
        assertEquals("42501", denied.getSQLState());
    }

    private static final class Fixture implements AutoCloseable {
        private final PostgreSQLContainer pg = new PostgreSQLContainer("postgres:16-alpine").withUsername("fixture_admin");
        private final Path directory = Files.createTempDirectory("runtime-history-918-");
        private final String proposal = new ClassPathResource(RESOURCE).getContentAsString(StandardCharsets.UTF_8);
        private Connection admin;
        private Connection owner;

        private Fixture() throws Exception {
            try {
                pg.start();
                admin = DriverManager.getConnection(pg.getJdbcUrl(), pg.getUsername(), pg.getPassword());
                exec(admin, "CREATE ROLE uten LOGIN NOSUPERUSER NOINHERIT PASSWORD 'fixture-only-918'; CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOINHERIT PASSWORD 'fixture-only-918';");
                exec(admin, "DO $$BEGIN EXECUTE format('ALTER DATABASE %I OWNER TO uten_migrator',current_database()); END$$; ALTER SCHEMA public OWNER TO uten_migrator;");
                owner = DriverManager.getConnection(pg.getJdbcUrl(), "uten_migrator", PASSWORD);
                Files.writeString(directory.resolve("V1__fixture.sql"), """
                        CREATE TABLE ordinary_business(id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,value text);
                        CREATE TABLE controlled_import_provenance(id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,value text);
                        GRANT SELECT,INSERT,UPDATE,DELETE ON ordinary_business TO uten;
                        GRANT USAGE,SELECT ON SEQUENCE ordinary_business_id_seq TO uten;
                        CREATE FUNCTION fixture_controlled_import(v text) RETURNS integer LANGUAGE plpgsql AS $$
                        DECLARE result integer; BEGIN INSERT INTO controlled_import_provenance(value) VALUES(v) RETURNING id INTO result; RETURN result; END$$;
                        REVOKE ALL ON FUNCTION fixture_controlled_import(text) FROM PUBLIC,uten;
                        """, StandardCharsets.UTF_8);
                assertEquals(1, flyway().migrate().migrationsExecuted);
                exec(owner, "DO $$BEGIN EXECUTE format('GRANT CONNECT,TEMPORARY,CREATE ON DATABASE %I TO uten',current_database()); EXECUTE format('GRANT CREATE ON DATABASE %I TO PUBLIC',current_database()); END$$;");
                exec(owner, "GRANT USAGE,CREATE ON SCHEMA public TO uten; GRANT CREATE ON SCHEMA public TO PUBLIC; GRANT ALL PRIVILEGES ON flyway_schema_history TO uten;");
            } catch (Exception failure) {
                close();
                throw failure;
            }
        }

        private Flyway flyway() {
            return Flyway.configure().dataSource(pg.getJdbcUrl(), "uten_migrator", PASSWORD)
                    .locations("filesystem:" + directory).defaultSchema("public").schemas("public")
                    .baselineOnMigrate(false).cleanDisabled(true).outOfOrder(false).validateOnMigrate(true).load();
        }

        private void addProposal() throws Exception {
            Files.writeString(directory.resolve("V918__runtime_acl.sql"), proposal, StandardCharsets.UTF_8);
        }

        private Connection app() throws SQLException {
            return DriverManager.getConnection(pg.getJdbcUrl(), "uten", PASSWORD);
        }

        private void exec(Connection connection, String sql) throws SQLException {
            try (var statement = connection.createStatement()) { statement.execute(sql); }
        }

        private boolean bool(String sql) throws SQLException {
            try (var statement = admin.createStatement(); var rows = statement.executeQuery(sql)) {
                assertTrue(rows.next()); return rows.getBoolean(1);
            }
        }

        private String text(String sql) throws SQLException {
            try (var statement = admin.createStatement(); var rows = statement.executeQuery(sql)) {
                assertTrue(rows.next()); return rows.getString(1);
            }
        }

        private int number(Connection connection, String sql) throws SQLException {
            try (var statement = connection.createStatement(); var rows = statement.executeQuery(sql)) {
                assertTrue(rows.next()); return rows.getInt(1);
            }
        }

        private String history() throws SQLException { return text("SELECT row_to_json(h)::text FROM flyway_schema_history h ORDER BY installed_rank LIMIT 1"); }
        private String firstHistoryRow() throws SQLException { return history(); }

        private void assertRejectedWithoutPartialChanges() throws SQLException {
            assertTrue(bool("SELECT has_schema_privilege('uten','public','CREATE')"));
            assertTrue(bool("SELECT has_table_privilege('uten','flyway_schema_history','UPDATE')"));
            String original = history();
            SQLException refused = assertThrows(SQLException.class, () -> exec(owner, proposal));
            assertEquals("42501", refused.getSQLState());
            assertEquals(original, history());
            assertTrue(bool("SELECT has_schema_privilege('uten','public','CREATE')"));
            assertTrue(bool("SELECT has_table_privilege('uten','flyway_schema_history','UPDATE')"));
        }

        private void assertSealedRuntime() throws SQLException {
            assertFalse(bool("SELECT has_database_privilege('uten',current_database(),'CREATE')"));
            assertFalse(bool("SELECT has_schema_privilege('uten','public','CREATE')"));
            assertTrue(bool("SELECT has_database_privilege('uten',current_database(),'TEMPORARY')"));
            assertTrue(bool("SELECT has_table_privilege('uten','flyway_schema_history','SELECT')"));
            for (String privilege : List.of("INSERT","UPDATE","DELETE","TRUNCATE","REFERENCES","TRIGGER","SELECT WITH GRANT OPTION")) {
                try (var query = admin.prepareStatement("SELECT has_table_privilege('uten','flyway_schema_history',?)")) {
                    query.setString(1,privilege);try (var rows=query.executeQuery()) {assertTrue(rows.next());assertFalse(rows.getBoolean(1),privilege);}
                }
            }
            for (String privilege : List.of("INSERT","UPDATE","REFERENCES","SELECT WITH GRANT OPTION")) {
                try (var query = admin.prepareStatement("SELECT has_any_column_privilege('uten','flyway_schema_history',?)")) {
                    query.setString(1,privilege);try (var rows=query.executeQuery()) {assertTrue(rows.next());assertFalse(rows.getBoolean(1),privilege);}
                }
            }
        }

        @Override public void close() throws Exception {
            try {
                if (owner != null) owner.close();
                if (admin != null) admin.close();
            } finally {
                pg.close();
                try (var paths = Files.list(directory)) { for (Path path : paths.toList()) Files.delete(path); }
                Files.delete(directory);
            }
        }
    }
}
