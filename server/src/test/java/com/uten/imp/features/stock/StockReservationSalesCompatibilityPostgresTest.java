package com.uten.imp.features.stock;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.Duration;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Verifies that V150's generic production allocation columns remain compatible
 * with the existing sales JPA insert shape, which does not populate them.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class StockReservationSalesCompatibilityPostgresTest {

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
    void legacySalesInsertGetsGenericOwnerDefaultsBeforeConstraints() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                UUID goodsId = UUID.randomUUID();
                UUID warehouseId = UUID.randomUUID();
                UUID orderItemId = UUID.randomUUID();
                UUID reservationId = UUID.randomUUID();

                try (PreparedStatement goods = connection.prepareStatement("""
                        insert into goods(id, code, name, min_qty)
                        values (?, ?, 'sales compatibility material', 0)
                        """);
                     PreparedStatement warehouse = connection.prepareStatement("""
                             insert into warehouses(id, code, name)
                             values (?, ?, 'sales compatibility warehouse')
                             """)) {
                    goods.setObject(1, goodsId);
                    goods.setString(2, "GOODS-" + goodsId);
                    goods.executeUpdate();

                    warehouse.setObject(1, warehouseId);
                    warehouse.setString(2, "WH-" + warehouseId);
                    warehouse.executeUpdate();
                }

                try (PreparedStatement reservation = connection.prepareStatement("""
                        insert into stock_reservations(
                            id, order_item_id, goods_id, warehouse_id,
                            qty, status, source, source_doc_type
                        )
                        values (?, ?, ?, ?, 5, 0, 0, 'SALES_ORDER')
                        """)) {
                    reservation.setObject(1, reservationId);
                    reservation.setObject(2, orderItemId);
                    reservation.setObject(3, goodsId);
                    reservation.setObject(4, warehouseId);
                    reservation.executeUpdate();
                }

                try (PreparedStatement query = connection.prepareStatement("""
                        select owner_type, owner_id, purpose, demand_id
                        from stock_reservations
                        where id = ?
                        """)) {
                    query.setObject(1, reservationId);
                    try (ResultSet result = query.executeQuery()) {
                        assertTrue(result.next());
                        assertEquals("SALES_ORDER_ITEM", result.getString(1));
                        assertEquals(orderItemId, result.getObject(2, UUID.class));
                        assertEquals("SALES_FULFILLMENT", result.getString(3));
                        assertNull(result.getObject(4));
                    }
                }
            }
        });
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }
}
