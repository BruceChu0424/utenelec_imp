package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.support.LoadingGrowthEvidence;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.util.ReflectionTestUtils;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * W7 P2.2 增长守卫(2026-11-08)：生产执行根视图在导入历史计划增长下，「进行中」徽章与默认
 * 列表(同一 {@code CURRENT_ROOT_PREDICATE})结果精确、逐根计划探查不被已完结历史拖动。
 *
 * <p>公司库形状：7,570 张计划里 7,470 张是导入历史根(全部登记、没有执行段)，约 4% 仍未
 * 完结。本守卫在当前迁移结构上(V1094 根视图 + V1117 共享段扫描，真实列/约束/索引)注入同形
 * 历史，断言：徽章数恒等于原生根数、全量根数恒等于原生根 + 未完结历史根；已完结的历史计划
 * 在计划状态条件处短路，逐根「计划还有未完成明细」探查只对未完结的计划执行，且走
 * production_plan_items 的计划索引。</p>
 *
 * <p>与应用一致地关闭 JIT：应用连接初始化固定 {@code SET jit = false}(UTEN_DB_JIT 默认关)。
 * 这个视图的计划代价远超 jit_above_cost，开着 JIT 时编译开销占满计时——W2 记录的「根视图
 * count 2,151ms / 段视图整页 1.70s」都是 psql 开 JIT 的读数，2026-11-08 公司库只读复测关 JIT
 * 分别是 90ms / 85ms。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionExecutionWorkbenchGrowthPostgresTest {
    private static final int CURRENT_ANALYSES = 2;
    private static final int CURRENT_PLANS = 3;
    /** 公司库约 4% 的导入计划仍未完结：每 25 张历史计划留 1 张未完结。 */
    private static final int OPEN_HISTORY_EVERY = 25;

    @Test
    void importedHistoryKeepsCurrentRootsExactWhileClosedPlansShortCircuit() throws Exception {
        String current = (String) ReflectionTestUtils.getField(
                ProductionExecutionWorkbenchService.class, "CURRENT_ROOT_PREDICATE");
        // inProgressRootCount 的超管(seeAll)口径：同一视图、同一谓词。
        String badge = "SELECT count(*) FROM v_production_execution_workbench_roots root"
                + " WHERE root.owner_employee_id IS NOT NULL AND " + current;
        // 默认列表(全量可见)：没有 owner 谓词，导入历史根要经过逐根汇总才被谓词剔除。
        String list = "SELECT count(*) FROM v_production_execution_workbench_roots root WHERE " + current;
        String allRoots = "SELECT count(*) FROM v_production_execution_workbench_roots";
        try (var lease = MigratedSchemaBaseline.openDatabase("workbench_growth");
             var connection = lease.openConnection()) {
            connection.setAutoCommit(false);
            try {
                var db = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
                db.execute("CREATE SCHEMA workbench_growth_fixture");
                db.execute("SET LOCAL search_path=workbench_growth_fixture,public");
                db.execute("SET LOCAL jit = off");
                MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                        "employees", "production_material_analyses", "production_material_analysis_items",
                        "preplan_supply_actions", "preplan_make_public_claims",
                        "v_production_execution_workbench_segments", "v_production_analysis_workbench_item_progress",
                        "execution_segment_sales_allocations", "sales_order_items", "sales_orders",
                        "goods", "units", "colors");
                // 逐根 LATERAL 与登记表谓词要用到的真实约束与索引。
                MigratedProjectionSchema.copyConstrainedTablesFromMigratedCatalog(connection,
                        "production_plans", "production_plan_items", "subplan_links", "imported_document_registry");
                db.execute(migration("V1094__execution_workbench_top_level_product_caliber.sql"));
                db.execute(migration("V1117__execution_workbench_roots_shared_segment_scan.sql"));
                seedCurrentRoots(db);

                int kept = CURRENT_ANALYSES + CURRENT_PLANS;
                int previous = 0;
                for (int history : List.of(1_000, 10_000, 30_000)) {
                    injectImportedHistory(db, previous + 1, history);
                    previous = history;
                    db.execute("ANALYZE production_plans, production_plan_items, subplan_links, imported_document_registry");
                    int openHistory = history / OPEN_HISTORY_EVERY;

                    assertThat(db.queryForObject(badge, Long.class))
                            .as("导入历史不进「进行中」徽章").isEqualTo(kept);
                    assertThat(db.queryForObject(list, Long.class))
                            .as("导入历史不进默认列表(与徽章同数)").isEqualTo(kept);
                    assertThat(db.queryForObject(allRoots, Long.class))
                            .as("未完结的导入计划仍是根(历史列表口径)").isEqualTo(kept + openHistory);

                    String plan = db.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) " + list, String.class);
                    List<JsonNode> probes = nodesReading(plan, "production_plan_items");
                    long probeLoops = probes.stream().mapToLong(node -> node.path("Actual Loops").asLong()).max().orElse(0);
                    assertThat(probeLoops)
                            .as("已完结历史计划在状态条件处短路，明细探查只对未完结计划执行: " + plan)
                            .isLessThanOrEqualTo(CURRENT_PLANS + openHistory);
                    assertThat(probes).as("计划明细探查走计划索引，不随历史整表扫描: " + plan)
                            .noneMatch(node -> "Seq Scan".equals(node.path("Node Type").asText()));
                    Map<String, Object> values = new LinkedHashMap<>();
                    values.put("jit", "off (as the application's connection-init-sql)");
                    values.put("currentRoots", kept);
                    values.put("importedPlans", history);
                    values.put("openImportedRoots", openHistory);
                    values.put("listPlanItemProbeLoops", probeLoops);
                    values.put("badge", LoadingGrowthEvidence.samples(() -> db.queryForObject(badge, Long.class)));
                    values.put("list", LoadingGrowthEvidence.samples(() -> db.queryForObject(list, Long.class)));
                    values.put("allRoots", LoadingGrowthEvidence.samples(() -> db.queryForObject(allRoots, Long.class)));
                    LoadingGrowthEvidence.write("workshop-roots-current", history, values, plan);
                }
            } finally {
                connection.rollback();
            }
        }
    }

    /** Native roots: two analyses with remaining demand and three open plans, one with segments. */
    private static void seedCurrentRoots(JdbcTemplate db) {
        db.update("INSERT INTO employees(id,full_name) VALUES (md5('maker')::uuid,'计划员')");
        db.update("INSERT INTO units(id,name) VALUES (md5('unit')::uuid,'个')");
        db.update("INSERT INTO goods(id,code,name) VALUES (md5('goods')::uuid,'G-1','货品1')");
        db.update("""
                INSERT INTO production_material_analyses(id,maker_id,status,is_deleted,analysis_no)
                SELECT md5('analysis'||n)::uuid, md5('maker')::uuid, 'ACTIVE', FALSE, 'WL-'||n
                FROM generate_series(1,?)n""", CURRENT_ANALYSES);
        db.update("""
                INSERT INTO production_material_analysis_items(id,analysis_id,goods_id,unit_id,source_type,requested_qty,is_deleted)
                SELECT md5('analysis-item'||n)::uuid, md5('analysis'||n)::uuid, md5('goods')::uuid, md5('unit')::uuid,
                       'SALES_ORDER_ITEM', 10, FALSE
                FROM generate_series(1,?)n""", CURRENT_ANALYSES);
        db.update("""
                INSERT INTO v_production_analysis_workbench_item_progress(analysis_id,analysis_item_id,remaining_schedule_qty)
                SELECT md5('analysis'||n)::uuid, md5('analysis-item'||n)::uuid, 5
                FROM generate_series(1,?)n""", CURRENT_ANALYSES);
        db.update("""
                INSERT INTO production_plans(id,maker_id,bill_no,bill_date,delivery_date,status,
                    is_deleted,is_closed,is_stopped,is_canceled)
                SELECT md5('plan'||n)::uuid, md5('maker')::uuid, 'JH-'||n, DATE '2026-11-01', DATE '2026-12-01', 1,
                       FALSE, FALSE, FALSE, FALSE
                FROM generate_series(1,?)n""", CURRENT_PLANS);
        db.update("""
                INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,
                    allowed_overproduction_rate,qty,iqty,is_deleted)
                SELECT md5('plan-item'||n)::uuid, md5('plan'||n)::uuid, 'JH-'||n, DATE '2026-11-01', 'JH-I-'||n,
                       md5('goods')::uuid, 0, 10, 1, FALSE
                FROM generate_series(1,?)n""", CURRENT_PLANS);
        db.update("""
                INSERT INTO v_production_execution_workbench_segments(segment_id,plan_id,root_type,root_id,segment_code,
                    segment_status,material_status,warehouse_ready,issued,reportable,product_goods_id,product_code,
                    product_name,planned_qty,reported_qty,fqc_pending_qty,fqc_passed_qty,fqc_failed_qty,
                    finished_inbound_pending_qty,inbound_qty,planned_inbound_qty,plan_begin_date,plan_end_date)
                SELECT md5('segment'||n)::uuid, md5('plan1')::uuid, 'PLAN', md5('plan1')::uuid, 'GD-'||n,
                       'WAITING', 'KIT_SHORT', FALSE, FALSE, FALSE, md5('goods')::uuid, 'G-1', '货品1',
                       10, 0, 0, 0, 0, 0, 0, 0, DATE '2026-11-01', DATE '2026-12-01'
                FROM generate_series(1,2)n""");
    }

    /** Imported plans as the company data has them: registered, no execution segments, mostly finished. */
    private static void injectImportedHistory(JdbcTemplate db, int from, int to) {
        String range = " FROM generate_series(" + from + "," + to + ")n";
        db.update("""
                INSERT INTO production_plans(id,maker_id,bill_no,bill_date,delivery_date,status,
                    is_deleted,is_closed,is_stopped,is_canceled)
                SELECT md5('history-plan'||n)::uuid, md5('maker')::uuid, 'HIS-'||n, DATE '2024-01-01', DATE '2024-02-01', 1,
                       FALSE, n%""" + OPEN_HISTORY_EVERY + "<>0, FALSE, FALSE" + range);
        db.update("""
                INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,
                    allowed_overproduction_rate,qty,iqty,is_deleted)
                SELECT md5('history-item'||n)::uuid, md5('history-plan'||n)::uuid, 'HIS-'||n, DATE '2024-01-01',
                       'HIS-I-'||n, md5('goods')::uuid, 0, 10,
                       CASE WHEN n%""" + OPEN_HISTORY_EVERY + "=0 THEN 1 ELSE 10 END, FALSE" + range);
        db.update("INSERT INTO imported_document_registry(table_name,row_id)"
                + " SELECT 'production_plans', md5('history-plan'||n)::uuid" + range);
    }

    /** Plan nodes that read the given relation. */
    private static List<JsonNode> nodesReading(String plan, String relation) throws Exception {
        List<JsonNode> nodes = new ArrayList<>();
        for (JsonNode node : new ObjectMapper().readTree(plan).findParents("Node Type")) {
            if (relation.equals(node.path("Relation Name").asText())) nodes.add(node);
        }
        return nodes;
    }

    private static String migration(String file) throws Exception {
        Path direct = Path.of("src/main/resources/db/migration").resolve(file);
        return Files.readString(Files.exists(direct) ? direct : Path.of("server").resolve(direct));
    }
}
