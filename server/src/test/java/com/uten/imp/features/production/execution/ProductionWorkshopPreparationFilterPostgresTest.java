package com.uten.imp.features.production.execution;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Executes the actual pre-pagination filter SQL against current migrated column shapes.
 * Authority functions return test-owned facts; this suite does not replace their migration regressions. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionWorkshopPreparationFilterPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID WORKSHOP = new UUID(1, 1), GOODS = new UUID(1, 2), COLOR = new UUID(1, 3);
    private static JdbcTemplate jdbc;

    @BeforeAll static void schema() {
        PG.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(jdbc, "production_execution_segments", "production_plans",
                "production_planning_packages", "production_planning_package_documents", "stock_documents",
                "stock_document_items", "warehouses", "v_production_execution_workbench_segments",
                "production_daily_reports", "production_daily_report_items", "production_workshop_direct_transfer_items",
                "v_workshop_direct_supply_lots");
        MigratedProjectionSchema.installImportedDocumentPolicy(jdbc,
                "production_plans", "stock_documents", "stock_document_items");
        jdbc.execute("""
                CREATE TABLE workshop_filter_materials(segment_id uuid PRIMARY KEY, demand_id uuid,
                    goods_id uuid, color_id uuid, shortage numeric, short_count integer, make_count integer);
                CREATE TABLE workshop_filter_requests(item_id uuid PRIMARY KEY, requested_qty numeric DEFAULT 0);
                CREATE TABLE workshop_filter_flags(segment_id uuid PRIMARY KEY, discovery boolean DEFAULT false,
                    bin_state text DEFAULT 'NO_BIN');
                CREATE TABLE workshop_filter_sources(source_id uuid, demand_id uuid, capacity numeric,
                    PRIMARY KEY(source_id,demand_id));
                CREATE FUNCTION fn_execution_segment_material_summary(uuid)
                    RETURNS TABLE(short_count integer,short_make_count integer) LANGUAGE sql AS
                    'SELECT short_count,make_count FROM workshop_filter_materials WHERE segment_id=$1';
                CREATE FUNCTION fn_execution_segment_material_facts(uuid)
                    RETURNS TABLE(demand_id uuid,goods_id uuid,color_id uuid,supply_route text,shortage_qty numeric)
                    LANGUAGE sql AS 'SELECT demand_id,goods_id,color_id,''MAKE''::text,shortage
                    FROM workshop_filter_materials WHERE segment_id=$1';
                CREATE FUNCTION fn_material_discovery_pending(uuid) RETURNS boolean LANGUAGE sql AS
                    'SELECT COALESCE((SELECT discovery FROM workshop_filter_flags WHERE segment_id=$1),false)';
                CREATE FUNCTION fn_segment_bin_material_state(uuid) RETURNS text LANGUAGE sql AS
                    'SELECT COALESCE((SELECT bin_state FROM workshop_filter_flags WHERE segment_id=$1),''NO_BIN'')';
                CREATE FUNCTION fn_split_batch_empty_issued(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT false';
                CREATE FUNCTION fn_actual_supplement_material_ready(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT false';
                CREATE FUNCTION fn_production_draw_item_effective_qty(uuid) RETURNS numeric LANGUAGE sql AS
                    'SELECT qty FROM stock_document_items WHERE id=$1';
                CREATE FUNCTION fn_production_draw_item_requested_qty(uuid) RETURNS numeric LANGUAGE sql AS
                    'SELECT COALESCE((SELECT requested_qty FROM workshop_filter_requests WHERE item_id=$1),0)';
                CREATE FUNCTION fn_production_draw_fully_requested(uuid) RETURNS boolean LANGUAGE sql AS
                    'SELECT NOT EXISTS(SELECT 1 FROM stock_document_items item WHERE item.doc_id=$1
                    AND fn_production_draw_item_requested_qty(item.id)<item.qty)';
                CREATE FUNCTION fn_workshop_direct_relationship_allows(uuid,uuid) RETURNS boolean LANGUAGE sql AS
                    'SELECT EXISTS(SELECT 1 FROM workshop_filter_sources WHERE source_id=$1 AND demand_id=$2)';
                CREATE FUNCTION fn_workshop_direct_remaining_for_source(uuid,uuid) RETURNS numeric LANGUAGE sql AS
                    'SELECT COALESCE((SELECT capacity FROM workshop_filter_sources WHERE source_id=$1 AND demand_id=$2),0)';
                """);
    }

    @BeforeEach void clear() {
        jdbc.execute("TRUNCATE production_execution_segments,production_plans,production_planning_packages,"
                + "production_planning_package_documents,stock_documents,stock_document_items,warehouses,"
                + "v_production_execution_workbench_segments,workshop_filter_materials,workshop_filter_requests,"
                + "workshop_filter_flags,workshop_filter_sources,production_daily_reports,production_daily_report_items,"
                + "production_workshop_direct_transfer_items,v_workshop_direct_supply_lots");
    }

    @AfterAll static void stop() { PG.stop(); }

    private static UUID id(int n) { return new UUID(2, n); }

    private static UUID task(int n, int shortCount, int makeCount) {
        UUID id = id(n);
        jdbc.update("INSERT INTO production_plans(id,status) VALUES (?,1)", id);
        jdbc.update("INSERT INTO production_planning_packages(id,status) VALUES (?,'CONFIRMED')", id);
        jdbc.update("""
                INSERT INTO production_execution_segments(id,plan_id,package_id,status,workshop_department_id,
                    product_goods_id,product_color_id,product_unit_rate,source_plan_item_id,start_route)
                VALUES (?,?,?,'READY',?,?,?,1,?,'CONTINUOUS')
                """, id, id, id, WORKSHOP, GOODS, COLOR, id);
        jdbc.update("""
                INSERT INTO v_production_execution_workbench_segments(segment_id,segment_status,issued,
                    zero_material,workshop_department_id,remaining_qty) VALUES (?,'READY',false,false,?,10)
                """, id, WORKSHOP);
        jdbc.update("INSERT INTO warehouses(id,is_line_side) VALUES (?,false)", id);
        jdbc.update("INSERT INTO stock_documents(id,doc_type,status,warehouse_id) VALUES (?,'DRAW',0,?)", id, id);
        jdbc.update("INSERT INTO stock_document_items(id,doc_id,qty,issued_qty) VALUES (?,?,10,0)", id, id);
        jdbc.update("INSERT INTO production_planning_package_documents(document_id,document_type,execution_segment_id)"
                + " VALUES (?,'DRAW',?)", id, id);
        jdbc.update("INSERT INTO workshop_filter_materials VALUES (?,?,?,?,?,?,?)",
                id, id, GOODS, COLOR, shortCount == 0 ? 0 : 10, shortCount, makeCount);
        return id;
    }

    private static List<UUID> matches(String filter) {
        return jdbc.queryForList("SELECT task.segment_id FROM v_production_execution_workbench_segments task"
                + " WHERE true" + ProductionExecutionWorkbenchService.preparationPredicate(filter)
                + " ORDER BY task.segment_id", UUID.class);
    }

    private static void source(int n, UUID receiver, int qty, int capacity) {
        UUID source = task(n, 0, 0);
        jdbc.update("UPDATE production_execution_segments SET status='IN_PROGRESS' WHERE id=?", source);
        jdbc.update("UPDATE v_production_execution_workbench_segments SET segment_status='IN_PROGRESS',remaining_qty=?"
                + " WHERE segment_id=?", qty, source);
        jdbc.update("INSERT INTO workshop_filter_sources VALUES (?,?,?)", source, receiver, capacity);
    }

    @Test void kitAndPartialAreDisjointBeforePaginationAndPartialRequestRemainsDrawable() {
        UUID full = task(10, 0, 0), partial = task(20, 1, 1), mixed = task(30, 2, 1), requested = task(40, 0, 0);
        jdbc.update("INSERT INTO workshop_filter_requests VALUES (?,3),(?,10)", partial, requested);
        jdbc.update("UPDATE stock_document_items SET issued_qty=2 WHERE id=?", partial);
        assertThat(matches("DRAW_FULL_KIT")).containsExactly(full);
        assertThat(matches("DRAW_PARTIAL")).containsExactly(partial, mixed);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM v_production_execution_workbench_segments task WHERE true"
                + ProductionExecutionWorkbenchService.preparationPredicate("DRAW_PARTIAL"), Long.class)).isEqualTo(2);
        assertThat(jdbc.queryForList("SELECT task.segment_id FROM v_production_execution_workbench_segments task WHERE true"
                + ProductionExecutionWorkbenchService.preparationPredicate("DRAW_PARTIAL")
                + " ORDER BY task.segment_id LIMIT 1 OFFSET 1", UUID.class)).containsExactly(mixed);
    }

    @Test void eligibilityKeepsIncrementalRequestsButNeverIncludesLineSideOnlyUnresolvedOrUnconfirmedRoutes() {
        UUID valid = task(10, 0, 0), lineSide = task(20, 0, 0), issued = task(30, 0, 0),
                discovery = task(40, 0, 0), bin = task(50, 0, 0), route = task(60, 0, 0), waiting = task(70, 0, 0);
        jdbc.update("UPDATE warehouses SET is_line_side=true WHERE id=?", lineSide);
        jdbc.update("UPDATE v_production_execution_workbench_segments SET issued=true WHERE segment_id=?", issued);
        jdbc.update("INSERT INTO workshop_filter_flags(segment_id,discovery) VALUES (?,true)", discovery);
        jdbc.update("INSERT INTO workshop_filter_flags(segment_id,bin_state) VALUES (?,'NEED_CHOICE')", bin);
        jdbc.update("UPDATE production_execution_segments SET start_route='BATCH' WHERE id=?", route);
        jdbc.update("UPDATE v_production_execution_workbench_segments SET segment_status='WAITING' WHERE segment_id=?", waiting);
        assertThat(matches("DRAW_FULL_KIT")).containsExactly(valid, issued);
        jdbc.update("INSERT INTO workshop_filter_requests VALUES (?,10)", issued);
        jdbc.update("UPDATE production_execution_segments SET start_route=NULL WHERE id=?", route);
        jdbc.update("UPDATE workshop_filter_flags SET bin_state='NEED_BIN' WHERE segment_id=?", bin);
        assertThat(matches("DRAW_FULL_KIT")).containsExactly(valid);
    }

    @Test void sameWorkshopMissingKindRequiresExactSufficientLiveSourceAndMatchingColor() {
        UUID receiver = task(10, 1, 1);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        source(20, receiver, 10, 10);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).containsExactly(receiver);
        for (String mutation : List.of("UPDATE production_plans SET is_canceled=true WHERE id=?",
                "UPDATE production_plans SET is_stopped=true WHERE id=?",
                "UPDATE production_plans SET is_closed=true WHERE id=?",
                "UPDATE production_plans SET status=0 WHERE id=?",
                "UPDATE production_planning_packages SET status='CANCELLED' WHERE id=?",
                "UPDATE production_execution_segments SET status='COMPLETED' WHERE id=?",
                "UPDATE production_execution_segments SET product_color_id=NULL WHERE id=?",
                "UPDATE production_execution_segments SET workshop_department_id=NULL WHERE id=?")) {
            jdbc.update(mutation, id(20));
            assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).as(mutation).isEmpty();
            jdbc.update("UPDATE production_plans SET is_canceled=false,is_stopped=false,is_closed=false,status=1 WHERE id=?", id(20));
            jdbc.update("UPDATE production_planning_packages SET status='CONFIRMED' WHERE id=?", id(20));
            jdbc.update("UPDATE production_execution_segments SET status='IN_PROGRESS',product_color_id=?,workshop_department_id=? WHERE id=?",
                    COLOR, WORKSHOP, id(20));
        }
        jdbc.update("UPDATE workshop_filter_sources SET capacity=9 WHERE source_id=?", id(20));
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        jdbc.update("UPDATE workshop_filter_sources SET capacity=10 WHERE source_id=?", id(20));
        jdbc.update("UPDATE v_production_execution_workbench_segments SET remaining_qty=9 WHERE segment_id=?", id(20));
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        jdbc.update("UPDATE production_execution_segments SET product_unit_rate=2 WHERE id=?", id(20));
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).containsExactly(receiver);
    }

    @Test void multipleMissingKindsOrExternalShortagesNeverQualifyAndSplitSharesAreNotCountedTwice() {
        UUID receiver = task(10, 1, 1);
        source(20, receiver, 3, 5);
        source(30, receiver, 7, 5);
        jdbc.update("UPDATE production_execution_segments SET source_plan_item_id=? WHERE id=?", id(20), id(30));
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        jdbc.update("UPDATE workshop_filter_sources SET capacity=10");
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).containsExactly(receiver);
        jdbc.update("UPDATE workshop_filter_materials SET short_count=2,make_count=2 WHERE segment_id=?", receiver);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        jdbc.update("UPDATE workshop_filter_materials SET short_count=1,make_count=0 WHERE segment_id=?", receiver);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
    }

    @Test void reportedSourceWaitingForQualityOrReceiptStillExplainsTheShortageWithoutBecomingStock() {
        UUID receiver = task(10, 1, 1);
        source(20, receiver, 0, 10);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        jdbc.update("UPDATE v_production_execution_workbench_segments SET fqc_pending_qty=10 WHERE segment_id=?", id(20));
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).containsExactly(receiver);
        jdbc.update("UPDATE v_production_execution_workbench_segments SET fqc_pending_qty=0,finished_inbound_pending_qty=10 WHERE segment_id=?", id(20));
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).containsExactly(receiver);
        jdbc.update("UPDATE production_execution_segments SET status='COMPLETED' WHERE id=?", id(20));
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).containsExactly(receiver);
        jdbc.update("UPDATE v_production_execution_workbench_segments SET finished_inbound_pending_qty=0 WHERE segment_id=?", id(20));
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        assertThat(jdbc.queryForObject("SELECT shortage FROM workshop_filter_materials WHERE segment_id=?", Integer.class, receiver))
                .isEqualTo(10);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM workshop_filter_requests", Integer.class)).isZero();
    }

    @Test void promisedDirectDeliveryIsIncludedUntilReceivedButReversedOrDraftReportsDoNotSupplyIt() {
        UUID receiver = task(10, 1, 1), producing = id(20), report = id(21), reportItem = id(22), transfer = id(23);
        source(20, receiver, 0, 0);
        jdbc.update("UPDATE v_production_execution_workbench_segments SET fqc_pending_qty=10 WHERE segment_id=?", producing);
        jdbc.update("INSERT INTO production_daily_reports(id,status) VALUES (?,1)", report);
        jdbc.update("INSERT INTO production_daily_report_items(id,report_id,execution_segment_id,unit_rate) VALUES (?,?,?,1)",
                reportItem, report, producing);
        jdbc.update("INSERT INTO production_workshop_direct_transfer_items(id,source_report_item_id,to_demand_id,qty) VALUES (?,?,?,10)",
                transfer, reportItem, receiver);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).containsExactly(receiver);
        jdbc.update("UPDATE production_workshop_direct_transfer_items SET reversal_id=? WHERE id=?", id(99), transfer);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        jdbc.update("UPDATE production_workshop_direct_transfer_items SET reversal_id=NULL WHERE id=?", transfer);
        jdbc.update("UPDATE production_daily_reports SET status=0 WHERE id=?", report);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        jdbc.update("UPDATE production_daily_reports SET status=1 WHERE id=?", report);
        jdbc.update("INSERT INTO v_workshop_direct_supply_lots(id,received_qty) VALUES (?,4)", transfer);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).isEmpty();
        jdbc.update("UPDATE workshop_filter_materials SET shortage=6 WHERE segment_id=?", receiver);
        assertThat(matches("SAME_WORKSHOP_MAKE_ONLY")).containsExactly(receiver);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM workshop_filter_requests", Integer.class)).isZero();
    }
}
