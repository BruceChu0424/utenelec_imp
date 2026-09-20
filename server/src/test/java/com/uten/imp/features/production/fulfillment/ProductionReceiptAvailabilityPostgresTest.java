package com.uten.imp.features.production.fulfillment;

import java.math.BigDecimal;
import java.sql.DriverManager;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.testcontainers.containers.PostgreSQLContainer;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService.ReceiptKind;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionReceiptAvailabilityPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

    @BeforeAll
    static void start() {
        POSTGRES.start();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @ParameterizedTest
    @EnumSource(value = ReceiptKind.class, names = {"PURCHASE", "SUBCONTRACT", "MAKE"})
    void usesTheReceiptTypesFrozenQuantityAndOnlyEffectiveAllocations(ReceiptKind kind) throws Exception {
        try (var connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement()) {
            // Minimal real receipt schemas intentionally omit base_qty on procurement.
            statement.execute("CREATE TEMP TABLE purchase_receipt_items(id uuid, qty numeric, unit_rate numeric)");
            statement.execute("CREATE TEMP TABLE subcontract_receipt_items(id uuid, qty numeric, unit_rate numeric)");
            statement.execute("CREATE TEMP TABLE stock_document_items(id uuid, qty numeric, unit_rate numeric, base_qty numeric)");
            for (String table : new String[]{"production_material_receipt_allocations",
                    "production_material_subcontract_receipt_allocations", "production_material_make_receipt_allocations"}) {
                statement.execute("CREATE TEMP TABLE " + table
                        + "(receipt_item_id uuid, allocated_qty numeric, status text)");
            }
            UUID id = UUID.randomUUID();
            for (String table : new String[]{"purchase_receipt_items", "subcontract_receipt_items"}) {
                statement.execute("INSERT INTO " + table + " VALUES ('" + id + "', 0.125, 24)");
            }
            statement.execute("INSERT INTO stock_document_items VALUES ('" + id + "', 0.125, 24, 7)");
            for (String table : new String[]{"production_material_receipt_allocations",
                    "production_material_subcontract_receipt_allocations", "production_material_make_receipt_allocations"}) {
                statement.execute("INSERT INTO " + table + " VALUES ('" + id
                        + "', 0.75, 'EFFECTIVE'), ('" + id + "', 9, 'REVERSED')");
            }
            try (var query = connection.prepareStatement(kind.remainingQuantitySql().replace(":id", "?"))) {
                query.setObject(1, id);
                try (var result = query.executeQuery()) {
                    assertThat(result.next()).isTrue();
                    assertThat(result.getBigDecimal(1)).isEqualByComparingTo(
                            new BigDecimal(kind == ReceiptKind.MAKE ? "6.25" : "2.25"));
                }
            }
        }
    }

    @Test
    void nonReceiptSourcesCannotSelectAPhysicalReceiptTable() {
        for (ReceiptKind kind : new ReceiptKind[]{ReceiptKind.PREPLAN, ReceiptKind.RECHECK, ReceiptKind.RECONCILE}) {
            assertThatThrownBy(kind::remainingQuantitySql).isInstanceOf(IllegalArgumentException.class);
        }
    }
}
