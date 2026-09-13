package com.uten.imp.features.documents;

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
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real migrated PostgreSQL regression for production tasks appearing twice in
 * warehouse totals: once in their task queue and again as status=0 stock drafts.
 * Only an isolated Testcontainers database is used. Every fixture is validated
 * with all deferred constraints before its assertions; cleanup is rollback.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionTaskDraftCountPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("production_task_draft_count")
                    .withUsername("uten")
                    .withPassword("uten");
    private static final AtomicInteger SEQUENCE = new AtomicInteger(800000);
    private static final LocalDate DATE = LocalDate.of(2026, 9, 12);

    @BeforeAll
    static void migrateRealSchema() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void productionDrawAndFinishedInboundAreNotCountedAgainButManualTypesRemain() throws Exception {
        try (Connection connection = connection()) {
            try {
                long before = stockDraftCount(connection);
                long transfersBefore = count(connection, DocumentDraftCountQueryService.STOCK_TRANSFER);
                long checksBefore = count(connection, DocumentDraftCountQueryService.STOCK_CHECK);
                UUID plan = insertPlan(connection);
                UUID automaticDraw = insertDocument(connection, "DRAW", 0, false);
                UUID automaticFinished = insertDocument(connection, "FINISHED_IN", 0, false);
                linkToPlan(connection, plan, automaticDraw, false);
                linkToPlan(connection, plan, automaticFinished, false);

                // Same document types are not themselves evidence of production ownership.
                List<UUID> manual = List.of(
                        insertDocument(connection, "DRAW", 0, false),
                        insertDocument(connection, "FINISHED_IN", 0, false),
                        insertDocument(connection, "TRANSFER", 0, false),
                        insertDocument(connection, "CHECK", 0, false));
                validateDeferredConstraints(connection);

                assertTrue(productionLinked(connection, automaticDraw));
                assertTrue(productionLinked(connection, automaticFinished));
                for (UUID document : manual) {
                    assertFalse(productionLinked(connection, document));
                }
                assertEquals(4, stockDraftCount(connection) - before,
                        "two production-owned drafts must not join the four manual drafts");
                assertEquals(1, count(connection, DocumentDraftCountQueryService.STOCK_TRANSFER) - transfersBefore);
                assertEquals(1, count(connection, DocumentDraftCountQueryService.STOCK_CHECK) - checksBefore);
                assertEquals(2, scalar(connection, """
                        SELECT count(*) FROM stock_documents
                        WHERE id IN (?, ?) AND status = 0 AND is_deleted = false
                        """, automaticDraw, automaticFinished),
                        "counting must leave both pending source documents unchanged");
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void statusAndSoftDeletionStillFilterEveryManualStockDocumentType() throws Exception {
        try (Connection connection = connection()) {
            try {
                long before = stockDraftCount(connection);
                List<String> types = List.of("DRAW", "FINISHED_IN", "TRANSFER", "CHECK",
                        "OTHER_IN", "OTHER_OUT");
                for (String type : types) {
                    insertDocument(connection, type, 0, false);
                    insertDocument(connection, type, 0, true);
                    insertDocument(connection, type, 1, false);
                    insertDocument(connection, type, -1, false);
                }
                validateDeferredConstraints(connection);

                assertEquals(types.size(), stockDraftCount(connection) - before,
                        "only the live status=0 row of each manual type belongs to the draft bucket");
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void displayNumbersAndInactiveLinksCannotReplaceAnActiveProductionUuid() throws Exception {
        try (Connection connection = connection()) {
            try {
                long before = stockDraftCount(connection);
                UUID plan = insertPlan(connection);
                UUID textOnly = insertDocument(connection, "DRAW", 0, false);
                UUID inactiveLink = insertDocument(connection, "FINISHED_IN", 0, false);
                execute(connection, """
                        UPDATE stock_documents
                        SET plan_no = (SELECT bill_no FROM production_plans WHERE id = ?),
                            source_doc_no = 'same-display-source'
                        WHERE id = ?
                        """, plan, textOnly);
                linkToPlan(connection, plan, inactiveLink, true);
                validateDeferredConstraints(connection);

                assertFalse(productionLinked(connection, textOnly));
                assertFalse(productionLinked(connection, inactiveLink));
                assertEquals(2, stockDraftCount(connection) - before,
                        "display numbers and inactive relations must not hide an otherwise manual draft");
            } finally {
                connection.rollback();
            }
        }
    }

    private static Connection connection() throws SQLException {
        Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        connection.setAutoCommit(false);
        return connection;
    }

    private static UUID insertPlan(Connection connection) throws SQLException {
        UUID id = UUID.randomUUID();
        execute(connection, """
                INSERT INTO production_plans(id, bill_no, bill_date, status)
                VALUES (?, ?, ?, 1)
                """, id, billNo("SJ"), DATE);
        return id;
    }

    private static UUID insertDocument(Connection connection, String type, int status, boolean deleted)
            throws SQLException {
        UUID id = UUID.randomUUID();
        String prefix = switch (type) {
            case "DRAW" -> "SL";
            case "FINISHED_IN" -> "CR";
            case "TRANSFER" -> "CB";
            case "CHECK" -> "PQ";
            case "OTHER_IN" -> "QR";
            case "OTHER_OUT" -> "QC";
            default -> throw new IllegalArgumentException("Unsupported stock type: " + type);
        };
        execute(connection, """
                INSERT INTO stock_documents(id, doc_type, bill_no, bill_date, status, is_deleted, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, CASE WHEN ? THEN now() END)
                """, id, type, billNo(prefix), DATE, (short) status, deleted, deleted);
        return id;
    }

    private static void linkToPlan(Connection connection, UUID plan, UUID document, boolean deleted)
            throws SQLException {
        execute(connection, """
                INSERT INTO plan_draw_links(plan_id, draw_id, is_deleted, deleted_at)
                VALUES (?, ?, ?, CASE WHEN ? THEN now() END)
                """, plan, document, deleted, deleted);
    }

    private static String billNo(String prefix) {
        return prefix + DATE.format(DateTimeFormatter.BASIC_ISO_DATE)
                + String.format(java.util.Locale.ROOT, "%06d", SEQUENCE.incrementAndGet());
    }

    private static void validateDeferredConstraints(Connection connection) throws SQLException {
        execute(connection, "SET CONSTRAINTS ALL IMMEDIATE");
    }

    private static boolean productionLinked(Connection connection, UUID document) throws SQLException {
        return scalar(connection,
                "SELECT CASE WHEN fn_is_production_linked_stock_document(?) THEN 1 ELSE 0 END",
                document) == 1;
    }

    private static long stockDraftCount(Connection connection) throws SQLException {
        return count(connection, DocumentDraftCountQueryService.STOCK_DOCUMENT);
    }

    private static long count(Connection connection, DocumentDraftCountQueryService.DraftSource source)
            throws SQLException {
        return scalar(connection, DocumentDraftCountQueryService.countSql(source, "1=1"));
    }

    private static long scalar(Connection connection, String sql, Object... parameters) throws SQLException {
        try (PreparedStatement statement = prepare(connection, sql, parameters);
             var result = statement.executeQuery()) {
            assertTrue(result.next());
            return result.getLong(1);
        }
    }

    private static void execute(Connection connection, String sql, Object... parameters) throws SQLException {
        try (PreparedStatement statement = prepare(connection, sql, parameters)) {
            statement.execute();
        }
    }

    private static PreparedStatement prepare(Connection connection, String sql, Object... parameters)
            throws SQLException {
        PreparedStatement statement = connection.prepareStatement(sql);
        for (int index = 0; index < parameters.length; index++) {
            statement.setObject(index + 1, parameters[index]);
        }
        return statement;
    }
}
