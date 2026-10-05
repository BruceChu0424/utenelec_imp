package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real V798 (ADR-143 §三.5) exact-lot functions, with only their input relations isolated in a disposable
 * PostgreSQL schema: an order item's frozen draw-plan line may take over the exact entitled lots of its source
 * analysis' child node, the claim ranges are partitioned over every live claimant of that child node and the lot
 * ranges are cut in event order, so one lot is never claimed twice and one material never releases another.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractComponentEntitledLotsPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ANALYSIS = id(1), PARENT_GOODS = id(2), CHILD_GOODS = id(3), SECOND_CHILD_GOODS = id(9);
    private static final UUID WAREHOUSE = id(4), ORDER_ITEM = id(6), PLAN_HEADER = id(7), PLAN = id(8), SECOND_PLAN = id(10);
    private Connection connection;

    @BeforeAll static void start() { DB.start(); }
    @AfterAll static void stop() { DB.stop(); }

    @BeforeEach void fixture() throws Exception {
        connection = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        connection.setAutoCommit(false);
        execute("CREATE SCHEMA entitled_lots_test; SET LOCAL search_path TO entitled_lots_test; SET LOCAL jit TO off");
        execute("""
                CREATE TABLE warehouses(id uuid PRIMARY KEY, is_deleted boolean DEFAULT false,
                    is_defective boolean DEFAULT false, is_line_side boolean DEFAULT false);
                CREATE TABLE subcontract_application_items(id uuid PRIMARY KEY, application_id uuid, goods_id uuid,
                    color_id uuid, qty numeric(18,4), is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_order_items(id uuid PRIMARY KEY, goods_id uuid, color_id uuid,
                    is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_order_item_sources(order_item_id uuid, application_item_id uuid, alloc_qty numeric(18,4));
                CREATE TABLE preplan_supply_actions(id uuid PRIMARY KEY, analysis_id uuid, route text, operation_type text,
                    status text, external_document_type text, external_document_id uuid, public_surplus_external_item_id uuid);
                CREATE TABLE preplan_supply_action_allocations(id uuid PRIMARY KEY, action_id uuid, analysis_id uuid,
                    analysis_material_id uuid, external_item_id uuid, allocated_qty numeric(18,4));
                CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY, analysis_id uuid,
                    analysis_item_id uuid, node_key text, parent_node_key text, node_role text DEFAULT 'BOM_COMPONENT',
                    depth integer, goods_id uuid, color_id uuid, active boolean DEFAULT true);
                CREATE TABLE subcontract_material_plans(id uuid PRIMARY KEY, status text DEFAULT 'OPEN', is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_plan_items(id uuid PRIMARY KEY, plan_id uuid, order_item_id uuid, line_no integer,
                    goods_id uuid, color_id uuid, bom_unit_qty numeric(18,6), is_deleted boolean DEFAULT false,
                    draw_closed_at timestamptz);
                CREATE TABLE stock_reservations(id uuid PRIMARY KEY, warehouse_id uuid, goods_id uuid, color_id uuid,
                    owner_type text, status smallint DEFAULT 0, is_deleted boolean DEFAULT false,
                    qty numeric(18,4), consumed_qty numeric(18,4) DEFAULT 0, released_qty numeric(18,4) DEFAULT 0);
                CREATE TABLE fixture_entitlement_lots(entitlement_event_id uuid PRIMARY KEY, stock_reservation_id uuid,
                    beneficiary_analysis_id uuid, beneficiary_analysis_material_id uuid,
                    source_exact_peg_id uuid, reallocation_id uuid, remaining_qty numeric(18,4));
                CREATE VIEW v_preplan_stock_entitlement_lot_balance AS SELECT * FROM fixture_entitlement_lots;
                CREATE TABLE subcontract_component_stock_handoffs(id uuid PRIMARY KEY, plan_item_id uuid,
                    application_item_id uuid, parent_material_id uuid, child_material_id uuid,
                    target_reservation_id uuid, qty numeric(18,4));
                """);
        // This focused fixture has one known operational warehouse; the production functions below are unmodified.
        execute("CREATE FUNCTION fn_warehouse_is_operational_leaf(uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM warehouses WHERE id=$1 AND NOT is_deleted) $$");
        String migration;
        try (var input = Objects.requireNonNull(getClass().getResourceAsStream(
                "/db/migration/V798__subcontract_step_draw.sql"))) {
            migration = new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
        execute(function(migration, "fn_subcontract_component_parent_capacity"));
        execute(function(migration, "fn_subcontract_component_entitled_lots"));
        update("INSERT INTO warehouses(id) VALUES (?)", WAREHOUSE);
        update("INSERT INTO subcontract_order_items(id,goods_id) VALUES (?,?)", ORDER_ITEM, PARENT_GOODS);
        update("INSERT INTO subcontract_material_plans(id) VALUES (?)", PLAN_HEADER);
        update("INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,line_no,goods_id,bom_unit_qty) VALUES (?,?,?,1,?,1)",
                PLAN, PLAN_HEADER, ORDER_ITEM, CHILD_GOODS);
    }

    @AfterEach void cleanup() throws Exception {
        if (connection != null) {
            connection.rollback();
            connection.close();
        }
    }

    @Test void oneLotIsPartitionedAcrossTwoApplicationsOfTheSameParent() throws Exception {
        parent(1);
        application(1, 1, "4");
        application(2, 1, "6");
        lot(1, child(1), "10");
        var rows = lots();
        assertThat(rows).containsExactly(
                new Slice(PLAN, app(1), event(1), child(1), parentId(1), new BigDecimal("4.0000")),
                new Slice(PLAN, app(2), event(1), child(1), parentId(1), new BigDecimal("6.0000")));
        assertThat(total(rows)).isEqualByComparingTo("10");
    }

    @Test void takingTheFirstApplicationLeavesTheSecondApplicationsSixUnitsVisible() throws Exception {
        parent(1);
        application(1, 1, "4");
        application(2, 1, "6");
        lot(1, child(1), "10");
        handoff(1, 1, "4");
        update("UPDATE stock_reservations SET released_qty=4 WHERE id=?", reservation(1));
        update("UPDATE fixture_entitlement_lots SET remaining_qty=6 WHERE entitlement_event_id=?", event(1));
        assertThat(lots()).containsExactly(
                new Slice(PLAN, app(2), event(1), child(1), parentId(1), new BigDecimal("6.0000")));
        // Approving the first issue consumes custody; it must not restore that application's capacity.
        update("UPDATE stock_reservations SET consumed_qty=4 WHERE id=?", target(1));
        assertThat(lots()).containsExactly(
                new Slice(PLAN, app(2), event(1), child(1), parentId(1), new BigDecimal("6.0000")));
    }

    @Test void multipleLotsAreSlicedAtTheApplicationBoundaryWithoutDoubleCounting() throws Exception {
        parent(1);
        application(1, 1, "4");
        application(2, 1, "6");
        lot(1, child(1), "3");
        lot(2, child(1), "7");
        var rows = lots();
        assertThat(rows).containsExactly(
                new Slice(PLAN, app(1), event(1), child(1), parentId(1), new BigDecimal("3.0000")),
                new Slice(PLAN, app(1), event(2), child(1), parentId(1), new BigDecimal("1.0000")),
                new Slice(PLAN, app(2), event(2), child(1), parentId(1), new BigDecimal("6.0000")));
        assertThat(total(rows.stream().filter(row -> row.event().equals(event(1))).toList())).isEqualByComparingTo("3");
        assertThat(total(rows.stream().filter(row -> row.event().equals(event(2))).toList())).isEqualByComparingTo("7");
    }

    @Test void sameSkuAndSameNodeKeysNeverLetOneParentsSurplusCoverAnotherParentsShortage() throws Exception {
        parent(1);
        parent(2);
        application(1, 1, "4");
        application(2, 2, "6");
        lot(1, child(1), "3");
        lot(2, child(1), "7");
        lot(3, child(2), "2");
        var rows = lots();
        assertThat(rows).containsExactly(
                new Slice(PLAN, app(1), event(1), child(1), parentId(1), new BigDecimal("3.0000")),
                new Slice(PLAN, app(1), event(2), child(1), parentId(1), new BigDecimal("1.0000")),
                new Slice(PLAN, app(2), event(3), child(2), parentId(2), new BigDecimal("2.0000")));
        assertThat(total(rows)).isEqualByComparingTo("6");
    }

    /** ADR-143 §六.6: one material's exact lots never release another material's frozen plan line. */
    @Test void eachFrozenPlanLineOnlySeesTheLotsOfItsOwnMaterialNode() throws Exception {
        update("INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,line_no,goods_id,bom_unit_qty) VALUES (?,?,?,2,?,2)",
                SECOND_PLAN, PLAN_HEADER, ORDER_ITEM, SECOND_CHILD_GOODS);
        parent(1);
        update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,parent_node_key,depth,goods_id) VALUES (?,?,?,'SECOND','P',2,?)",
                secondChild(1), ANALYSIS, id(3001), SECOND_CHILD_GOODS);
        application(1, 1, "5");
        lot(1, child(1), "5");
        lot(2, secondChild(1), "4", SECOND_CHILD_GOODS);
        assertThat(lots()).containsExactly(
                new Slice(PLAN, app(1), event(1), child(1), parentId(1), new BigDecimal("5.0000")),
                new Slice(SECOND_PLAN, app(1), event(2), secondChild(1), parentId(1), new BigDecimal("4.0000")));
        // Closing one material's draw line stops only that material's takeover.
        update("UPDATE subcontract_material_plan_items SET draw_closed_at=now() WHERE id=?", PLAN);
        assertThat(lots()).containsExactly(
                new Slice(SECOND_PLAN, app(1), event(2), secondChild(1), parentId(1), new BigDecimal("4.0000")));
    }

    private void parent(int number) throws Exception {
        update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,depth,goods_id) VALUES (?,?,?,'P',1,?)",
                parentId(number), ANALYSIS, id(3000 + number), PARENT_GOODS);
        update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,parent_node_key,depth,goods_id) VALUES (?,?,?,'CHILD','P',2,?)",
                child(number), ANALYSIS, id(3000 + number), CHILD_GOODS);
    }

    private void application(int number, int owner, String quantity) throws Exception {
        update("INSERT INTO subcontract_application_items(id,application_id,goods_id,qty) VALUES (?,?,?,?)",
                app(number), applicationHeader(number), PARENT_GOODS, new BigDecimal(quantity));
        update("""
                INSERT INTO preplan_supply_actions(id,analysis_id,route,operation_type,status,external_document_type,external_document_id)
                VALUES (?,?,'SUBCONTRACT','SUPPLY','CREATED','SUBCONTRACT_APPLICATION',?)
                """, id(400 + number), ANALYSIS, applicationHeader(number));
        update("INSERT INTO preplan_supply_action_allocations(id,action_id,analysis_id,analysis_material_id,external_item_id,allocated_qty) VALUES (?,?,?,?,?,?)",
                id(5000 + number * 10 + owner), id(400 + number), ANALYSIS, parentId(owner), app(number), new BigDecimal(quantity));
        update("INSERT INTO subcontract_order_item_sources(order_item_id,application_item_id,alloc_qty) VALUES (?,?,?)",
                ORDER_ITEM, app(number), new BigDecimal(quantity));
    }

    private void lot(int number, UUID material, String quantity) throws Exception {
        lot(number, material, quantity, CHILD_GOODS);
    }

    private void lot(int number, UUID material, String quantity, UUID goods) throws Exception {
        update("INSERT INTO stock_reservations(id,warehouse_id,goods_id,owner_type,qty) VALUES (?,?,?,'PREPLAN_ANALYSIS',?)",
                reservation(number), WAREHOUSE, goods, new BigDecimal(quantity));
        update("INSERT INTO fixture_entitlement_lots(entitlement_event_id,stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,remaining_qty) VALUES (?,?,?,?,?)",
                event(number), reservation(number), ANALYSIS, material, new BigDecimal(quantity));
    }

    private void handoff(int application, int owner, String quantity) throws Exception {
        update("INSERT INTO stock_reservations(id,warehouse_id,goods_id,owner_type,qty) VALUES (?,?,?,'SUBCONTRACT_OUTBOUND',?)",
                target(application), WAREHOUSE, CHILD_GOODS, new BigDecimal(quantity));
        update("""
                INSERT INTO subcontract_component_stock_handoffs(id,plan_item_id,application_item_id,parent_material_id,child_material_id,target_reservation_id,qty)
                VALUES (?,?,?,?,?,?,?)
                """, id(10000 + application), PLAN, app(application), parentId(owner), child(owner), target(application),
                new BigDecimal(quantity));
    }

    private List<Slice> lots() throws Exception {
        var rows = new ArrayList<Slice>();
        try (var query = connection.prepareStatement("""
                SELECT plan_item_id,application_item_id,entitlement_event_id,beneficiary_analysis_material_id,parent_material_id,remaining_qty
                FROM fn_subcontract_component_entitled_lots(?)
                ORDER BY plan_item_id,parent_material_id,application_item_id,entitlement_event_id
                """)) {
            query.setObject(1, ORDER_ITEM);
            try (var result = query.executeQuery()) {
                while (result.next()) rows.add(new Slice(result.getObject(1, UUID.class), result.getObject(2, UUID.class),
                        result.getObject(3, UUID.class), result.getObject(4, UUID.class), result.getObject(5, UUID.class),
                        result.getBigDecimal(6).setScale(4)));
            }
        }
        return rows;
    }

    private void execute(String sql) throws Exception {
        try (var statement = connection.createStatement()) { statement.execute(sql); }
    }

    private void update(String sql, Object... parameters) throws Exception {
        try (var statement = connection.prepareStatement(sql)) {
            for (int i = 0; i < parameters.length; i++) statement.setObject(i + 1, parameters[i]);
            statement.executeUpdate();
        }
    }

    private static String function(String migration, String name) {
        int start = migration.indexOf("CREATE FUNCTION " + name + "(");
        if (start < 0) start = migration.indexOf("CREATE OR REPLACE FUNCTION " + name + "(");
        assertThat(start).as("production migration function %s", name).isGreaterThanOrEqualTo(0);
        int end = migration.indexOf("$$;", start);
        assertThat(end).isGreaterThan(start);
        return migration.substring(start, end + 3);
    }

    private static BigDecimal total(List<Slice> rows) { return rows.stream().map(Slice::quantity).reduce(BigDecimal.ZERO, BigDecimal::add); }
    private static UUID id(int number) { return UUID.fromString("00000000-0000-0000-0000-%012d".formatted(number)); }
    private static UUID parentId(int n) { return id(1000 + n); }
    private static UUID child(int n) { return id(2000 + n); }
    private static UUID secondChild(int n) { return id(2500 + n); }
    private static UUID app(int n) { return id(200 + n); }
    private static UUID applicationHeader(int n) { return id(300 + n); }
    private static UUID event(int n) { return id(7000 + n); }
    private static UUID reservation(int n) { return id(8000 + n); }
    private static UUID target(int n) { return id(9000 + n); }
    private record Slice(UUID plan, UUID application, UUID event, UUID child, UUID parent, BigDecimal quantity) {}
}
