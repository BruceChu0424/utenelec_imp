package com.uten.imp.features.stock;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

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

    private static MigratedSchemaBaseline.ScopedDatabase POSTGRES;

    @BeforeAll
    static void migrate() throws Exception {
        POSTGRES = MigratedSchemaBaseline.openDatabase("measurement_c5ca839bf159");
    }

    @AfterAll
    static void stopPostgres() throws Exception {
        if (POSTGRES != null) POSTGRES.close();
    }

    @Test
    void legacySalesInsertGetsGenericOwnerDefaultsBeforeConstraints() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                UUID goodsId = UUID.randomUUID();
                UUID warehouseId = UUID.randomUUID();
                UUID orderItemId = UUID.randomUUID();
                UUID reservationId = UUID.randomUUID();
                UUID unitId = UUID.randomUUID();
                try(var unit=connection.prepareStatement("INSERT INTO units(id,code,name) VALUES(?,?,'piece')")) {
                    unit.setObject(1,unitId);unit.setString(2,"U-"+unitId);unit.executeUpdate();
                }

                try (PreparedStatement goods = connection.prepareStatement("""
                        insert into goods(id, code, name, min_qty, code_sequence,unit_id)
                        values (?, ?, 'sales compatibility material', 0,
                                (select coalesce(max(code_sequence), 0) + 1 from goods),?)
                        """);
                     PreparedStatement warehouse = connection.prepareStatement("""
                             insert into warehouses(id, code, name)
                             values (?, ?, 'sales compatibility warehouse')
                             """)) {
                    goods.setObject(1, goodsId);
                    goods.setString(2, "GOODS-" + goodsId);
                    goods.setObject(3, unitId);
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
