package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-143 §4.5 per-material subcontract draw coverage. Runs the real projection SQL against
 * minimal relations holding only the columns it reads; the two SQL helpers are the migrated
 * definitions (fn_subcontract_order_source_share from V503, fn_subcontract_draw_f per V798).
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractComponentCustodyProjectionPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final BigDecimal EPSILON = new BigDecimal("0.00001");

    private Connection connection;

    @BeforeAll static void start() { DB.start(); }
    @AfterAll static void stop() { DB.stop(); }

    @AfterEach
    void close() throws SQLException {
        if (connection != null) connection.close();
    }

    @BeforeEach
    void schema() throws SQLException {
        connection = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        execute("DROP SCHEMA IF EXISTS coverage CASCADE");
        execute("CREATE SCHEMA coverage");
        execute("SET search_path TO coverage");
        execute("""
                CREATE TABLE preplan_supply_actions(id uuid PRIMARY KEY, analysis_id uuid, route text,
                    operation_type text, status text, external_document_type text, requested_qty numeric,
                    public_surplus_qty numeric NOT NULL DEFAULT 0, public_surplus_external_item_id uuid);
                CREATE TABLE preplan_supply_action_allocations(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    action_id uuid, analysis_id uuid, analysis_material_id uuid, allocated_qty numeric,
                    external_item_id uuid);
                CREATE TABLE subcontract_orders(id uuid PRIMARY KEY, status int, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_order_items(id uuid PRIMARY KEY, order_id uuid, unit_rate numeric,
                    returned_qty numeric DEFAULT 0, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_order_item_sources(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    order_item_id uuid, application_item_id uuid, alloc_qty numeric, line_no int);
                CREATE TABLE subcontract_receipts(id uuid PRIMARY KEY, status int, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_receipt_items(id uuid PRIMARY KEY, receipt_id uuid, order_item_id uuid,
                    qty numeric, unit_rate numeric, is_deleted boolean DEFAULT false);
                CREATE TABLE procurement_inspection_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    receipt_type text, receipt_item_id uuid, status text, warehouse_stocked_base_qty numeric);
                CREATE TABLE subcontract_material_plans(id uuid PRIMARY KEY, status text, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_plan_items(id uuid PRIMARY KEY, plan_id uuid, order_item_id uuid,
                    goods_id uuid, color_id uuid, bom_unit_qty numeric, issued_qty numeric,
                    is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_issues(id uuid PRIMARY KEY, status int, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_issue_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    issue_id uuid, plan_item_id uuid, qty numeric, is_deleted boolean DEFAULT false);
                CREATE TABLE stock_reservations(id uuid PRIMARY KEY, qty numeric, released_qty numeric DEFAULT 0,
                    consumed_qty numeric DEFAULT 0, status int DEFAULT 0, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_component_stock_handoffs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    plan_item_id uuid, parent_material_id uuid, child_material_id uuid,
                    source_reservation_id uuid, target_reservation_id uuid, qty numeric,
                    created_at timestamptz DEFAULT now());
                CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY, analysis_id uuid,
                    analysis_item_id uuid, node_key text, parent_node_key text, node_role text, depth int,
                    path text, goods_id uuid, color_id uuid, active boolean DEFAULT true);
                CREATE FUNCTION fn_subcontract_draw_f(p_sets numeric, p_bom_unit_qty numeric)
                RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT CEIL(p_sets * p_bom_unit_qty * 10000) / 10000 $$;
                CREATE FUNCTION fn_subcontract_order_source_share(p_order_item_id uuid, p_application_item_id uuid,
                    p_total_base numeric) RETURNS numeric LANGUAGE sql STABLE AS $$
                    WITH bounds AS (
                        SELECT src.application_item_id,
                               src.alloc_qty * COALESCE(item.unit_rate, 1) AS alloc_base,
                               COALESCE(SUM(src.alloc_qty) OVER w, 0) * COALESCE(item.unit_rate, 1)
                                   - src.alloc_qty * COALESCE(item.unit_rate, 1) AS prefix_base,
                               ROW_NUMBER() OVER w AS rn,
                               COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
                        FROM subcontract_order_item_sources src
                        JOIN subcontract_order_items item ON item.id = src.order_item_id
                        WHERE src.order_item_id = p_order_item_id AND src.alloc_qty > 0
                        WINDOW w AS (PARTITION BY src.order_item_id ORDER BY src.line_no, src.id))
                    SELECT COALESCE((SELECT CASE WHEN b.rn = b.source_count
                            THEN GREATEST(COALESCE(p_total_base, 0) - b.prefix_base, 0)
                            ELSE GREATEST(LEAST(b.alloc_base, COALESCE(p_total_base, 0) - b.prefix_base), 0) END
                        FROM bounds b WHERE b.application_item_id = p_application_item_id), 0);
                $$;
                """);
    }

    @Test
    void stockedReturnsConsumeTheirMaterialAndCapTheRemainingParentOutput() throws Exception {
        // Q=100, b=1：领了 70 套，40 套已回厂合格入库。委外商处 30 套料仍覆盖剩余 60 套的需求。
        World w = new World(UUID.randomUUID());
        Parent p = w.parent("P", false);
        UUID childA = w.child(p, "A", w.goodsA);
        UUID action = w.action(p, "100", "0");
        UUID application = w.allocation(action, p, "100");
        UUID orderItem = w.orderItem("1", application, "100");
        w.planLine(orderItem, w.goodsA, "1", "70");
        w.stockedReceipt(orderItem, "40");

        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);

        assertThat(rows).containsOnlyKeys(childA);
        assertThat(rows.get(childA)[0]).isCloseTo(new BigDecimal("30"), within(EPSILON));
        assertThat(rows.get(childA)[1]).isCloseTo(new BigDecimal("60"), within(EPSILON));
    }

    @Test
    void everyMaterialIsCoveredOnItsOwnAndDraftsCountWithNetSent() throws Exception {
        // 两种直属物料：A 单耗 1 已发 40；B 单耗 2 已发 60 + 待仓库发 20。不同物料从不相加。
        World w = new World(UUID.randomUUID());
        Parent p = w.parent("P", false);
        UUID childA = w.child(p, "A", w.goodsA);
        UUID childB = w.child(p, "B", w.goodsB);
        UUID action = w.action(p, "100", "0");
        UUID application = w.allocation(action, p, "100");
        UUID orderItem = w.orderItem("1", application, "100");
        w.planLine(orderItem, w.goodsA, "1", "40");
        UUID lineB = w.planLine(orderItem, w.goodsB, "2", "60");
        w.draft(lineB, "20");

        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);

        assertThat(rows.get(childA)[0]).isCloseTo(new BigDecimal("40"), within(EPSILON));
        assertThat(rows.get(childB)[0]).isCloseTo(new BigDecimal("80"), within(EPSILON));
        assertThat(rows.get(childA)[1]).isCloseTo(new BigDecimal("100"), within(EPSILON));
    }

    @Test
    void mergedOrderItemSplitsPublicDrawsByApplicationWeightAndKeepsExactHandoffs() throws Exception {
        // 两张分析合并成一条订货明细(60 + 40)：公共领出的 50 按空额 60:40 分；Y 另有 10 专属交接。
        World x = new World(UUID.randomUUID());
        Parent px = x.parent("PX", false);
        UUID cx = x.child(px, "A", x.goodsA);
        UUID actionX = x.action(px, "60", "0");
        UUID applicationX = x.allocation(actionX, px, "60");
        World y = x.sibling(UUID.randomUUID());
        Parent py = y.parent("PY", false);
        UUID cy = y.child(py, "A", x.goodsA);
        UUID actionY = y.action(py, "40", "0");
        UUID applicationY = y.allocation(actionY, py, "40");
        UUID orderItem = x.orderItem("1", applicationX, "60");
        x.source(orderItem, applicationY, "40", 2);
        UUID line = x.planLine(orderItem, x.goodsA, "1", "50");
        x.handoff(line, py, cy, "10");

        Map<UUID, BigDecimal[]> forX = coverage(x.analysis);
        Map<UUID, BigDecimal[]> forY = coverage(y.analysis);

        BigDecimal netX = forX.get(cx)[0];
        BigDecimal netY = forY.get(cy)[0];
        assertThat(netX.add(netY)).isCloseTo(new BigDecimal("50"), within(EPSILON));
        // Y 的专属 10 归它本身；其余公共 40 按空额(X 60、Y 30)分摊。
        assertThat(netY).isCloseTo(new BigDecimal("23.3333"), within(new BigDecimal("0.0002")));
        assertThat(forX.get(cx)[1]).isCloseTo(new BigDecimal("60"), within(EPSILON));
        assertThat(forY.get(cy)[1]).isCloseTo(new BigDecimal("40"), within(EPSILON));
    }

    @Test
    void mergedOrderItemConsumesStockedReturnsBeforeSplittingPublicDraws() throws Exception {
        // 两张分析各 100 合并成一条订货明细：公共库存领出 100 套，回厂 100 合格入库，按来源先后算 X 的。
        // 领出的料已全部做进 X 的 P：X 什么都不缺，Y 一套料都没有，仍缺 100。
        World x = new World(UUID.randomUUID());
        Parent px = x.parent("PX", false);
        UUID cx = x.child(px, "A", x.goodsA);
        UUID applicationX = x.allocation(x.action(px, "100", "0"), px, "100");
        World y = x.sibling(UUID.randomUUID());
        Parent py = y.parent("PY", false);
        UUID cy = y.child(py, "A", x.goodsA);
        UUID applicationY = y.allocation(y.action(py, "100", "0"), py, "100");
        UUID orderItem = x.orderItem("1", applicationX, "100");
        x.source(orderItem, applicationY, "100", 2);
        UUID line = x.planLine(orderItem, x.goodsA, "1", "100");
        x.stockedReceipt(orderItem, "100");

        assertThat(coverage(x.analysis)).doesNotContainKey(cx);
        assertThat(coverage(y.analysis)).doesNotContainKey(cy);

        // 再领 40 套：只有 Y 还缺料，全部归 Y；Y 的 P 剩余计划产出仍是 100，缺口 60。
        x.draft(line, "40");
        Map<UUID, BigDecimal[]> forY = coverage(y.analysis);
        assertThat(coverage(x.analysis)).doesNotContainKey(cx);
        assertThat(forY.get(cy)[0]).isCloseTo(new BigDecimal("40"), within(EPSILON));
        assertThat(forY.get(cy)[1]).isCloseTo(new BigDecimal("100"), within(EPSILON));
    }

    @Test
    void exactHandoffConsumedUnderAnEarlierSourcesReturnsNoLongerCoversItsOwner() throws Exception {
        // 同样 100 + 100 合并：领出的 100 套全是 Y 的专属交接；回厂 100 按来源先后算 X 的。
        // 料已做成 P 入库，剩余料为 0：Y 的专属量不再覆盖，Y 仍缺 100。
        World x = new World(UUID.randomUUID());
        Parent px = x.parent("PX", false);
        UUID cx = x.child(px, "A", x.goodsA);
        UUID applicationX = x.allocation(x.action(px, "100", "0"), px, "100");
        World y = x.sibling(UUID.randomUUID());
        Parent py = y.parent("PY", false);
        UUID cy = y.child(py, "A", x.goodsA);
        UUID applicationY = y.allocation(y.action(py, "100", "0"), py, "100");
        UUID orderItem = x.orderItem("1", applicationX, "100");
        x.source(orderItem, applicationY, "100", 2);
        UUID line = x.planLine(orderItem, x.goodsA, "1", "100");
        x.handoff(line, py, cy, "100");

        assertThat(coverage(y.analysis).get(cy)[0]).isCloseTo(new BigDecimal("100"), within(EPSILON));
        assertThat(coverage(x.analysis)).doesNotContainKey(cx);

        x.stockedReceipt(orderItem, "100");
        assertThat(coverage(x.analysis)).doesNotContainKey(cx);
        assertThat(coverage(y.analysis)).doesNotContainKey(cy);

        // 再从公共库存领 30 套：剩余料 30 只能是给仍缺料的 Y 做的。
        x.draft(line, "30");
        Map<UUID, BigDecimal[]> forY = coverage(y.analysis);
        assertThat(forY.get(cy)[0]).isCloseTo(new BigDecimal("30"), within(EPSILON));
        assertThat(forY.get(cy)[1]).isCloseTo(new BigDecimal("100"), within(EPSILON));
        assertThat(coverage(x.analysis)).doesNotContainKey(cx);
    }

    @Test
    void rootSupplyParentCoversItsDepthOneChildrenAndPublicSurplusRaisesTheCap() throws Exception {
        // 顶层委外件(ROOT_SUPPLY)：直属物料是同一来源行的第 1 层节点；需求 1000 + 公共 500。
        World w = new World(UUID.randomUUID());
        Parent root = w.parent("ROOT_SUPPLY", true);
        UUID childA = w.child(root, "A", w.goodsA);
        UUID action = w.action(root, "1000", "500");
        UUID application = w.allocation(action, root, "1000");
        w.publicSurplus(action, application);
        UUID orderItem = w.orderItem("1", application, "1500");
        w.planLine(orderItem, w.goodsA, "1", "1200");
        w.stockedReceipt(orderItem, "200");

        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);

        assertThat(rows.get(childA)[0]).isCloseTo(new BigDecimal("1000"), within(EPSILON));
        assertThat(rows.get(childA)[1]).isCloseTo(new BigDecimal("1300"), within(EPSILON));
    }

    @Test
    void manualExcessBeyondTheApplicationIsNotAttributed() throws Exception {
        // 订货 150 只来自 100 的申请：领出 150 套，只有申请那 100 套的料归本分析。
        World w = new World(UUID.randomUUID());
        Parent p = w.parent("P", false);
        UUID childA = w.child(p, "A", w.goodsA);
        UUID action = w.action(p, "100", "0");
        UUID application = w.allocation(action, p, "100");
        UUID orderItem = w.orderItem("1", application, "100");
        w.planLine(orderItem, w.goodsA, "1", "150");

        assertThat(coverage(w.analysis).get(childA)[0]).isCloseTo(new BigDecimal("100"), within(EPSILON));
    }

    private Map<UUID, BigDecimal[]> coverage(UUID analysisId) throws SQLException {
        String sql = productionSql().replace(":analysisId", "'" + analysisId + "'::uuid");
        Map<UUID, BigDecimal[]> rows = new LinkedHashMap<>();
        try (var statement = connection.createStatement()) {
            statement.setQueryTimeout(10);
            try (var result = statement.executeQuery(sql)) {
                while (result.next()) {
                    rows.put(UUID.fromString(result.getString(3)),
                            new BigDecimal[]{result.getBigDecimal(6), result.getBigDecimal(7)});
                }
            }
        }
        return rows;
    }

    private static String productionSql() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(java.util.List.of());
        SubcontractComponentCustodyProjection.coverageForAnalysis(em, UUID.randomUUID());
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        return sql.getValue();
    }

    private void execute(String sql) throws SQLException {
        try (var statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }

    private void update(String sql, Object... values) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int i = 0; i < values.length; i++) statement.setObject(i + 1, values[i]);
            statement.executeUpdate();
        }
    }

    private record Parent(UUID id, UUID analysisItemId, String nodeKey, boolean root) {}

    /** One analysis; goods identities are shared by siblings so merged orders reuse materials. */
    private final class World {
        final UUID analysis;
        final UUID goodsA;
        final UUID goodsB;
        final UUID order = UUID.randomUUID();
        final UUID plan = UUID.randomUUID();
        private boolean orderCreated;
        private boolean planCreated;

        World(UUID analysis) {
            this(analysis, UUID.randomUUID(), UUID.randomUUID());
        }

        private World(UUID analysis, UUID goodsA, UUID goodsB) {
            this.analysis = analysis;
            this.goodsA = goodsA;
            this.goodsB = goodsB;
        }

        World sibling(UUID otherAnalysis) {
            return new World(otherAnalysis, goodsA, goodsB);
        }

        Parent parent(String nodeKey, boolean root) throws SQLException {
            UUID id = UUID.randomUUID();
            UUID item = UUID.randomUUID();
            update("INSERT INTO production_material_analysis_materials VALUES (?,?,?,?,?,?,?,?,?,NULL,true)",
                    id, analysis, item, nodeKey, null, root ? "ROOT_SUPPLY" : "BOM_COMPONENT",
                    root ? 0 : 1, nodeKey, UUID.randomUUID());
            return new Parent(id, item, nodeKey, root);
        }

        UUID child(Parent parent, String nodeKey, UUID goods) throws SQLException {
            UUID id = UUID.randomUUID();
            String key = parent.nodeKey() + "/" + nodeKey;
            update("INSERT INTO production_material_analysis_materials VALUES (?,?,?,?,?,?,?,?,?,NULL,true)",
                    id, analysis, parent.analysisItemId(), key, parent.root() ? null : parent.nodeKey(),
                    "BOM_COMPONENT", parent.root() ? 1 : 2, key, goods);
            return id;
        }

        UUID action(Parent parent, String requested, String publicSurplus) throws SQLException {
            UUID id = UUID.randomUUID();
            update("INSERT INTO preplan_supply_actions VALUES (?,?,'SUBCONTRACT','SUPPLY','CREATED','SUBCONTRACT_APPLICATION',?,?,NULL)",
                    id, analysis, new BigDecimal(requested), new BigDecimal(publicSurplus));
            return id;
        }

        UUID allocation(UUID action, Parent parent, String qty) throws SQLException {
            UUID application = UUID.randomUUID();
            update("INSERT INTO preplan_supply_action_allocations(action_id,analysis_id,analysis_material_id,allocated_qty,external_item_id) VALUES (?,?,?,?,?)",
                    action, analysis, parent.id(), new BigDecimal(qty), application);
            return application;
        }

        void publicSurplus(UUID action, UUID application) throws SQLException {
            update("UPDATE preplan_supply_actions SET public_surplus_external_item_id=? WHERE id=?", application, action);
        }

        UUID orderItem(String rate, UUID application, String allocQty) throws SQLException {
            if (!orderCreated) {
                update("INSERT INTO subcontract_orders VALUES (?,1,false)", order);
                orderCreated = true;
            }
            UUID item = UUID.randomUUID();
            update("INSERT INTO subcontract_order_items VALUES (?,?,?,0,false)", item, order, new BigDecimal(rate));
            source(item, application, allocQty, 1);
            return item;
        }

        void source(UUID orderItem, UUID application, String allocQty, int lineNo) throws SQLException {
            update("INSERT INTO subcontract_order_item_sources(order_item_id,application_item_id,alloc_qty,line_no) VALUES (?,?,?,?)",
                    orderItem, application, new BigDecimal(allocQty), lineNo);
        }

        UUID planLine(UUID orderItem, UUID goods, String bomUnitQty, String issued) throws SQLException {
            if (!planCreated) {
                update("INSERT INTO subcontract_material_plans VALUES (?,'OPEN',false)", plan);
                planCreated = true;
            }
            UUID line = UUID.randomUUID();
            update("INSERT INTO subcontract_material_plan_items VALUES (?,?,?,?,NULL,?,?,false)",
                    line, plan, orderItem, goods, new BigDecimal(bomUnitQty), new BigDecimal(issued));
            return line;
        }

        void draft(UUID planLine, String qty) throws SQLException {
            UUID issue = UUID.randomUUID();
            update("INSERT INTO subcontract_material_issues VALUES (?,0,false)", issue);
            update("INSERT INTO subcontract_material_issue_items(issue_id,plan_item_id,qty) VALUES (?,?,?)",
                    issue, planLine, new BigDecimal(qty));
        }

        void handoff(UUID planLine, Parent parent, UUID child, String qty) throws SQLException {
            UUID target = UUID.randomUUID();
            update("INSERT INTO stock_reservations(id,qty) VALUES (?,?)", target, new BigDecimal(qty));
            update("INSERT INTO subcontract_component_stock_handoffs(plan_item_id,parent_material_id,child_material_id,source_reservation_id,target_reservation_id,qty) VALUES (?,?,?,?,?,?)",
                    planLine, parent.id(), child, UUID.randomUUID(), target, new BigDecimal(qty));
        }

        void stockedReceipt(UUID orderItem, String qty) throws SQLException {
            UUID receipt = UUID.randomUUID();
            UUID item = UUID.randomUUID();
            update("INSERT INTO subcontract_receipts VALUES (?,1,false)", receipt);
            update("INSERT INTO subcontract_receipt_items VALUES (?,?,?,?,1,false)", item, receipt, orderItem, new BigDecimal(qty));
            update("INSERT INTO procurement_inspection_items(receipt_type,receipt_item_id,status,warehouse_stocked_base_qty) VALUES ('SUBCONTRACT',?,'RESOLVED',?)",
                    item, new BigDecimal(qty));
        }
    }
}
