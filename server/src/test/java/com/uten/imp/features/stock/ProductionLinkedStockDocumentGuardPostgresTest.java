package com.uten.imp.features.stock;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionLinkedStockDocumentGuardPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void genericCrudIsClosedButOperationalPostingRemainsOpen()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = createFixture(connection, "DRAW");

            assertConstraint(
                    connection,
                    "update stock_documents set remark = 'tampered' where id = ?",
                    fixture.documentId(),
                    "production_linked_stock_document_update_guard");
            assertConstraint(
                    connection,
                    "update stock_documents set is_deleted = true where id = ?",
                    fixture.documentId(),
                    "production_linked_stock_document_update_guard");
            assertConstraint(
                    connection,
                    "delete from stock_documents where id = ?",
                    fixture.documentId(),
                    "production_linked_stock_document_delete_guard");
            assertConstraint(
                    connection,
                    "update stock_document_items set qty = 2 where id = ?",
                    fixture.itemId(),
                    "production_linked_stock_document_item_update_guard");
            assertConstraint(
                    connection,
                    "delete from stock_document_items where id = ?",
                    fixture.itemId(),
                    "production_linked_stock_document_item_delete_guard");

            execute(
                    connection,
                    "update stock_documents set status = 1 where id = ?",
                    fixture.documentId());
            execute(
                    connection,
                    "update stock_document_items set issued_qty = 1 where id = ?",
                    fixture.itemId());

            assertEquals(
                    1,
                    scalarInt(
                            connection,
                            "select status from stock_documents where id = ?",
                            fixture.documentId()));
            assertEquals(
                    1,
                    scalarInt(
                            connection,
                            "select issued_qty::int from stock_document_items where id = ?",
                            fixture.itemId()));

            // V232: is_closed 是 recomputeIssueStatus 派生的生命周期字段（领料全出完=true/反出库=false），
            // 非身份列，必须允许翻转——否则生产链领料单无法完成出库（曾抛 23514 identity is immutable）。
            execute(
                    connection,
                    "update stock_documents set is_closed = true where id = ?",
                    fixture.documentId());
            assertEquals(
                    1,
                    scalarInt(
                            connection,
                            "select case when is_closed then 1 else 0 end"
                                    + " from stock_documents where id = ?",
                            fixture.documentId()));
        }
    }

    @Test
    void exactTransactionMarkerAllowsOnlyDraftReportCleanup()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = createFixture(connection, "FINISHED_IN");
            connection.setAutoCommit(false);
            try {
                try (PreparedStatement marker = connection.prepareStatement("""
                        select set_config(
                            'app.production_report_reverse_doc_id', ?, true)
                        """)) {
                    marker.setString(1, fixture.documentId().toString());
                    marker.executeQuery();
                }
                execute(
                        connection,
                        """
                        update stock_documents
                        set is_deleted = true, deleted_at = now()
                        where id = ?
                        """,
                        fixture.documentId());
                execute(
                        connection,
                        """
                        update stock_document_items
                        set is_deleted = true
                        where id = ?
                        """,
                        fixture.itemId());
                execute(
                        connection,
                        """
                        update plan_draw_links
                        set is_deleted = true, deleted_at = now()
                        where draw_id = ?
                        """,
                        fixture.documentId());
                connection.commit();
            } catch (Throwable error) {
                connection.rollback();
                throw error;
            } finally {
                connection.setAutoCommit(true);
            }

            assertEquals(
                    1,
                    scalarInt(
                            connection,
                            """
                            select count(*) from stock_documents
                            where id = ? and is_deleted = true
                            """,
                            fixture.documentId()));
            assertEquals(
                    1,
                    scalarInt(
                            connection,
                            """
                            select count(*) from stock_document_items
                            where id = ? and is_deleted = true
                            """,
                            fixture.itemId()));
        }
    }

    private static Fixture createFixture(
            Connection connection, String documentType) throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID documentId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 7, 31);
        String planNo = businessIdentifier("SJ", date);
        String documentNo = businessIdentifier(
                switch (documentType) {
                    case "DRAW" -> "SL";
                    case "FINISHED_IN" -> "CR";
                    default -> throw new IllegalArgumentException(
                            "unsupported stock document type: " + documentType);
                },
                date);

        execute(
                connection,
                "insert into units(id, code, name) values (?, ?, 'piece')",
                unitId, "UNIT-" + unitId);
        execute(
                connection,
                "insert into goods(id, code, name, code_sequence) "
                        + "values (?, ?, 'fixture', (select coalesce(max(code_sequence), 0) + 1 from goods))",
                goodsId, "GOODS-" + goodsId);
        execute(
                connection,
                "insert into warehouses(id, code, name) values (?, ?, 'fixture')",
                warehouseId, "WH-" + warehouseId);
        execute(
                connection,
                """
                insert into production_plans(id, bill_no, bill_date, status)
                values (?, ?, ?, 1)
                """,
                planId, planNo, date);
        execute(
                connection,
                """
                insert into stock_documents(
                    id, doc_type, bill_no, bill_date, warehouse_id, status)
                values (?, ?, ?, ?, ?, 0)
                """,
                documentId, documentType, documentNo, date,
                warehouseId);
        execute(
                connection,
                """
                insert into stock_document_items(
                    id, doc_id, bill_type, bill_no, bill_date, line_no,
                    goods_id, unit_id, qty, base_qty, goods_snapshot_source)
                values (?, ?, ?, ?, ?, 1, ?, ?, 1, 1, 'MASTER_AT_SAVE')
                """,
                itemId, documentId, documentType, documentNo,
                date, goodsId, unitId);
        execute(
                connection,
                """
                insert into plan_draw_links(plan_id, draw_id)
                values (?, ?)
                """,
                planId, documentId);
        return new Fixture(documentId, itemId);
    }

    private static void assertConstraint(
            Connection connection, String sql, UUID id, String constraint) {
        PSQLException error = assertThrows(
                PSQLException.class,
                () -> execute(connection, sql, id));
        assertEquals(
                constraint,
                error.getServerErrorMessage().getConstraint());
    }

    private static void execute(
            Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int i = 0; i < values.length; i++) {
                statement.setObject(i + 1, values[i]);
            }
            statement.executeUpdate();
        }
    }

    private static int scalarInt(
            Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (var result = statement.executeQuery()) {
                result.next();
                return result.getInt(1);
            }
        }
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private record Fixture(UUID documentId, UUID itemId) {
    }
}
