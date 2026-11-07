package com.uten.imp.features.production.execution;

import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * V1117 rewrites the V1094 root view in place so every rollup reads one materialized
 * segment-view evaluation. Both definitions run over the same migrated column shapes and
 * the same mixed roots; every output column must stay value-for-value identical.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionExecutionWorkbenchRootsSharedScanPostgresTest {
    private static final String[] COLORS = {"红", "蓝", "绿", "黑", null};
    private static final String[] UNITS = {"个", "套", null};
    private static final String[] STATUSES = {"WAITING", "READY", "DISPATCHED", "IN_PROGRESS", "COMPLETED", "CANCELLED", "REVERSED"};

    @Test
    void sharedSegmentScanKeepsEveryRootValueOfTheV1094Definition() throws Exception {
        try (var lease = MigratedSchemaBaseline.openDatabase("roots_shared_scan");
             var connection = lease.openConnection()) {
            connection.setAutoCommit(false);
            try {
                var db = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
                db.execute("CREATE SCHEMA roots_shared_scan_fixture");
                db.execute("SET LOCAL search_path=roots_shared_scan_fixture,public");
                MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                        "employees", "production_material_analyses", "production_material_analysis_items",
                        "production_plans", "production_plan_items", "subplan_links", "preplan_supply_actions",
                        "preplan_make_public_claims", "v_production_execution_workbench_segments",
                        "v_production_analysis_workbench_item_progress", "execution_segment_sales_allocations",
                        "sales_order_items", "sales_orders", "goods", "units", "colors");
                db.execute(migration("V1094__execution_workbench_top_level_product_caliber.sql"));
                int roots = seed(db);

                db.execute("CREATE TEMP TABLE roots_before ON COMMIT DROP AS SELECT * FROM v_production_execution_workbench_roots");
                db.execute(migration("V1117__execution_workbench_roots_shared_segment_scan.sql"));
                db.execute("CREATE TEMP TABLE roots_after ON COMMIT DROP AS SELECT * FROM v_production_execution_workbench_roots");

                assertThat(db.queryForObject("SELECT COUNT(*) FROM roots_before", Integer.class)).isEqualTo(roots);
                assertThat(db.queryForObject("SELECT COUNT(*) FROM roots_after", Integer.class)).isEqualTo(roots);
                assertThat(db.queryForObject("""
                        SELECT COUNT(*) FROM ((SELECT * FROM roots_before EXCEPT ALL SELECT * FROM roots_after)
                                        UNION ALL (SELECT * FROM roots_after EXCEPT ALL SELECT * FROM roots_before)) difference
                        """, Integer.class)).isZero();
                // The fixture exercises the more-than-three previews and both root kinds.
                assertThat(db.queryForObject("""
                        SELECT COUNT(*) FROM roots_after WHERE work_order_has_more AND product_has_more
                          AND workshop_has_more AND sales_order_has_more AND execution_unit_count > 1
                        """, Integer.class)).isPositive();
                assertThat(db.queryForList("SELECT DISTINCT root_type FROM roots_after ORDER BY 1", String.class))
                        .containsExactly("ANALYSIS", "PLAN");

                String definition = db.queryForObject(
                        "SELECT pg_get_viewdef('v_production_execution_workbench_roots'::regclass, true)", String.class);
                assertThat(definition).contains("workbench_segment_facts AS MATERIALIZED");
                assertThat(definition.split("v_production_execution_workbench_segments", -1)).hasSize(2);
                // The anchors refuse a second rewrite instead of rewriting an unknown shape.
                db.execute("SAVEPOINT rerun");
                assertThatThrownBy(() -> db.execute(migration("V1117__execution_workbench_roots_shared_segment_scan.sql")))
                        .hasMessageContaining("Execution workbench root rollup anchors changed");
                db.execute("ROLLBACK TO SAVEPOINT rerun");
            } finally {
                connection.rollback();
            }
        }
    }

    /** Mixed analysis and legacy plan roots; returns the number of roots the view keeps. */
    private static int seed(JdbcTemplate db) {
        UUID maker = UUID.randomUUID();
        db.update("INSERT INTO employees(id,full_name) VALUES (?,'计划员')", maker);
        UUID[] colors = new UUID[COLORS.length];
        for (int index = 0; index < COLORS.length; index++) {
            if (COLORS[index] == null) continue;
            colors[index] = UUID.randomUUID();
            db.update("INSERT INTO colors(id,name) VALUES (?,?)", colors[index], COLORS[index]);
        }
        UUID unit = UUID.randomUUID();
        db.update("INSERT INTO units(id,name) VALUES (?,'个')", unit);
        UUID[] orders = new UUID[5];
        UUID[] orderItems = new UUID[5];
        for (int index = 0; index < orders.length; index++) {
            orders[index] = UUID.randomUUID();
            orderItems[index] = UUID.randomUUID();
            db.update("INSERT INTO sales_orders(id,bill_no) VALUES (?,?)", orders[index], "SO-" + (9 - index));
            db.update("INSERT INTO sales_order_items(id,order_id) VALUES (?,?)", orderItems[index], orders[index]);
        }
        int kept = 0;
        int segmentNumber = 0;
        // Analysis roots: active with segments, active without segments (quantity fallback),
        // cancelled and deleted analyses (never roots).
        for (int analysisIndex = 0; analysisIndex < 4; analysisIndex++) {
            UUID analysis = UUID.randomUUID();
            boolean cancelled = analysisIndex == 2, deleted = analysisIndex == 3;
            db.update("INSERT INTO production_material_analyses(id,maker_id,status,is_deleted,analysis_no) VALUES (?,?,?,?,?)",
                    analysis, maker, cancelled ? "CANCELLED" : "ACTIVE", deleted, "WL-" + analysisIndex);
            if (!cancelled && !deleted) kept++;
            UUID[] items = new UUID[6];
            for (int itemIndex = 0; itemIndex < items.length; itemIndex++) {
                items[itemIndex] = UUID.randomUUID();
                UUID goods = goods(db, "A" + analysisIndex + "-" + itemIndex);
                boolean component = itemIndex == 4, child = itemIndex == 5;
                db.update("""
                        INSERT INTO production_material_analysis_items(id,analysis_id,goods_id,unit_id,color_id,source_type,
                            requested_qty,parent_analysis_material_id,sales_order_item_id,is_deleted)
                        VALUES (?,?,?,?,?,?,?,?,?,FALSE)
                        """, items[itemIndex], analysis, goods, unit, colors[itemIndex % colors.length],
                        component ? "MAKE_COMPONENT" : "SALES_ORDER_ITEM", BigDecimal.valueOf(10 + itemIndex),
                        child ? UUID.randomUUID() : null, orderItems[itemIndex % orderItems.length]);
                db.update("INSERT INTO v_production_analysis_workbench_item_progress(analysis_id,analysis_item_id,remaining_schedule_qty) VALUES (?,?,?)",
                        analysis, items[itemIndex], BigDecimal.valueOf(analysisIndex == 1 ? 3 : 0));
            }
            if (analysisIndex == 1) continue;
            for (int itemIndex = 0; itemIndex < items.length; itemIndex++) {
                UUID plan = UUID.randomUUID();
                db.update("""
                        INSERT INTO production_plans(id,maker_id,material_analysis_id,material_analysis_item_id,status,
                            is_deleted,is_closed,is_stopped,is_canceled,bill_date,delivery_date)
                        VALUES (?,?,?,?,1,FALSE,FALSE,FALSE,FALSE,?,?)
                        """, plan, maker, analysis, itemIndex % 2 == 0 ? items[itemIndex] : null,
                        LocalDate.parse("2026-10-01").plusDays(itemIndex), LocalDate.parse("2026-11-01").plusDays(itemIndex));
                db.update("INSERT INTO production_plan_items(id,plan_id,qty,iqty,is_deleted) VALUES (?,?,10,?,FALSE)",
                        UUID.randomUUID(), plan, itemIndex % 3 == 0 ? BigDecimal.TEN : BigDecimal.ONE);
                for (int copy = 0; copy < 2; copy++) {
                    segmentNumber = segment(db, "ANALYSIS", analysis, plan, segmentNumber, colors, orderItems);
                }
            }
        }
        // Legacy plan roots: open, draft, closed with a parent link (child, not a root), completed only.
        for (int planIndex = 0; planIndex < 4; planIndex++) {
            UUID plan = UUID.randomUUID();
            boolean draft = planIndex == 1, child = planIndex == 2, completed = planIndex == 3;
            db.update("""
                    INSERT INTO production_plans(id,maker_id,bill_no,status,is_deleted,is_closed,is_stopped,is_canceled,bill_date,delivery_date)
                    VALUES (?,?,?,?,FALSE,?,FALSE,FALSE,?,?)
                    """, plan, maker, "JH-" + planIndex, draft ? 0 : 1, completed,
                    LocalDate.parse("2026-09-01").plusDays(planIndex), LocalDate.parse("2026-12-01").plusDays(planIndex));
            db.update("INSERT INTO production_plan_items(id,plan_id,qty,iqty,is_deleted) VALUES (?,?,10,?,FALSE)",
                    UUID.randomUUID(), plan, completed ? BigDecimal.TEN : BigDecimal.ONE);
            if (child) {
                db.update("INSERT INTO subplan_links(id,plan_id,subplan_id,is_deleted) VALUES (?,?,?,FALSE)",
                        UUID.randomUUID(), UUID.randomUUID(), plan);
            }
            if (!child && !completed) kept++;
            for (int copy = 0; copy < (completed ? 1 : 5); copy++) {
                segmentNumber = segment(db, "PLAN", plan, plan, segmentNumber, colors, orderItems);
            }
            if (completed) {
                db.update("UPDATE v_production_execution_workbench_segments SET segment_status='COMPLETED' WHERE root_id=?", plan);
            }
        }
        return kept;
    }

    private static int segment(JdbcTemplate db, String rootType, UUID root, UUID plan, int number,
                               UUID[] colors, UUID[] orderItems) {
        UUID segment = UUID.randomUUID();
        int product = number % 5;
        String color = COLORS[number % COLORS.length];
        db.update("""
                INSERT INTO v_production_execution_workbench_segments(
                    segment_id, plan_id, root_type, root_id, segment_code, segment_status, material_status,
                    warehouse_ready, issued, reportable, workshop_department_id, workshop_name,
                    product_goods_id, product_code, product_name, product_color_name, product_unit_name,
                    planned_qty, reported_qty, fqc_pending_qty, fqc_passed_qty, fqc_failed_qty,
                    finished_inbound_pending_qty, inbound_qty, planned_inbound_qty, plan_begin_date, plan_end_date)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, segment, plan, rootType, root, "GD-" + (1000 - number), STATUSES[number % STATUSES.length],
                number % 3 == 0 ? "KIT_READY" : "KIT_SHORT", number % 2 == 0, number % 4 == 0, number % 5 == 0,
                new UUID(9, number % 5), number % 6 == 0 ? null : "车间" + (number % 5),
                new UUID(8, product), "CP-" + product, "产品" + product, color, UNITS[number % UNITS.length],
                BigDecimal.valueOf(20 + number), BigDecimal.valueOf(number % 7), BigDecimal.valueOf(number % 3),
                BigDecimal.valueOf(number % 2), BigDecimal.ZERO, BigDecimal.valueOf(number % 4),
                BigDecimal.valueOf(number % 9), BigDecimal.valueOf(number % 8),
                LocalDate.parse("2026-10-01").plusDays(number % 11), LocalDate.parse("2026-11-01").plusDays(number % 13));
        db.update("INSERT INTO execution_segment_sales_allocations(id,execution_segment_id,sales_order_item_id) VALUES (?,?,?)",
                UUID.randomUUID(), segment, orderItems[number % orderItems.length]);
        return number + 1;
    }

    private static UUID goods(JdbcTemplate db, String code) {
        UUID goods = UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name) VALUES (?,?,?)", goods, "G-" + code, "货品" + code);
        return goods;
    }

    private static String migration(String file) throws Exception {
        Path direct = Path.of("src/main/resources/db/migration").resolve(file);
        return Files.readString(Files.exists(direct) ? direct : Path.of("server").resolve(direct));
    }
}
