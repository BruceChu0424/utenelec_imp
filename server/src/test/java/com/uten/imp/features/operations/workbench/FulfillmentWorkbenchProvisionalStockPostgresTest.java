package com.uten.imp.features.operations.workbench;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * PostgreSQL evidence that WAITING segments do not reserve partial kits and
 * that the purchase workbench does not overstate a shortage for free stock.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FulfillmentWorkbenchProvisionalStockPostgresTest {

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
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void freeStockIsSuggestedOnceByNeedDateWithoutBecomingAReservation()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);

            assertQuantity(
                    connection,
                    """
                    SELECT COUNT(*)
                    FROM v_fulfillment_workbench
                    WHERE department = 'WAREHOUSE'
                      AND task_id IN (?, ?, ?)
                    """,
                    "0",
                    fixture.earlyA(),
                    fixture.laterA(),
                    fixture.laterB());

            // A has six on hand and one safety-stock unit. The earlier demand
            // receives four units of advisory coverage; the later demand sees
            // the one remaining unit and therefore asks Purchase for three.
            assertNoPurchaseTask(connection, fixture.earlyA());
            assertOpenQty(connection, fixture.laterA(), "3");
            assertOpenQty(connection, fixture.laterB(), "4");

            update(
                    connection,
                    "UPDATE stock_balances SET qty = 10 WHERE id = ?",
                    fixture.balanceA());

            // Nine free A units now cover both four-unit WAITING demands.
            // Neither demand is reserved, and neither is shown as a purchase
            // request. B remains the only true shortage.
            assertNoPurchaseTask(connection, fixture.earlyA());
            assertNoPurchaseTask(connection, fixture.laterA());
            assertOpenQty(connection, fixture.laterB(), "4");
            assertQuantity(
                    connection,
                    """
                    SELECT COUNT(*)
                    FROM stock_reservations
                    WHERE demand_id IN (?, ?, ?)
                      AND is_deleted = FALSE
                    """,
                    "0",
                    fixture.earlyA(),
                    fixture.laterA(),
                    fixture.laterB());
        }
    }

    private static Fixture fixture(Connection connection) throws Exception {
        UUID warehouse = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        UUID materialA = UUID.randomUUID();
        UUID materialB = UUID.randomUUID();
        UUID product = UUID.randomUUID();
        UUID balanceA = UUID.randomUUID();
        UUID plan = UUID.randomUUID();
        UUID earlyPlanItem = UUID.randomUUID();
        UUID laterPlanItem = UUID.randomUUID();
        UUID planningPackage = UUID.randomUUID();
        UUID earlySegment = UUID.randomUUID();
        UUID laterSegment = UUID.randomUUID();
        UUID earlyA = UUID.randomUUID();
        UUID laterA = UUID.randomUUID();
        UUID laterB = UUID.randomUUID();

        insert(
                connection,
                "INSERT INTO warehouses(id,code,name) VALUES(?,?,'仓库')",
                warehouse,
                "W-" + warehouse);
        insert(
                connection,
                "INSERT INTO units(id,code,name) VALUES(?,?,'件')",
                unit,
                "U-" + unit);
        insert(
                connection,
                """
                INSERT INTO goods(id,code,name,min_qty)
                VALUES(?,?,'物料 A',1)
                """,
                materialA,
                "A-" + materialA);
        insert(
                connection,
                """
                INSERT INTO goods(id,code,name,min_qty)
                VALUES(?,?,'物料 B',0)
                """,
                materialB,
                "B-" + materialB);
        insert(
                connection,
                """
                INSERT INTO goods(id,code,name,min_qty)
                VALUES(?,?,'成品',0)
                """,
                product,
                "P-" + product);
        insert(
                connection,
                """
                INSERT INTO stock_balances(id,warehouse_id,goods_id,qty)
                VALUES(?,?,?,6)
                """,
                balanceA,
                warehouse,
                materialA);
        insert(
                connection,
                """
                INSERT INTO production_plans(
                    id,bill_no,bill_date,status,is_closed
                ) VALUES(?,?,?,1,FALSE)
                """,
                plan,
                "PLAN-" + plan,
                LocalDate.of(2026, 7, 31));
        insertPlanItem(connection, earlyPlanItem, plan, product, unit, "EARLY");
        insertPlanItem(connection, laterPlanItem, plan, product, unit, "LATER");

        connection.setAutoCommit(false);
        try {
            insert(
                    connection,
                    """
                    INSERT INTO production_planning_packages(
                        id,plan_id,warehouse_id,idempotency_key,request_hash,
                        preview_fingerprint,status,execution_model_version
                    ) VALUES(?,?,?,?,?,?,'CONFIRMED',1)
                    """,
                    planningPackage,
                    plan,
                    warehouse,
                    "PKG-" + planningPackage,
                    "a".repeat(64),
                    "b".repeat(64));
            insertSegment(
                    connection,
                    earlySegment,
                    planningPackage,
                    plan,
                    earlyPlanItem,
                    product,
                    unit,
                    1,
                    "EARLY",
                    LocalDate.of(2026, 8, 1));
            insertSegment(
                    connection,
                    laterSegment,
                    planningPackage,
                    plan,
                    laterPlanItem,
                    product,
                    unit,
                    2,
                    "LATER",
                    LocalDate.of(2026, 8, 2));
            insertDemand(
                    connection,
                    earlyA,
                    planningPackage,
                    plan,
                    warehouse,
                    materialA,
                    unit,
                    earlySegment,
                    earlyPlanItem,
                    LocalDate.of(2026, 8, 1));
            insertDemand(
                    connection,
                    laterA,
                    planningPackage,
                    plan,
                    warehouse,
                    materialA,
                    unit,
                    laterSegment,
                    laterPlanItem,
                    LocalDate.of(2026, 8, 2));
            insertDemand(
                    connection,
                    laterB,
                    planningPackage,
                    plan,
                    warehouse,
                    materialB,
                    unit,
                    laterSegment,
                    laterPlanItem,
                    LocalDate.of(2026, 8, 2));
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return new Fixture(balanceA, earlyA, laterA, laterB);
    }

    private static void insertPlanItem(
            Connection connection,
            UUID id,
            UUID plan,
            UUID goods,
            UUID unit,
            String productNo) throws Exception {
        insert(
                connection,
                """
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,goods_id,
                    unit_id,unit_rate,qty,fqty,iqty
                ) VALUES(?,?,?,?,?,?,?,1,4,0,0)
                """,
                id,
                "ITEM-" + id,
                LocalDate.of(2026, 7, 31),
                plan,
                productNo,
                goods,
                unit);
    }

    private static void insertSegment(
            Connection connection,
            UUID id,
            UUID planningPackage,
            UUID plan,
            UUID planItem,
            UUID goods,
            UUID unit,
            int number,
            String key,
            LocalDate begin) throws Exception {
        insert(
                connection,
                """
                INSERT INTO production_execution_segments(
                    id,package_id,plan_id,source_plan_item_id,segment_no,
                    segment_code,client_segment_key,product_goods_id,
                    product_unit_id,product_unit_rate,planned_qty,status,
                    plan_begin_date,bom_fingerprint,idempotency_key
                ) VALUES(?,?,?,?,?,?,?,?,?,1,4,'WAITING',?,?,?)
                """,
                id,
                planningPackage,
                plan,
                planItem,
                number,
                "SEG-" + key,
                key,
                goods,
                unit,
                begin,
                "c".repeat(64),
                "SEGMENT-" + id);
    }

    private static void insertDemand(
            Connection connection,
            UUID id,
            UUID planningPackage,
            UUID plan,
            UUID warehouse,
            UUID goods,
            UUID unit,
            UUID segment,
            UUID planItem,
            LocalDate needDate) throws Exception {
        insert(
                connection,
                """
                INSERT INTO production_material_demands(
                    id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                    required_qty,supply_route,status,idempotency_key,
                    execution_segment_id,source_plan_item_id,
                    per_product_qty,need_date
                ) VALUES(?,?,?,?,?,?,4,'BUY','WAITING_SUPPLY',?,?,?,?,?)
                """,
                id,
                planningPackage,
                plan,
                warehouse,
                goods,
                unit,
                "DEMAND-" + id,
                segment,
                planItem,
                BigDecimal.ONE,
                needDate);
    }

    private static void assertNoPurchaseTask(
            Connection connection,
            UUID demandId) throws Exception {
        assertQuantity(
                connection,
                """
                SELECT COUNT(*)
                FROM v_fulfillment_workbench
                WHERE department = 'PURCHASE' AND task_id = ?
                """,
                "0",
                demandId);
    }

    private static void assertOpenQty(
            Connection connection,
            UUID demandId,
            String expected) throws Exception {
        assertQuantity(
                connection,
                """
                SELECT open_qty
                FROM v_fulfillment_workbench
                WHERE department = 'PURCHASE' AND task_id = ?
                """,
                expected,
                demandId);
    }

    private static void assertQuantity(
            Connection connection,
            String sql,
            String expected,
            Object... parameters) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) {
                statement.setObject(index + 1, parameters[index]);
            }
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                assertEquals(
                        0,
                        new BigDecimal(expected).compareTo(
                                new BigDecimal(result.getObject(1).toString())));
            }
        }
    }

    private static void insert(
            Connection connection,
            String sql,
            Object... parameters) throws Exception {
        update(connection, sql, parameters);
    }

    private static void update(
            Connection connection,
            String sql,
            Object... parameters) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) {
                statement.setObject(index + 1, parameters[index]);
            }
            statement.executeUpdate();
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private record Fixture(
            UUID balanceA,
            UUID earlyA,
            UUID laterA,
            UUID laterB) {
    }
}
