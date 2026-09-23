package com.uten.imp.features.subcontract.plan;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.SubcontractChainNoticePort;
import com.uten.imp.application.port.SubcontractOrderPreparationPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItemRepository;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Executes the real detail projection in an isolated, read-model-only schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractOutboundDetailPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static RecordingJdbcTemplate jdbc;
    private SecurityContextCurrentUser currentUser;
    private SubcontractMaterialPlanService service;

    @BeforeAll
    static void start() {
        DB.start();
        jdbc = new RecordingJdbcTemplate(new DriverManagerDataSource(
                DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        jdbc.execute("CREATE TABLE goods(id uuid PRIMARY KEY, code text, name text, stock_place text, default_purchase_price_color_id uuid, default_purchase_price_currency_id uuid, default_purchase_price_supplier_id uuid, default_purchase_price_tax_rate numeric(18,4), default_purchase_price_unit_id uuid, default_subcontract_price_color_id uuid, default_subcontract_price_currency_id uuid, default_subcontract_price_supplier_id uuid, default_subcontract_price_tax_rate numeric(18,4), default_subcontract_price_unit_id uuid)");
        jdbc.execute("CREATE TABLE colors(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE units(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE suppliers(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE warehouses(id uuid PRIMARY KEY, code text, name text, is_deleted boolean, is_defective boolean, is_line_side boolean)");
        // taskDetail 的 LATERAL 会按「作业叶仓 + 合格可动用量」替仓库选发料仓(ADR-101)：
        // 桩视图只喂一条「第一仓对目标件有充足可动用量」的行(9999 不会压住任何断言)，
        // 让发现货行的 issuable/stock 字段照生产口径算出来而不是整个 LATERAL 落空。
        jdbc.execute("""
                CREATE VIEW v_stock_available AS
                SELECT '00000000-0000-0000-0000-000000000007'::uuid AS warehouse_id,
                       '00000000-0000-0000-0000-000000000006'::uuid AS goods_id,
                       NULL::uuid AS color_id,
                       9999::numeric AS available_qty
                """);
        // 本测试不关心仓库层级语义，叶仓判定恒真即可(真实函数由 V613 定义, 这里只做桩)。
        jdbc.execute("""
                CREATE FUNCTION fn_warehouse_is_operational_leaf(uuid)
                RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT true $$
                """);
        jdbc.execute("CREATE TABLE subcontract_orders(id uuid PRIMARY KEY, deliver_date date, legacy_import_run_id uuid)");
        jdbc.execute("""
                CREATE TABLE subcontract_material_plans(id uuid PRIMARY KEY, order_id uuid,
                    order_bill_no text, status text, supplier_id uuid, close_reason text, is_deleted boolean)
                """);
        jdbc.execute("""
                CREATE TABLE subcontract_material_plan_items(id uuid PRIMARY KEY, plan_id uuid,
                    order_item_id uuid, parent_goods_id uuid, parent_color_id uuid, goods_id uuid,
                    color_id uuid, unit_id uuid, unit_rate numeric, bom_unit_qty numeric,
                    planned_qty numeric, issued_qty numeric, prepared_qty numeric, flow_mode text,
                    preparation_status text, preparation_analysis_id uuid,
                    preparation_analysis_item_id uuid, preparation_warehouse_id uuid,
                    line_no integer, is_deleted boolean)
                """);
        jdbc.execute("""
                CREATE TABLE subcontract_material_issues(id uuid PRIMARY KEY, bill_no text,
                    status smallint, bill_date date, warehouse_id uuid, approver_name text,
                    created_at timestamptz, is_deleted boolean)
                """);
        jdbc.execute("""
                CREATE TABLE subcontract_material_issue_items(id uuid PRIMARY KEY,
                    issue_id uuid, plan_item_id uuid, qty numeric)
                """);
        // These indexes already exist in V53/V304; no proposed production index is assumed.
        jdbc.execute("CREATE INDEX ON subcontract_material_plan_items(plan_id) WHERE is_deleted = FALSE");
        jdbc.execute("CREATE INDEX ON subcontract_material_issue_items(plan_item_id) WHERE plan_item_id IS NOT NULL");
        jdbc.execute("CREATE INDEX ON subcontract_material_issue_items(issue_id)");
        jdbc.execute("CREATE INDEX ON subcontract_material_issues(status)");
        jdbc.update("INSERT INTO goods VALUES (?, 'TARGET', '目标件', 'A-01')", id(6));
        jdbc.update("INSERT INTO units VALUES (?, '件')", id(4));
        jdbc.update("INSERT INTO suppliers VALUES (?, '委外商')", id(3));
        jdbc.update("INSERT INTO warehouses VALUES (?, 'WH-001', '第一仓', FALSE, FALSE, FALSE), (?, 'WH-002', '第二仓', FALSE, FALSE, FALSE)", id(7), id(8));
        jdbc.update("INSERT INTO subcontract_orders VALUES (?, DATE '2026-09-20')", id(2));
        jdbc.update("INSERT INTO subcontract_material_plans VALUES (?, ?, 'EO-001', 'OPEN', ?, NULL, FALSE)",
                id(1), id(2), id(3));
        line(11, 1, 2, "READY_OUTBOUND", 20, 20, 4, false);
        line(12, 1, 1, "LEGACY_READY", 10, 4, 2, false);
        line(13, 1, null, "READY_OUTBOUND", 10, 5, 1, false);
        line(14, 1, 3, "WAITING_FQC", 10, 10, 0, false);
        line(15, 1, 4, "READY_OUTBOUND", 10, 10, 10, false);
        line(16, 1, 5, "READY_OUTBOUND", 10, 10, 0, true);
        line(17, 9, 1, "READY_OUTBOUND", 10, 10, 0, false);
        issue(101, 0, false, 7);
        issue(102, 0, false, 8);
        issue(103, 1, false, 7);
        issue(104, 0, true, 7);
        issue(105, 2, false, 7);
        item(201, 101, 11, 2);
        item(202, 102, 11, 3);
        item(203, 103, 11, 99);
        item(204, 104, 11, 99);
        item(205, 105, 11, 99);
        item(206, 101, 13, 10);
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    @BeforeEach
    void setUp() {
        currentUser = mock(SecurityContextCurrentUser.class);
        authorize(Set.of("subcontract_outbound:execute"));
        service = new SubcontractMaterialPlanService(mock(EntityManager.class), jdbc,
                mock(DocNumberService.class), mock(SubcontractMaterialIssueRepository.class),
                mock(SubcontractMaterialIssueItemRepository.class), currentUser,
                mock(SubcontractChainNoticePort.class), mock(InventoryMutationLock.class),
                mock(SubcontractOrderPreparationPort.class),
                mock(org.springframework.beans.factory.ObjectProvider.class));
        jdbc.queries.clear();
    }

    @Test
    void preservesReadyLinesQuantitiesDraftHistoryAndWarehouseNames() {
        var detail = service.taskDetail(id(1));
        assertThat(jdbc.queries).hasSize(3);
        assertThat(detail.lines()).extracting(line -> line.planItemId())
                .containsExactly(id(12), id(11), id(13));
        var noDraft = detail.lines().get(0);
        assertThat(noDraft.draftReservedQty()).isZero();
        assertThat(noDraft.readyOutboundQty()).isEqualByComparingTo("2");
        var multipleWarehouses = detail.lines().get(1);
        assertThat(multipleWarehouses.draftReservedQty()).isEqualByComparingTo("5");
        assertThat(multipleWarehouses.readyOutboundQty()).isEqualByComparingTo("11");
        assertThat(multipleWarehouses.remainingQty()).isEqualByComparingTo("16");
        assertThat(multipleWarehouses.unitName()).isEqualTo("件");
        assertThat(multipleWarehouses.allowedActions()).containsExactly("HANDLE_OUTBOUND");
        assertThat(detail.lines().get(2).readyOutboundQty()).isZero();
        assertThat(detail.lines().get(2).draftReservedQty()).isEqualByComparingTo("10");
        assertThat(detail.drafts()).extracting(draft -> draft.issueId())
                .containsExactly(id(101), id(102), id(103), id(105));
        assertThat(detail.drafts().get(0).warehouseName()).isEqualTo("第一仓");
        assertThat(detail.drafts().get(1).warehouseName()).isEqualTo("第二仓");
        authorize(Set.of());
        assertThat(service.taskDetail(id(1)).lines())
                .allSatisfy(line -> assertThat(line.allowedActions()).isEmpty());
    }

    @Test
    void aggregatesDraftQuantityOncePerVisibleLineInsteadOfTwice() throws Exception {
        service.taskDetail(id(1));
        String detailSql = jdbc.queries.getFirst();
        // Previous calculation, retained here only as a PostgreSQL plan/work baseline.
        String previousSql = """
                SELECT pi.id,
                    COALESCE((SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                        JOIN subcontract_material_issues i ON i.id = ii.issue_id
                        WHERE ii.plan_item_id = pi.id AND i.status = 0 AND i.is_deleted = FALSE), 0),
                    GREATEST(LEAST(pi.planned_qty, pi.prepared_qty) - pi.issued_qty
                        - COALESCE((SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                            JOIN subcontract_material_issues i ON i.id = ii.issue_id
                            WHERE ii.plan_item_id = pi.id AND i.status = 0 AND i.is_deleted = FALSE), 0), 0)
                FROM subcontract_material_plan_items pi
                WHERE pi.plan_id = ? AND pi.is_deleted = FALSE
                    AND pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                    AND pi.planned_qty - pi.issued_qty > 0
                ORDER BY pi.line_no ASC NULLS LAST, pi.id
                """;
        assertThat(aggregateLoops(previousSql)).isEqualTo(6);
        assertThat(aggregateLoops(detailSql)).isEqualTo(3);
    }

    private static int aggregateLoops(String sql) throws Exception {
        String json = jdbc.queryForObject("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql,
                String.class, id(1));
        return aggregateLoops(new ObjectMapper().readTree(json).get(0).get("Plan"));
    }

    private static int aggregateLoops(JsonNode plan) {
        int loops = "Aggregate".equals(plan.path("Node Type").asText())
                ? plan.path("Actual Loops").asInt() : 0;
        for (JsonNode child : plan.path("Plans")) {
            loops += aggregateLoops(child);
        }
        return loops;
    }

    private void authorize(Set<String> permissions) {
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(id(500), id(501), "reader", permissions, false, true, false)));
    }

    private static UUID id(int value) {
        return new UUID(0, value);
    }

    private static void line(int value, int plan, Integer number, String status,
            int planned, int prepared, int issued, boolean deleted) {
        jdbc.update("""
                INSERT INTO subcontract_material_plan_items(id, plan_id, order_item_id,
                    parent_goods_id, goods_id, unit_id, unit_rate, bom_unit_qty, planned_qty,
                    prepared_qty, issued_qty, flow_mode, preparation_status, line_no, is_deleted)
                VALUES (?, ?, ?, ?, ?, ?, 1, 1, ?, ?, ?, 'DIRECT_OUTBOUND', ?, ?, ?)
                """, id(value), id(plan), id(1000 + value), id(6), id(6), id(4),
                planned, prepared, issued, status, number, deleted);
    }

    private static void issue(int value, int status, boolean deleted, int warehouse) {
        jdbc.update("""
                INSERT INTO subcontract_material_issues VALUES (?, ?, ?, DATE '2026-09-12', ?, NULL,
                    TIMESTAMPTZ '2026-09-12 00:00:00+00' + (? * INTERVAL '1 second'), ?)
                """, id(value), "EC-" + value, status, id(warehouse), value, deleted);
    }

    private static void item(int value, int issue, int line, int qty) {
        jdbc.update("INSERT INTO subcontract_material_issue_items VALUES (?, ?, ?, ?)",
                id(value), id(issue), id(line), qty);
    }

    private static final class RecordingJdbcTemplate extends JdbcTemplate {
        private final List<String> queries = new ArrayList<>();

        private RecordingJdbcTemplate(DriverManagerDataSource source) {
            super(source);
        }

        @Override
        public <T> List<T> query(String sql, RowMapper<T> mapper, Object... args) {
            queries.add(sql);
            return super.query(sql, mapper, args);
        }
    }
}
