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

/** Real V646 functions, with only their input relations isolated in a disposable PostgreSQL schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractComponentEntitledLotsPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ANALYSIS = id(1), PARENT_GOODS = id(2), CHILD_GOODS = id(3);
    private static final UUID WAREHOUSE = id(4), EDGE = id(5), ORDER_ITEM = id(6), PLAN = id(7);
    private Connection connection;

    @BeforeAll static void start() { DB.start(); }
    @AfterAll static void stop() { DB.stop(); }

    @BeforeEach void fixture() throws Exception {
        connection = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        connection.setAutoCommit(false);
        execute("CREATE SCHEMA entitled_lots_test; SET LOCAL search_path TO entitled_lots_test; SET LOCAL jit TO off");
        execute("""
                CREATE TABLE goods(id uuid PRIMARY KEY, is_deleted boolean DEFAULT false, auto_created boolean DEFAULT false);
                CREATE TABLE goods_bom_items(id uuid PRIMARY KEY, goods_id uuid, component_goods_id uuid,
                    color_id uuid, qty numeric, consumption_basis text, control_stage text, is_deleted boolean DEFAULT false);
                CREATE TABLE warehouses(id uuid PRIMARY KEY, is_deleted boolean DEFAULT false,
                    is_defective boolean DEFAULT false, is_line_side boolean DEFAULT false);
                CREATE TABLE subcontract_application_items(id uuid PRIMARY KEY, goods_id uuid, color_id uuid,
                    qty numeric(18,4), unit_rate numeric(18,6) DEFAULT 1, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_order_items(id uuid PRIMARY KEY, unit_rate numeric(18,6) DEFAULT 1);
                CREATE TABLE subcontract_order_item_sources(order_item_id uuid, application_item_id uuid, alloc_qty numeric(18,4));
                CREATE TABLE preplan_supply_actions(id uuid PRIMARY KEY, analysis_id uuid, route text,
                    status text, external_document_type text, public_surplus_external_item_id uuid);
                CREATE TABLE preplan_supply_action_allocations(id uuid PRIMARY KEY, action_id uuid, analysis_id uuid,
                    analysis_material_id uuid, external_item_id uuid, allocated_qty numeric(18,4));
                CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY, analysis_id uuid,
                    analysis_item_id uuid, node_key text, parent_node_key text, bom_item_id uuid,
                    goods_id uuid, color_id uuid, active boolean DEFAULT true);
                CREATE TABLE stock_reservations(id uuid PRIMARY KEY, warehouse_id uuid, goods_id uuid, color_id uuid,
                    owner_type text, status smallint DEFAULT 0, is_deleted boolean DEFAULT false,
                    qty numeric(18,4), consumed_qty numeric(18,4) DEFAULT 0, released_qty numeric(18,4) DEFAULT 0);
                CREATE TABLE fixture_entitlement_lots(entitlement_event_id uuid PRIMARY KEY, stock_reservation_id uuid,
                    beneficiary_analysis_id uuid, beneficiary_analysis_material_id uuid,
                    source_exact_peg_id uuid, reallocation_id uuid, remaining_qty numeric(18,4));
                CREATE VIEW v_preplan_stock_entitlement_lot_balance AS SELECT * FROM fixture_entitlement_lots;
                CREATE TABLE subcontract_material_plan_items(id uuid PRIMARY KEY, order_item_id uuid);
                CREATE TABLE subcontract_component_stock_handoffs(id uuid PRIMARY KEY, plan_item_id uuid,
                    application_item_id uuid, child_material_id uuid, target_reservation_id uuid, qty numeric(18,4));
                """);
        // This focused fixture has one known operational warehouse; the production functions below are unmodified.
        execute("CREATE FUNCTION fn_warehouse_is_operational_leaf(uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM warehouses WHERE id=$1 AND NOT is_deleted) $$");
        String migration;
        try (var input = Objects.requireNonNull(getClass().getResourceAsStream(
                "/db/migration/V646__subcontract_component_exact_stock_handoff.sql"))) {
            migration = new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
        execute(function(migration, "fn_subcontract_sole_component_goods"));
        execute(function(migration, "fn_subcontract_component_parent_capacity"));
        execute(function(migration, "fn_subcontract_component_entitled_lots"));
        update("INSERT INTO goods(id) VALUES (?),(?)", PARENT_GOODS, CHILD_GOODS);
        update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,consumption_basis,control_stage) VALUES (?,?,?,1,'PER_UNIT','START')",
                EDGE, PARENT_GOODS, CHILD_GOODS);
        update("INSERT INTO warehouses(id) VALUES (?)", WAREHOUSE);
        update("INSERT INTO subcontract_order_items(id) VALUES (?)", ORDER_ITEM);
        update("INSERT INTO subcontract_material_plan_items VALUES (?,?)", PLAN, ORDER_ITEM);
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
        lot(1, 1, "10");
        var rows = lots();
        assertThat(rows).containsExactly(
                new Slice(app(1), event(1), child(1), parentId(1), new BigDecimal("4.0000")),
                new Slice(app(2), event(1), child(1), parentId(1), new BigDecimal("6.0000")));
        assertThat(total(rows)).isEqualByComparingTo("10");
    }

    @Test void takingTheFirstApplicationLeavesTheSecondApplicationsSixUnitsVisible() throws Exception {
        parent(1);
        application(1, 1, "4");
        application(2, 1, "6");
        lot(1, 1, "10");
        handoff(1, 1, "4");
        update("UPDATE stock_reservations SET released_qty=4 WHERE id=?", reservation(1));
        update("UPDATE fixture_entitlement_lots SET remaining_qty=6 WHERE entitlement_event_id=?", event(1));
        assertThat(lots()).containsExactly(
                new Slice(app(2), event(1), child(1), parentId(1), new BigDecimal("6.0000")));
        // Approving the first issue consumes custody; it must not restore that application's capacity.
        update("UPDATE stock_reservations SET consumed_qty=4 WHERE id=?", target(1));
        assertThat(lots()).containsExactly(
                new Slice(app(2), event(1), child(1), parentId(1), new BigDecimal("6.0000")));
    }

    @Test void multipleLotsAreSlicedAtTheApplicationBoundaryWithoutDoubleCounting() throws Exception {
        parent(1);
        application(1, 1, "4");
        application(2, 1, "6");
        lot(1, 1, "3");
        lot(2, 1, "7");
        var rows = lots();
        assertThat(rows).containsExactly(
                new Slice(app(1), event(1), child(1), parentId(1), new BigDecimal("3.0000")),
                new Slice(app(1), event(2), child(1), parentId(1), new BigDecimal("1.0000")),
                new Slice(app(2), event(2), child(1), parentId(1), new BigDecimal("6.0000")));
        assertThat(total(rows.stream().filter(row -> row.event().equals(event(1))).toList())).isEqualByComparingTo("3");
        assertThat(total(rows.stream().filter(row -> row.event().equals(event(2))).toList())).isEqualByComparingTo("7");
    }

    @Test void sameSkuAndSameNodeKeysNeverLetOneParentsSurplusCoverAnotherParentsShortage() throws Exception {
        parent(1);
        parent(2);
        application(1, 1, "4");
        application(2, 2, "6");
        lot(1, 1, "3");
        lot(2, 1, "7");
        lot(3, 2, "2");
        var rows = lots();
        assertThat(rows).containsExactly(
                new Slice(app(1), event(1), child(1), parentId(1), new BigDecimal("3.0000")),
                new Slice(app(1), event(2), child(1), parentId(1), new BigDecimal("1.0000")),
                new Slice(app(2), event(3), child(2), parentId(2), new BigDecimal("2.0000")));
        assertThat(total(rows)).isEqualByComparingTo("6");
    }

    private void parent(int number) throws Exception {
        update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,goods_id) VALUES (?,?,?,'ROOT',?)",
                parentId(number), ANALYSIS, id(3000 + number), PARENT_GOODS);
        update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,parent_node_key,bom_item_id,goods_id) VALUES (?,?,?,'CHILD','ROOT',?,?)",
                child(number), ANALYSIS, id(3000 + number), EDGE, CHILD_GOODS);
    }

    private void application(int number, int owner, String quantity) throws Exception {
        update("INSERT INTO subcontract_application_items(id,goods_id,qty) VALUES (?,?,?)", app(number), PARENT_GOODS, new BigDecimal(quantity));
        update("INSERT INTO preplan_supply_actions(id,analysis_id,route,status,external_document_type) VALUES (?,?,'SUBCONTRACT','CREATED','SUBCONTRACT_APPLICATION')",
                id(400 + number), ANALYSIS);
        allocation(number, owner, quantity);
        update("INSERT INTO subcontract_order_item_sources VALUES (?,?,?)", ORDER_ITEM, app(number), new BigDecimal(quantity));
    }

    private void allocation(int application, int owner, String quantity) throws Exception {
        update("INSERT INTO preplan_supply_action_allocations VALUES (?,?,?,?,?,?)", id(5000 + application * 10 + owner),
                id(400 + application), ANALYSIS, parentId(owner), app(application), new BigDecimal(quantity));
    }

    private void lot(int number, int owner, String quantity) throws Exception {
        update("INSERT INTO stock_reservations(id,warehouse_id,goods_id,owner_type,qty) VALUES (?,?,?,'PREPLAN_ANALYSIS',?)",
                reservation(number), WAREHOUSE, CHILD_GOODS, new BigDecimal(quantity));
        update("INSERT INTO fixture_entitlement_lots(entitlement_event_id,stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,remaining_qty) VALUES (?,?,?,?,?)",
                event(number), reservation(number), ANALYSIS, child(owner), new BigDecimal(quantity));
    }

    private void handoff(int application, int owner, String quantity) throws Exception {
        update("INSERT INTO stock_reservations(id,warehouse_id,goods_id,owner_type,qty) VALUES (?,?,?,'SUBCONTRACT_OUTBOUND',?)",
                target(application), WAREHOUSE, CHILD_GOODS, new BigDecimal(quantity));
        update("INSERT INTO subcontract_component_stock_handoffs VALUES (?,?,?,?,?,?)", id(10000 + application), PLAN,
                app(application), child(owner), target(application), new BigDecimal(quantity));
    }

    private List<Slice> lots() throws Exception {
        var rows = new ArrayList<Slice>();
        try (var query = connection.prepareStatement("SELECT application_item_id,entitlement_event_id,beneficiary_analysis_material_id,parent_material_id,remaining_qty FROM fn_subcontract_component_entitled_lots(NULL,?) ORDER BY parent_material_id,application_item_id,entitlement_event_id")) {
            query.setObject(1, ORDER_ITEM);
            try (var result = query.executeQuery()) {
                while (result.next()) rows.add(new Slice(result.getObject(1, UUID.class), result.getObject(2, UUID.class),
                        result.getObject(3, UUID.class), result.getObject(4, UUID.class), result.getBigDecimal(5).setScale(4)));
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
    private static UUID app(int n) { return id(200 + n); }
    private static UUID event(int n) { return id(7000 + n); }
    private static UUID reservation(int n) { return id(8000 + n); }
    private static UUID target(int n) { return id(9000 + n); }
    private record Slice(UUID application, UUID event, UUID child, UUID parent, BigDecimal quantity) {}
}
