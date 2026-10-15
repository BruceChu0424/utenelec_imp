package com.uten.imp.features.subcontract.kit;

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
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V868 batch authority against the actual V809/V854 oracle in one disposable PostgreSQL schema.
 * This includes deterministic linear work, complete field equivalence, and two-connection watermark concurrency.
 * 真函数体只把输入关系隔离进一次性 schema:
 * 专属批次只给它自己的申请用, 同申请已有订货单先占专属批次、不够再占公共库存, 已批准的只占还要领的量,
 * 合并行按来源拆到 4 位小数恰好等于本行需要, 「可下单 N」下出的单恰好通过订货单齐套检查。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractKitBatchAuthorityPostgresTest {

    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ANALYSIS = id(1), PARENT_GOODS = id(2), MATERIAL = id(3), WAREHOUSE = id(4);
    private static final String[] V798_FUNCTIONS = {"fn_subcontract_draw_f", "fn_subcontract_draw_sets",
            "fn_subcontract_draw_edges"};
    private static final String[] V809_FUNCTIONS = {"fn_subcontract_application_exact_qty",
            "fn_subcontract_order_item_component_need", "fn_subcontract_component_pool_demands",
            "fn_subcontract_component_public_qty", "fn_subcontract_component_public_free",
            "fn_subcontract_application_kit_facts", "fn_subcontract_application_kit_qty",
            "fn_subcontract_application_open_qty", "fn_subcontract_application_orderable_qty",
            "fn_subcontract_order_kit_shortages"};
    private Connection connection;

    @BeforeAll static void start() { DB.start(); }
    @AfterAll static void stop() { DB.stop(); }

    @BeforeEach void fixture() throws Exception {
        connection = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        connection.setAutoCommit(false);
        execute("CREATE SCHEMA kit_test; SET LOCAL search_path TO kit_test; SET LOCAL jit TO off");
        execute("""
                CREATE TABLE warehouses(id uuid PRIMARY KEY, is_deleted boolean DEFAULT false,
                    is_defective boolean DEFAULT false, is_line_side boolean DEFAULT false);
                CREATE TABLE goods(id uuid PRIMARY KEY, color_id uuid, is_deleted boolean DEFAULT false,
                    auto_created boolean DEFAULT false, issue_method text DEFAULT 'PER_ORDER');
                CREATE TABLE goods_bom_items(id uuid PRIMARY KEY, goods_id uuid, component_goods_id uuid, color_id uuid,
                    qty numeric(18,6), is_deleted boolean DEFAULT false, consumption_basis text DEFAULT 'PER_UNIT',
                    control_stage text DEFAULT 'START', sort_order integer DEFAULT 1);
                CREATE TABLE subcontract_applications(id uuid PRIMARY KEY, status smallint DEFAULT 1,
                    is_deleted boolean DEFAULT false, is_closed boolean DEFAULT false);
                CREATE TABLE subcontract_application_items(id uuid PRIMARY KEY, application_id uuid, goods_id uuid,
                    color_id uuid, unit_rate numeric(18,6) DEFAULT 1, qty numeric(18,4), ordered_qty numeric(18,4) DEFAULT 0,
                    is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_orders(id uuid PRIMARY KEY, status smallint DEFAULT 0,
                    is_deleted boolean DEFAULT false, is_closed boolean DEFAULT false);
                CREATE TABLE subcontract_order_items(id uuid PRIMARY KEY, order_id uuid, goods_id uuid, color_id uuid,
                    qty numeric(18,4), unit_rate numeric(18,6) DEFAULT 1, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_order_item_sources(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    order_item_id uuid, application_item_id uuid, alloc_qty numeric(18,4), line_no integer);
                CREATE TABLE procurement_order_approval_cases(order_type text, order_id uuid, status text,
                    attempt integer DEFAULT 1, UNIQUE(order_type,order_id,attempt));
                CREATE TABLE subcontract_material_plans(id uuid PRIMARY KEY, status text DEFAULT 'OPEN',
                    is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_plan_items(id uuid PRIMARY KEY, plan_id uuid, order_item_id uuid,
                    line_no integer, goods_id uuid, color_id uuid, bom_unit_qty numeric(18,6), planned_qty numeric(18,4),
                    issued_qty numeric(18,4) DEFAULT 0, is_deleted boolean DEFAULT false, draw_closed_at timestamptz);
                CREATE TABLE subcontract_material_issues(id uuid PRIMARY KEY, status smallint, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_issue_items(id uuid PRIMARY KEY, issue_id uuid, plan_item_id uuid,
                    qty numeric(18,4), is_deleted boolean DEFAULT false);
                CREATE TABLE preplan_supply_actions(id uuid PRIMARY KEY, analysis_id uuid, route text, operation_type text,
                    status text, external_document_type text, external_document_id uuid, public_surplus_external_item_id uuid);
                CREATE TABLE preplan_supply_action_allocations(id uuid PRIMARY KEY, action_id uuid, analysis_id uuid,
                    analysis_material_id uuid, external_item_id uuid, allocated_qty numeric(18,4));
                CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY, analysis_id uuid,
                    analysis_item_id uuid, node_key text, parent_node_key text, node_role text DEFAULT 'BOM_COMPONENT',
                    depth integer, goods_id uuid, color_id uuid, active boolean DEFAULT true);
                CREATE TABLE stock_reservations(id uuid PRIMARY KEY, warehouse_id uuid, goods_id uuid, color_id uuid,
                    owner_type text, status smallint DEFAULT 0, is_deleted boolean DEFAULT false,
                    qty numeric(18,4), consumed_qty numeric(18,4) DEFAULT 0, released_qty numeric(18,4) DEFAULT 0);
                CREATE TABLE fixture_entitlement_lots(entitlement_event_id uuid PRIMARY KEY, stock_reservation_id uuid,
                    beneficiary_analysis_id uuid, beneficiary_analysis_material_id uuid, remaining_qty numeric(18,4));
                CREATE VIEW v_preplan_stock_entitlement_lot_balance AS SELECT * FROM fixture_entitlement_lots;
                CREATE TABLE fixture_public_stock(warehouse_id uuid, goods_id uuid, color_id uuid, available_qty numeric(18,4));
                CREATE VIEW v_stock_available AS SELECT * FROM fixture_public_stock;
                """);
        // 这个聚焦夹具只有一个可用仓; 领料「还要领」的上限这里只取计划量(委外商自带料另有用例覆盖)。
        execute("""
                CREATE FUNCTION fn_warehouse_counts_as_usable(uuid) RETURNS boolean LANGUAGE sql STABLE
                AS $$ SELECT EXISTS (SELECT 1 FROM warehouses WHERE id=$1 AND NOT is_deleted) $$;
                CREATE FUNCTION fn_subcontract_draw_needed_qty(uuid, numeric, numeric) RETURNS numeric LANGUAGE sql STABLE
                AS $$ SELECT $2 $$;
                """);
        String v798 = migration("V798__subcontract_step_draw.sql");
        for (String name : V798_FUNCTIONS) execute(function(v798, name, "$$;"));
        String v809 = migration("V809__subcontract_application_kit_lock.sql");
        for (String name : V809_FUNCTIONS) execute(function(v809, name, "$function$;"));
        String v854 = migration("V854__procurement_returned_source_commitments.sql");
        execute(function(v854,"fn_procurement_order_latest_approval_status","$function$;"));
        execute(function(v854,"fn_subcontract_application_open_qty","$function$;"));

        // Independent old V809 + latest V854 oracle, operating on the very same
        // disposable fixture. It is test-only and never installed in production.
        var names = new java.util.ArrayList<String>(java.util.List.of(V809_FUNCTIONS));
        names.add("fn_procurement_order_latest_approval_status");
        for (String name : V809_FUNCTIONS) {
            String definition = function(v809, name, "$function$;");
            if (name.equals("fn_subcontract_application_open_qty"))
                definition = function(v854, name, "$function$;");
            for (String original : names.stream().sorted(java.util.Comparator.comparingInt(String::length).reversed()).toList())
                definition = definition.replaceAll("\\b"+original+"\\b", "oracle_"+original);
            if (name.equals("fn_subcontract_application_open_qty")) {
                String latest = function(v854,"fn_procurement_order_latest_approval_status","$function$;");
                execute(latest.replace("fn_procurement_order_latest_approval_status", "oracle_fn_procurement_order_latest_approval_status"));
            }
            execute(definition);
        }
        execute(migration("V868__subcontract_kit_batch_authority.sql"));

        update("INSERT INTO warehouses(id) VALUES (?)", WAREHOUSE);
        update("INSERT INTO goods(id) VALUES (?), (?)", PARENT_GOODS, MATERIAL);
        update("INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty) VALUES (?, ?, ?, 1)",
                id(50), PARENT_GOODS, MATERIAL);
    }

    @AfterEach void cleanup() throws Exception {
        if (connection != null) {
            connection.rollback();
            execute("DROP SCHEMA IF EXISTS kit_test CASCADE");
            connection.commit();
            connection.close();
        }
    }

    /** 分析分给申请的专属批次只让这张申请齐套; 没有来源申请的手工委外单只能用公共库存。 */
    @Test void exclusiveLotsKitTheirOwnApplicationButNeverAManualOrder() throws Exception {
        application(1, "30");
        lot(1, 1, "30");
        Map<String, BigDecimal> facts = facts(1);
        assertThat(facts.get("exact_qty")).isEqualByComparingTo("30");
        assertThat(facts.get("public_qty")).isEqualByComparingTo("0");
        assertThat(scalar("SELECT fn_subcontract_application_orderable_qty(?)", app(1))).isEqualByComparingTo("30");

        order(1, (short) 0);
        orderItem(1, 1, "1");
        assertThat(shortages(1)).as("手工单拿不到专属批次").hasSize(1);

        update("UPDATE subcontract_orders SET is_deleted = true WHERE id = ?", orderId(1));
        order(2, (short) 0);
        orderItem(2, 2, "30");
        source(2, 1, "30");
        assertThat(shortages(2)).as("从申请下 30 套由专属批次齐套").isEmpty();
        order(3, (short) 0);
        orderItem(3, 3, "1");
        source(3, 1, "1");
        assertThat(shortages(3)).as("专属批次已被同申请的草稿占满, 再下 1 套不够").hasSize(1);
    }

    /** 同申请已有的订货单先用专属批次, 不够的部分占公共库存; 别的申请只能用公共库存剩下的。 */
    @Test void sameApplicationOrdersUseItsLotsFirstAndOverflowIntoPublicStock() throws Exception {
        application(1, "100");
        application(2, "100");
        lot(1, 1, "30");
        publicStock("20");
        order(1, (short) 0);
        orderItem(1, 1, "40");
        source(1, 1, "40");
        Map<String, BigDecimal> first = facts(1);
        assertThat(first.get("exact_claimed_qty")).isEqualByComparingTo("40");
        assertThat(first.get("exact_free_qty")).isEqualByComparingTo("0");
        assertThat(first.get("public_claimed_qty")).as("专属 30 不够, 溢出 10 占公共").isEqualByComparingTo("10");
        assertThat(first.get("public_free_qty")).isEqualByComparingTo("10");
        assertThat(first.get("kit_qty")).isEqualByComparingTo("10");
        Map<String, BigDecimal> second = facts(2);
        assertThat(second.get("exact_qty")).isEqualByComparingTo("0");
        assertThat(second.get("kit_qty")).as("申请 2 只能用公共剩下的 10").isEqualByComparingTo("10");
    }

    /** 已批准的订货单只占还要领的量: 需领 − 已发净量 − 已提交未发(草稿已占住库存)。 */
    @Test void anApprovedOrderClaimsOnlyWhatItStillHasToDraw() throws Exception {
        application(1, "100");
        publicStock("50");
        order(1, (short) 1);
        orderItem(1, 1, "40");
        source(1, 1, "40");
        update("INSERT INTO subcontract_material_plans(id) VALUES (?)", id(900));
        update("""
                INSERT INTO subcontract_material_plan_items(id, plan_id, order_item_id, line_no, goods_id, bom_unit_qty,
                                                            planned_qty, issued_qty)
                VALUES (?, ?, ?, 1, ?, 1, 40, 25)
                """, id(901), id(900), orderItemId(1), MATERIAL);
        update("INSERT INTO subcontract_material_issues(id, status) VALUES (?, 0)", id(902));
        update("INSERT INTO subcontract_material_issue_items(id, issue_id, plan_item_id, qty) VALUES (?, ?, ?, 5)",
                id(903), id(902), id(901));
        assertThat(scalar("SELECT fn_subcontract_order_item_component_need(?, ?, NULL)", orderItemId(1), MATERIAL))
                .isEqualByComparingTo("10");
        Map<String, BigDecimal> facts = facts(1);
        assertThat(facts.get("public_claimed_qty")).isEqualByComparingTo("10");
        assertThat(facts.get("kit_qty")).isEqualByComparingTo("40");
        update("UPDATE subcontract_orders SET is_closed = true WHERE id = ?", orderId(1));
        assertThat(facts(1).get("public_claimed_qty")).as("已结案的单不再占").isEqualByComparingTo("0");
    }

    /** 合并行按来源逐段累计取 4 位求差: 各来源份额之和恰好等于本行需要。 */
    @Test void aMergedLineSplitsItsNeedAcrossSourcesToExactlyTheLineNeed() throws Exception {
        update("UPDATE goods_bom_items SET qty = 0.333333");
        application(1, "1");
        application(2, "2");
        order(1, (short) 0);
        orderItem(1, 1, "3");
        source(1, 1, "1");
        source(1, 2, "2");
        Map<UUID, BigDecimal> demands = new LinkedHashMap<>();
        try (var query = connection.prepareStatement("""
                SELECT application_item_id, demand_qty FROM fn_subcontract_component_pool_demands(?, NULL, NULL)
                ORDER BY application_item_id NULLS LAST
                """)) {
            query.setObject(1, MATERIAL);
            try (var result = query.executeQuery()) {
                while (result.next()) demands.put(result.getObject(1, UUID.class), result.getBigDecimal(2));
            }
        }
        assertThat(demands).containsOnlyKeys(app(1), app(2));
        assertThat(demands.get(app(1))).isEqualByComparingTo("0.3333");
        assertThat(demands.get(app(2))).isEqualByComparingTo("0.6667");
    }

    /** 「可下单 N」= TRUNC4(可用 / 单耗); 按 N 下单恰好齐套, 多 0.0001 套就不够。 */
    @Test void orderingTheOrderableQuantityPassesAndOneTenThousandthMoreFails() throws Exception {
        update("UPDATE goods_bom_items SET qty = 0.333333");
        application(1, "10");
        publicStock("1");
        assertThat(scalar("SELECT fn_subcontract_application_kit_qty(?, NULL)", app(1))).isEqualByComparingTo("3");
        assertThat(scalar("SELECT fn_subcontract_application_orderable_qty(?)", app(1))).isEqualByComparingTo("3");
        order(1, (short) 0);
        orderItem(1, 1, "3");
        source(1, 1, "3");
        assertThat(shortages(1)).isEmpty();
        update("UPDATE subcontract_order_items SET qty = 3.0001 WHERE id = ?", orderItemId(1));
        update("UPDATE subcontract_order_item_sources SET alloc_qty = 3.0001 WHERE order_item_id = ?", orderItemId(1));
        assertThat(shortages(1)).hasSize(1);
    }

    /** 剩余未下单 = 申请 − 已下单 − 在审/退回待修订; 未审核或已结案的申请为 0(锁住)。 */
    @Test void openQuantityRetainsReturnedSharesAndUsesOnlyTheLatestAttempt() throws Exception {
        application(1, "100");
        publicStock("1000");
        update("UPDATE subcontract_application_items SET ordered_qty = 30 WHERE id = ?", app(1));
        order(1, (short) 0);
        orderItem(1, 1, "20");
        source(1, 1, "20");
        assertThat(scalar("SELECT fn_subcontract_application_open_qty(?)", app(1)))
                .as("未送审的草稿不扣剩余").isEqualByComparingTo("70");
        update("INSERT INTO procurement_order_approval_cases(order_type,order_id,status) VALUES ('SUBCONTRACT', ?, 'PENDING')", orderId(1));
        assertThat(scalar("SELECT fn_subcontract_application_open_qty(?)", app(1))).isEqualByComparingTo("50");
        assertThat(scalar("SELECT fn_subcontract_application_orderable_qty(?)", app(1))).isEqualByComparingTo("50");
        update("UPDATE procurement_order_approval_cases SET status='REJECTED' WHERE order_id=?",orderId(1));
        assertThat(scalar("SELECT fn_subcontract_application_open_qty(?)", app(1))).isEqualByComparingTo("50");
        update("INSERT INTO procurement_order_approval_cases VALUES ('SUBCONTRACT', ?, 'REJECTED', 2)",orderId(1));
        assertThat(scalar("SELECT fn_subcontract_application_open_qty(?)", app(1)))
                .as("重复驳回保留同一份额一次").isEqualByComparingTo("50");
        update("UPDATE subcontract_order_item_sources SET alloc_qty=10 WHERE order_item_id=?",orderItemId(1));
        assertThat(scalar("SELECT fn_subcontract_application_open_qty(?)", app(1))).isEqualByComparingTo("60");
        update("INSERT INTO procurement_order_approval_cases VALUES ('SUBCONTRACT', ?, 'CANCELED', 3)",orderId(1));
        assertThat(scalar("SELECT fn_subcontract_application_open_qty(?)", app(1)))
                .as("新轮已撤回时旧驳回不得复活").isEqualByComparingTo("70");
        update("INSERT INTO procurement_order_approval_cases VALUES ('SUBCONTRACT', ?, 'PENDING', 4)",orderId(1));
        assertThat(scalar("SELECT fn_subcontract_application_open_qty(?)", app(1))).isEqualByComparingTo("60");
        update("UPDATE subcontract_orders SET is_deleted=true WHERE id=?",orderId(1));
        assertThat(scalar("SELECT fn_subcontract_application_open_qty(?)", app(1))).isEqualByComparingTo("70");
        update("UPDATE subcontract_applications SET is_closed = true WHERE id = ?", applicationHeader(1));
        assertThat(scalar("SELECT fn_subcontract_application_orderable_qty(?)", app(1))).isEqualByComparingTo("0");
    }

    // =====================================================================================

    private void application(int number, String qty) throws Exception {
        update("INSERT INTO subcontract_applications(id) VALUES (?)", applicationHeader(number));
        update("INSERT INTO subcontract_application_items(id, application_id, goods_id, qty) VALUES (?, ?, ?, ?)",
                app(number), applicationHeader(number), PARENT_GOODS, new BigDecimal(qty));
        update("""
                INSERT INTO production_material_analysis_materials(id, analysis_id, analysis_item_id, node_key, depth, goods_id)
                VALUES (?, ?, ?, 'P', 1, ?)
                """, parentNode(number), ANALYSIS, id(3000 + number), PARENT_GOODS);
        update("""
                INSERT INTO production_material_analysis_materials(id, analysis_id, analysis_item_id, node_key,
                                                                   parent_node_key, depth, goods_id)
                VALUES (?, ?, ?, 'M', 'P', 2, ?)
                """, childNode(number), ANALYSIS, id(3000 + number), MATERIAL);
        update("""
                INSERT INTO preplan_supply_actions(id, analysis_id, route, operation_type, status,
                                                   external_document_type, external_document_id)
                VALUES (?, ?, 'SUBCONTRACT', 'SUPPLY', 'CREATED', 'SUBCONTRACT_APPLICATION', ?)
                """, id(400 + number), ANALYSIS, applicationHeader(number));
        update("""
                INSERT INTO preplan_supply_action_allocations(id, action_id, analysis_id, analysis_material_id,
                                                              external_item_id, allocated_qty)
                VALUES (?, ?, ?, ?, ?, ?)
                """, id(500 + number), id(400 + number), ANALYSIS, parentNode(number), app(number), new BigDecimal(qty));
    }

    private void lot(int number, int application, String qty) throws Exception {
        update("INSERT INTO stock_reservations(id, warehouse_id, goods_id, owner_type, qty) VALUES (?, ?, ?, 'PREPLAN_ANALYSIS', ?)",
                id(8000 + number), WAREHOUSE, MATERIAL, new BigDecimal(qty));
        update("""
                INSERT INTO fixture_entitlement_lots(entitlement_event_id, stock_reservation_id, beneficiary_analysis_id,
                                                     beneficiary_analysis_material_id, remaining_qty)
                VALUES (?, ?, ?, ?, ?)
                """, id(7000 + number), id(8000 + number), ANALYSIS, childNode(application), new BigDecimal(qty));
    }

    private void publicStock(String qty) throws Exception {
        update("INSERT INTO fixture_public_stock VALUES (?, ?, NULL, ?)", WAREHOUSE, MATERIAL, new BigDecimal(qty));
    }

    private void order(int number, short status) throws Exception {
        update("INSERT INTO subcontract_orders(id, status) VALUES (?, ?)", orderId(number), status);
    }

    private void orderItem(int order, int number, String qty) throws Exception {
        update("INSERT INTO subcontract_order_items(id, order_id, goods_id, qty) VALUES (?, ?, ?, ?)",
                orderItemId(number), orderId(order), PARENT_GOODS, new BigDecimal(qty));
    }

    private void source(int item, int application, String qty) throws Exception {
        update("""
                INSERT INTO subcontract_order_item_sources(order_item_id, application_item_id, alloc_qty, line_no)
                VALUES (?, ?, ?, (SELECT COUNT(*) + 1 FROM subcontract_order_item_sources WHERE order_item_id = ?))
                """, orderItemId(item), app(application), new BigDecimal(qty), orderItemId(item));
    }

    private Map<String, BigDecimal> facts(int application) throws Exception {
        Map<String, BigDecimal> facts = new LinkedHashMap<>();
        try (var query = connection.prepareStatement("""
                SELECT exact_qty, exact_claimed_qty, exact_free_qty, public_qty, public_claimed_qty, public_free_qty,
                       free_qty, kit_qty
                FROM fn_subcontract_application_kit_facts(?, NULL)
                """)) {
            query.setObject(1, app(application));
            try (var result = query.executeQuery()) {
                assertThat(result.next()).as("申请 %s 有一条直属物料事实", application).isTrue();
                var meta = result.getMetaData();
                for (int i = 1; i <= meta.getColumnCount(); i++) facts.put(meta.getColumnName(i), result.getBigDecimal(i));
                assertThat(result.next()).isFalse();
            }
        }

        var oracle = rows("SELECT * FROM oracle_fn_subcontract_application_kit_facts(?,NULL)", app(application));
        var actual = rows("SELECT * FROM fn_subcontract_application_kit_facts(?,NULL)", app(application));
        assertThat(actual).as("all edge/fact fields equal old authority").isEqualTo(oracle);
        return facts;
    }

    private List<BigDecimal> shortages(int order) throws Exception {
        List<BigDecimal> rows = new ArrayList<>();
        try (var query = connection.prepareStatement("SELECT need_qty FROM fn_subcontract_order_kit_shortages(?)")) {
            query.setObject(1, orderId(order));
            try (var result = query.executeQuery()) {
                while (result.next()) rows.add(result.getBigDecimal(1));
            }
        }

        assertThat(rows("SELECT * FROM fn_subcontract_order_kit_shortages(?) ORDER BY goods_id,color_id NULLS FIRST",orderId(order)))
            .isEqualTo(rows("SELECT * FROM oracle_fn_subcontract_order_kit_shortages(?) ORDER BY goods_id,color_id NULLS FIRST",orderId(order)));
        return rows;
    }

    private BigDecimal scalar(String sql, Object... parameters) throws Exception {
        try (var query = connection.prepareStatement(sql)) {
            for (int i = 0; i < parameters.length; i++) query.setObject(i + 1, parameters[i]);
            try (var result = query.executeQuery()) {
                assertThat(result.next()).isTrue();
                return result.getBigDecimal(1);
            }
        }
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

    private String migration(String file) throws Exception {
        try (var input = Objects.requireNonNull(getClass().getResourceAsStream("/db/migration/" + file))) {
            return new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    private static String function(String migration, String name, String terminator) {
        int start = migration.indexOf("CREATE FUNCTION " + name + "(");
        if (start<0) start=migration.indexOf("CREATE OR REPLACE FUNCTION " + name + "(");
        assertThat(start).as("production migration function %s", name).isGreaterThanOrEqualTo(0);
        int end = migration.indexOf(terminator, start);
        assertThat(end).isGreaterThan(start);
        return migration.substring(start, end + terminator.length());
    }

    private static UUID id(int number) { return UUID.fromString("00000000-0000-0000-0000-%012d".formatted(number)); }
    private static UUID app(int n) { return id(200 + n); }
    private static UUID applicationHeader(int n) { return id(300 + n); }
    private static UUID parentNode(int n) { return id(1000 + n); }
    private static UUID childNode(int n) { return id(2000 + n); }
    private static UUID orderId(int n) { return id(600 + n); }
    private static UUID orderItemId(int n) { return id(700 + n); }
    @Test void batchKeepsLatestAttemptsClosedDeletedMissingAndDuplicateIdSemantics() throws Exception {
        for(int n=1;n<=7;n++) application(n,"100");
        publicStock("999");order(1,(short)0);orderItem(1,1,"10");source(1,1,"10");
        update("INSERT INTO procurement_order_approval_cases VALUES ('SUBCONTRACT',?,'PENDING',1)",orderId(1));
        update("INSERT INTO procurement_order_approval_cases VALUES ('SUBCONTRACT',?,'REJECTED',2)",orderId(1));
        update("UPDATE subcontract_applications SET is_closed=true WHERE id=?",applicationHeader(2));
        update("UPDATE subcontract_application_items SET is_deleted=true WHERE id=?",app(3));
        update("UPDATE subcontract_applications SET is_deleted=true WHERE id=?",applicationHeader(4));
        update("UPDATE subcontract_applications SET status=0 WHERE id=?",applicationHeader(5));
        update("UPDATE subcontract_application_items SET ordered_qty=100 WHERE id=?",app(6));
        update("UPDATE subcontract_application_items SET goods_id=? WHERE id=?",MATERIAL,app(7));
        assertBatchEqualsOracle(new UUID[]{app(1),app(2),app(3),app(4),app(5),app(6),app(7),app(1),id(999999)});
        assertThat(rows("SELECT * FROM fn_subcontract_application_orderable_batch(ARRAY[]::uuid[])")).isEmpty();
        assertThat(scalar("SELECT fn_subcontract_application_orderable_qty(?)",id(999999))).isZero();
        assertThat(rows("SELECT * FROM fn_subcontract_component_public_free(NULL,NULL,NULL)"))
            .isEqualTo(rows("SELECT * FROM oracle_fn_subcontract_component_public_free(NULL,NULL,NULL)"));
        update("INSERT INTO procurement_order_approval_cases VALUES ('SUBCONTRACT',?,'CANCELED',3)",orderId(1));
        assertBatchEqualsOracle(new UUID[]{app(1),app(2),app(3)});
    }

    @Test void sharedPoolBatchEvaluatesEachOrderDimensionOnceRatherThanPerApplication() throws Exception {
        int applications=202, orders=401;
        // Many independent ordinary order headers share one component; fan-in is
        // not dependent on a single unusual 401-line document.
        for(int n=1;n<=applications;n++)
            update("INSERT INTO subcontract_applications(id) VALUES (?);",id(10000+n));
        for(int n=1;n<=applications;n++)
            update("INSERT INTO subcontract_application_items(id,application_id,goods_id,qty) VALUES (?,?,?,1000)",
                   id(20000+n),id(10000+n),PARENT_GOODS);
        publicStock("1000");
        for(int n=1;n<=orders;n++) {
            update("INSERT INTO subcontract_orders(id) VALUES (?)",id(30000+n));
            update("INSERT INTO subcontract_order_items(id,order_id,goods_id,qty) VALUES (?,?,?,1)",id(40000+n),id(30000+n),PARENT_GOODS);
            update("INSERT INTO subcontract_order_item_sources(order_item_id,application_item_id,alloc_qty,line_no) VALUES (?,?,1,1)",
                   id(40000+n),id(20001+(n%applications)));
        }
        UUID[] ids=java.util.stream.IntStream.rangeClosed(1,applications).mapToObj(n->id(20000+n)).toArray(UUID[]::new);
        execute("SET LOCAL track_functions TO 'all'");
        long before=needCalls();
        var actual=rows("SELECT * FROM fn_subcontract_application_orderable_batch(?) ORDER BY application_item_id",(Object)connection.createArrayOf("uuid",ids));
        long delta=needCalls()-before;
        assertThat(delta).as("one authoritative leaf call per relevant order/dimension, independent of A=202").isEqualTo(orders);
        assertThat(actual).hasSize(applications);
        assertThat(actual).allSatisfy(row->assertThat((BigDecimal)row.get("orderable_qty")).isEqualByComparingTo("599"));
        // The same 202-ID oracle comparison is retained in the dense diagnostic
        // evidence. This routine regression checks every result above and three
        // independently executed old-authority samples, avoiding 202 known slow
        // scalar scans on every CI run. Varied facts/precision are compared below.
        assertBatchEqualsOracle(new UUID[]{ids[0],ids[100],ids[201]});
    }

    @Test void multiColorEdgesUnitRatesExclusionsAndClosedPlansMatchOracle() throws Exception {
        application(1,"100");application(2,"100");application(3,"100");
        UUID color=id(9200), second=id(9201);
        update("INSERT INTO goods(id) VALUES (?)",second);
        update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,color_id,qty,sort_order) VALUES (?,?,?,?,0.777777,2)",
            id(9202),PARENT_GOODS,MATERIAL,color);
        update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,sort_order) VALUES (?,?,?,1.234567,3)",
            id(9203),PARENT_GOODS,second);
        update("UPDATE subcontract_application_items SET unit_rate=1.333333 WHERE id=?",app(2));
        publicStock("45.6789");
        update("INSERT INTO fixture_public_stock VALUES (?,?,?,88.7654)",WAREHOUSE,MATERIAL,color);
        update("INSERT INTO fixture_public_stock VALUES (?,?,NULL,100)",WAREHOUSE,second);
        lot(1,1,"15.4321");
        order(1,(short)0);orderItem(1,1,"10.3333");source(1,1,"3.1111");source(1,2,"6.7777");
        order(2,(short)1);orderItem(2,2,"30");source(2,3,"30");
        update("INSERT INTO subcontract_material_plans(id) VALUES (?)",id(9300));
        update("INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,line_no,goods_id,color_id,bom_unit_qty,planned_qty,issued_qty) VALUES (?,?,?,1,?,?,1,30,7.7777)",
            id(9301),id(9300),orderItemId(2),MATERIAL,color);
        for(int n=1;n<=3;n++) for(UUID exclude:new UUID[]{null,orderId(1),orderId(2)})
            assertThat(rows("SELECT * FROM fn_subcontract_application_kit_facts(?,?) ORDER BY edge_id",app(n),exclude))
                .isEqualTo(rows("SELECT * FROM oracle_fn_subcontract_application_kit_facts(?,?) ORDER BY edge_id",app(n),exclude));
        for(int n=1;n<=2;n++) shortages(n);
        assertBatchEqualsOracle(new UUID[]{app(1),app(2),app(3)});
        update("UPDATE subcontract_material_plan_items SET draw_closed_at=now() WHERE id=?",id(9301));
        assertBatchEqualsOracle(new UUID[]{app(1),app(2),app(3)});
        update("UPDATE subcontract_orders SET status=2 WHERE id=?",orderId(1));
        assertBatchEqualsOracle(new UUID[]{app(1),app(2),app(3)});
    }

    private long needCalls() throws Exception {
        return scalar("SELECT COALESCE(SUM(calls),0) FROM pg_stat_xact_user_functions WHERE schemaname='kit_test' AND funcname='fn_subcontract_order_item_component_need'").longValueExact();
    }
    private void assertBatchEqualsOracle(UUID[] ids) throws Exception {
        var array=connection.createArrayOf("uuid",ids);
        assertThat(rows("SELECT * FROM fn_subcontract_application_orderable_batch(?) ORDER BY application_item_id",array))
            .isEqualTo(rows("SELECT id AS application_item_id,oracle_fn_subcontract_application_open_qty(id) AS open_qty,oracle_fn_subcontract_application_orderable_qty(id) AS orderable_qty FROM subcontract_application_items WHERE id=ANY(?) ORDER BY id",array));
    }
    private List<Map<String,Object>> rows(String sql,Object... values) throws Exception {
        var result=new ArrayList<Map<String,Object>>();
        try(var statement=connection.prepareStatement(sql)) {
            for(int i=0;i<values.length;i++) statement.setObject(i+1,values[i]);
            try(var rows=statement.executeQuery()) {
                var columns=rows.getMetaData();
                while(rows.next()) {
                    var row=new LinkedHashMap<String,Object>();
                    for(int i=1;i<=columns.getColumnCount();i++) {
                        Object value=rows.getObject(i);
                        if(value instanceof BigDecimal decimal) value=decimal.stripTrailingZeros();
                        row.put(columns.getColumnLabel(i),value);
                    }
                    result.add(row);
                }
            }
        }
        return result;
    }

    @Test void noticeMarksFollowFreshShownQuantitiesThroughDropsDuplicatesAndRearrival() throws Exception {
        application(1,"100");application(2,"100");publicStock("10");
        var runtime=noticeRuntime();
        runtime.jdbc.update("INSERT INTO subcontract_application_kit_notice_marks(application_item_id,notified_orderable) VALUES (?,4),(?,0)",app(1),app(2));
        var stockAtPublication=new java.util.concurrent.atomic.AtomicReference<BigDecimal>(BigDecimal.ZERO);
        var publications=new java.util.concurrent.atomic.AtomicInteger();
        bindPublication(runtime,stockAtPublication,publications,null,null);
        var service=new SubcontractApplicationKitRecheckService(runtime.jdbc,runtime.kit,runtime.notices);
        runtime.tx.executeWithoutResult(s->service.recheck(List.of(app(2),app(1),app(1))));
        assertMark(runtime,1,"0",1);assertMark(runtime,2,"0",0);
        assertThat(runtime.jdbc.queryForObject("SELECT count(*) FROM fixture_cards",Integer.class)).isZero();
        runtime.jdbc.update("UPDATE fixture_public_stock SET available_qty=12");
        runtime.tx.executeWithoutResult(s->service.recheck(List.of(app(1),app(2))));
        assertMark(runtime,1,"12",1);assertMark(runtime,2,"12",0);
        runtime.tx.executeWithoutResult(s->service.recheck(List.of(app(2),app(1))));
        assertThat(publications.get()).as("same event has no repeated publication").isEqualTo(2);
        runtime.jdbc.update("UPDATE fixture_public_stock SET available_qty=3");
        runtime.tx.executeWithoutResult(s->service.recheck(List.of(app(1),app(2))));
        assertMark(runtime,1,"3",2);assertMark(runtime,2,"3",1);
        runtime.jdbc.update("UPDATE fixture_public_stock SET available_qty=0");
        runtime.tx.executeWithoutResult(s->service.recheck(List.of(app(1),app(2))));
        assertMark(runtime,1,"0",3);assertMark(runtime,2,"0",2);
        assertThat(runtime.jdbc.queryForObject("SELECT count(*) FROM fixture_cards",Integer.class)).isZero();
        runtime.jdbc.update("UPDATE fixture_public_stock SET available_qty=9");
        runtime.tx.executeWithoutResult(s->service.recheck(List.of(app(1),app(2))));
        assertMark(runtime,1,"9",3);assertMark(runtime,2,"9",2);
        assertThat(runtime.jdbc.queryForObject("SELECT count(*) FROM fixture_cards WHERE shown_qty=9",Integer.class)).isEqualTo(2);
        assertThat(publications.get()).isEqualTo(3);
        org.mockito.Mockito.verify(runtime.notices,org.mockito.Mockito.never()).refreshSubcontractOrderKitReady(org.mockito.ArgumentMatchers.any());
    }

    @Test void overlappingRechecksLockInOneOrderAndRereadAfterWaitingWithoutDuplicateCards() throws Exception {
        application(1,"100");application(2,"100");publicStock("20");
        var runtime=noticeRuntime();
        runtime.jdbc.update("INSERT INTO subcontract_application_kit_notice_marks(application_item_id) VALUES (?),(?)",app(1),app(2));
        var stockAtPublication=new java.util.concurrent.atomic.AtomicReference<BigDecimal>(new BigDecimal("12"));
        var publications=new java.util.concurrent.atomic.AtomicInteger();
        var entered=new java.util.concurrent.CountDownLatch(1);var release=new java.util.concurrent.CountDownLatch(1);
        bindPublication(runtime,stockAtPublication,publications,entered,release);
        var service=new SubcontractApplicationKitRecheckService(runtime.jdbc,runtime.kit,runtime.notices);
        var pool=java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            var first=pool.submit(()->runtime.tx.executeWithoutResult(s->service.recheck(List.of(app(2),app(1)))));
            assertThat(entered.await(10,java.util.concurrent.TimeUnit.SECONDS)).isTrue();
            var started=new java.util.concurrent.CountDownLatch(1);
            var second=pool.submit(()->{started.countDown();runtime.tx.executeWithoutResult(s->service.recheck(List.of(app(1),app(2))));});
            assertThat(started.await(10,java.util.concurrent.TimeUnit.SECONDS)).isTrue();
            assertThat(second.isDone()).as("the other event cannot pass held watermark locks").isFalse();
            release.countDown();first.get(20,java.util.concurrent.TimeUnit.SECONDS);second.get(20,java.util.concurrent.TimeUnit.SECONDS);
        } finally {release.countDown();pool.shutdownNow();assertThat(pool.awaitTermination(10,java.util.concurrent.TimeUnit.SECONDS)).isTrue();}
        assertMark(runtime,1,"12",0);assertMark(runtime,2,"12",0);
        assertThat(publications.get()).as("queued event sees committed fresh quantity, not the pre-lock 20").isEqualTo(1);
        assertThat(runtime.jdbc.queryForObject("SELECT count(*) FROM fixture_cards WHERE shown_qty=12",Integer.class)).isEqualTo(2);
    }

    private record NoticeRuntime(org.springframework.jdbc.core.JdbcTemplate jdbc,
        SubcontractKitService kit,com.uten.imp.application.port.SubcontractChainNoticePort notices,
        org.springframework.transaction.support.TransactionTemplate tx) {}
    private NoticeRuntime noticeRuntime() throws Exception {
        execute("CREATE TABLE subcontract_application_kit_notice_marks(application_item_id uuid PRIMARY KEY REFERENCES subcontract_application_items(id),notified_orderable numeric(18,4) NOT NULL DEFAULT 0,epoch integer NOT NULL DEFAULT 0,updated_at timestamptz DEFAULT now())");
        execute("CREATE TABLE fixture_cards(application_item_id uuid PRIMARY KEY,shown_qty numeric(18,4))");
        connection.commit();
        var dataSource=new org.postgresql.ds.PGSimpleDataSource();dataSource.setURL(DB.getJdbcUrl());
        dataSource.setUser(DB.getUsername());dataSource.setPassword(DB.getPassword());dataSource.setCurrentSchema("kit_test");
        var jdbc=new org.springframework.jdbc.core.JdbcTemplate(dataSource);
        var kit=new SubcontractKitService(jdbc,org.mockito.Mockito.mock(com.uten.imp.application.port.SubcontractOutboundWakePort.class));
        var notices=org.mockito.Mockito.mock(com.uten.imp.application.port.SubcontractChainNoticePort.class);
        var tx=new org.springframework.transaction.support.TransactionTemplate(new org.springframework.jdbc.datasource.DataSourceTransactionManager(dataSource));tx.setTimeout(20);
        return new NoticeRuntime(jdbc,kit,notices,tx);
    }
    private void bindPublication(NoticeRuntime runtime,java.util.concurrent.atomic.AtomicReference<BigDecimal> stock,
        java.util.concurrent.atomic.AtomicInteger calls,java.util.concurrent.CountDownLatch entered,java.util.concurrent.CountDownLatch release) {
        org.mockito.Mockito.when(runtime.notices.refreshSubcontractOrderKitReadyBatch(org.mockito.ArgumentMatchers.anyCollection())).thenAnswer(invocation->{
            int call=calls.incrementAndGet();
            if(call==1&&entered!=null){entered.countDown();assertThat(release.await(10,java.util.concurrent.TimeUnit.SECONDS)).isTrue();}
            BigDecimal next=stock.getAndSet(null);if(next!=null) runtime.jdbc.update("UPDATE fixture_public_stock SET available_qty=?",next);
            // A real second authority read after the original recheck snapshot,
            // matching the port's shown-card contract rather than echoing input.
            var fresh=runtime.kit.orderableNow(invocation.getArgument(0));
            fresh.forEach((id,quantity)->{
                if(quantity.signum()>0) runtime.jdbc.update("INSERT INTO fixture_cards VALUES (?,?) ON CONFLICT(application_item_id) DO UPDATE SET shown_qty=excluded.shown_qty",id,quantity);
                else runtime.jdbc.update("DELETE FROM fixture_cards WHERE application_item_id=?",id);
            });return fresh;
        });
        org.mockito.Mockito.doAnswer(invocation->{runtime.jdbc.update("DELETE FROM fixture_cards WHERE application_item_id=?",invocation.<UUID>getArgument(0));return null;})
            .when(runtime.notices).resolveSubcontractOrderKitReady(org.mockito.ArgumentMatchers.any());
    }
    private void assertMark(NoticeRuntime runtime,int application,String expected,int epoch) {
        var mark=runtime.jdbc.queryForMap("SELECT notified_orderable,epoch FROM subcontract_application_kit_notice_marks WHERE application_item_id=?",app(application));
        assertThat((BigDecimal)mark.get("notified_orderable")).isEqualByComparingTo(expected);assertThat(mark.get("epoch")).isEqualTo(epoch);
    }

}
