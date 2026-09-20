package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractPreparationCommitmentMigrationPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String MIGRATION = "db/migration/V621__subcontract_preparation_commitment_reconciliation.sql";

    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test void deployedV606UpgradesToCurrentHeadWithoutChangingAppliedChecksums() {
        var base = Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target("606").load();
        base.migrate();
        var db = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        var checksums = db.queryForList("SELECT version, checksum FROM flyway_schema_history WHERE version::integer<=606 ORDER BY installed_rank");
        var upgraded = Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
        assertEquals(MigrationRehearsalSupport.expectedMigrationsAfter(606), upgraded.migrationsExecuted);
        assertEquals(checksums, db.queryForList("SELECT version, checksum FROM flyway_schema_history WHERE version::integer<=606 ORDER BY installed_rank"));
    }

    @Test void repairsOnlyProvenProjectionAndDoesNotRewriteSourceFacts() throws Exception {
        var db = fixture("2000", "2000", "10000", "0");
        var actions = db.queryForList("SELECT * FROM preplan_supply_actions");
        var links = db.queryForList("SELECT * FROM production_material_analysis_plan_links");
        db.execute(sql());
        assertEquals(0, new BigDecimal("12000").compareTo(db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks", BigDecimal.class)));
        assertEquals(1L, db.queryForObject("SELECT version FROM preplan_subcontract_make_tasks", Long.class));
        assertEquals(actions, db.queryForList("SELECT * FROM preplan_supply_actions"));
        assertEquals(links, db.queryForList("SELECT * FROM production_material_analysis_plan_links"));
        db.execute(sql());
        assertEquals(1L, db.queryForObject("SELECT version FROM preplan_subcontract_make_tasks", Long.class), "Rehearsal is idempotent");
    }

    @Test void rejectsMissingOrSpuriousPublicActionsWithoutGuessingHistoricalIntent() throws Exception {
        for (var quantities : new String[][] {{"0", "2000"}, {"4000", "0"}}) {
            var db = fixture(quantities[0], quantities[1], "10000", "0");
            String migration = sql();
            var error = assertThrows(org.springframework.dao.DataAccessException.class, () -> db.execute(migration));
            assertTrue(error.getMessage().contains("V621 subcontract preparation source mismatch"));
            assertEquals(0, new BigDecimal("10000").compareTo(db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks", BigDecimal.class)));
            assertEquals(0L, db.queryForObject("SELECT version FROM preplan_subcontract_make_tasks", Long.class));
        }
    }

    @Test void refusesToReduceAProjectionBelowAlreadyProducedOutput() throws Exception {
        var db = fixture("0", "0", "12000", "11000");
        String migration = sql();
        assertThrows(org.springframework.dao.DataAccessException.class, () -> db.execute(migration));
        assertEquals(0, new BigDecimal("12000").compareTo(db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks", BigDecimal.class)));
    }

    private static String sql() throws Exception {
        return new ClassPathResource(MIGRATION).getContentAsString(StandardCharsets.UTF_8);
    }

    /** Isolated historical projection fixture; no production triggers are disabled. */
    private static JdbcTemplate fixture(String actionSurplus, String planSurplus, String required, String produced) {
        String schema = "v621_" + UUID.randomUUID().toString().replace("-", "");
        var admin = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        admin.execute("CREATE SCHEMA " + schema);
        String schemaUrl = POSTGRES.getJdbcUrl() + (POSTGRES.getJdbcUrl().contains("?") ? "&" : "?") + "currentSchema=" + schema;
        var db = new JdbcTemplate(new DriverManagerDataSource(schemaUrl,
                POSTGRES.getUsername(), POSTGRES.getPassword()));
        com.uten.imp.support.MigratedProjectionSchema.createTables(db,"620",
                "production_material_analysis_items","preplan_supply_actions",
                "production_material_analysis_plan_links","preplan_subcontract_make_tasks");
        UUID analysis = UUID.randomUUID(), item = UUID.randomUUID();
        db.update("INSERT INTO production_material_analysis_items(id,requested_qty) VALUES(?,10000)", item);
        db.update("INSERT INTO preplan_supply_actions(id,analysis_id,external_document_id,external_document_type,status,public_surplus_qty) VALUES(?,?,?,'SUBCONTRACT_MAKE_TASK','CREATED',?)",
                UUID.randomUUID(), analysis, item, new BigDecimal(actionSurplus));
        db.update("INSERT INTO production_material_analysis_plan_links(id,analysis_id,analysis_item_id,public_surplus_qty,allocation_status) VALUES(?,?,?,?,'APPROVED')",
                UUID.randomUUID(), analysis, item, new BigDecimal(planSurplus));
        db.update("INSERT INTO preplan_subcontract_make_tasks(id,analysis_id,preparation_item_id,status,required_qty,produced_qty,notified_qty,version,updated_at) VALUES(?,?,?,'ACTIVE',?,?,0,0,NULL)",
                UUID.randomUUID(), analysis, item, new BigDecimal(required), new BigDecimal(produced));
        return db;
    }
}
