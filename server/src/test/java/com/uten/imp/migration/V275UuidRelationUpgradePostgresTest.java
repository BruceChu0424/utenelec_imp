package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class V275UuidRelationUpgradePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static final UUID HISTORICAL_DOCUMENT_ID = UUID.randomUUID();

    @BeforeAll
    static void migrateNonEmptySchema() throws Exception {
        POSTGRES.start();
        flyway("274").migrate();

        try (Connection connection = connection(); PreparedStatement insert =
                connection.prepareStatement("""
                        INSERT INTO stock_documents(
                            id, doc_type, bill_no, bill_date, source_doc_no
                        ) VALUES (?, 'CHECK', 'PD-V275-HISTORY', ?, ?)
                        """)) {
            insert.setObject(1, HISTORICAL_DOCUMENT_ID);
            insert.setObject(2, LocalDate.of(2026, 8, 14));
            insert.setString(3, "AUTHORIZED_BALANCE_ADJUSTMENT:legacy-request-001");
            insert.executeUpdate();
        }

        assertThat(flyway("275").migrate().migrationsExecuted).isEqualTo(1);
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void upgradeMovesControlledMarkerToUuidCommandRelationWithoutRewritingEvidence()
            throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertThat(text(statement, """
                    SELECT request_key
                    FROM stock_balance_adjustment_requests
                    WHERE stock_document_id='%s'
                    """.formatted(HISTORICAL_DOCUMENT_ID)))
                    .isEqualTo("legacy-request-001");
            assertThat(text(statement, """
                    SELECT source_doc_no
                    FROM stock_documents
                    WHERE id='%s'
                    """.formatted(HISTORICAL_DOCUMENT_ID)))
                    .isEqualTo("AUTHORIZED_BALANCE_ADJUSTMENT:legacy-request-001");
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM pg_indexes
                    WHERE schemaname='public'
                      AND indexname='ux_stock_documents_authorized_balance_adjustment_source'
                    """)).isZero();
        }
    }

    @Test
    void commandRelationIsUniqueRestrictiveAndAudited() throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM pg_constraint
                    WHERE conname='fk_stock_balance_adjustment_request_document'
                      AND contype='f'
                      AND confdeltype='r'
                    """)).isEqualTo(1);
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM pg_trigger
                    WHERE tgname='trg_audit_stock_balance_adjustment_requests'
                      AND NOT tgisinternal
                    """)).isEqualTo(1);
            assertThrows(SQLException.class, () -> statement.execute("""
                    DELETE FROM stock_documents
                    WHERE id='%s'
                    """.formatted(HISTORICAL_DOCUMENT_ID)));
        }
    }

    @Test
    void dailyReportUuidForeignKeysAreValidatedWhileLegacySnapshotGuardIsForwardOnly()
            throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM pg_constraint
                    WHERE conname IN ('fk_pdri_plan_item', 'fk_pdri_sales_order_item')
                      AND contype='f'
                      AND convalidated
                      AND confdeltype='r'
                    """)).isEqualTo(2);
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM pg_constraint
                    WHERE conname='ck_pdri_number_snapshots_require_uuid'
                      AND contype='c'
                      AND NOT convalidated
                    """)).isEqualTo(1);
        }
    }

    @Test
    void systemRootRegistryIsUuidRelatedAuditedAndImmutable() throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM system_master_category_registry registry
                    JOIN material_categories material ON material.id=registry.material_category_id
                    JOIN client_categories client ON client.id=registry.client_category_id
                    JOIN mould_categories mould ON mould.id=registry.mould_category_id
                    JOIN supplier_categories supplier ON supplier.id=registry.supplier_category_id
                    WHERE registry.id='27500000-0000-4000-8000-000000000001'
                    """)).isEqualTo(1);
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM pg_trigger
                    WHERE tgname IN (
                        'trg_audit_system_master_category_registry',
                        'trg_protect_system_master_category_registry'
                    ) AND NOT tgisinternal
                    """)).isEqualTo(2);
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM pg_trigger
                    WHERE tgname='trg_material_categories_protect_uncategorized'
                      AND NOT tgisinternal
                    """)).isEqualTo(1);
            assertThrows(SQLException.class, () -> statement.execute("""
                    UPDATE system_master_category_registry
                    SET client_category_id=client_category_id
                    """));
            assertThrows(SQLException.class, () -> statement.execute("""
                    DELETE FROM system_master_category_registry
                    """));
            assertThrows(SQLException.class, () -> statement.execute("""
                    UPDATE material_categories category
                    SET name='mutated system root'
                    FROM system_master_category_registry registry
                    WHERE category.id=registry.material_category_id
                    """));
            assertThrows(SQLException.class, () -> statement.execute("""
                    DELETE FROM material_categories category
                    USING system_master_category_registry registry
                    WHERE category.id=registry.material_category_id
                    """));

            statement.execute("""
                    INSERT INTO clients(code, name, category_id, status, code_sequence)
                    VALUES ('V275-RAW-UUID-ROOT', 'V275 raw writer', NULL, '使用', 9275001)
                    """);
            assertThat(number(statement, """
                    SELECT count(*)
                    FROM clients client
                    JOIN system_master_category_registry registry
                      ON registry.client_category_id=client.category_id
                    WHERE client.code='V275-RAW-UUID-ROOT'
                    """)).isEqualTo(1);
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static long number(Statement statement, String sql) throws SQLException {
        try (var result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }

    private static String text(Statement statement, String sql) throws SQLException {
        try (var result = statement.executeQuery(sql)) {
            result.next();
            return result.getString(1);
        }
    }
}
