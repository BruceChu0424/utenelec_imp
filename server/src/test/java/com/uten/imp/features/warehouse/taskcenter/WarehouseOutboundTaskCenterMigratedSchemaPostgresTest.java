package com.uten.imp.features.warehouse.taskcenter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Real migrated column/function contracts complement the isolated paging/function fixture. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseOutboundTaskCenterMigratedSchemaPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private NamedParameterJdbcTemplate jdbc;
    private static final UUID ACTOR = UUID.randomUUID();

    @BeforeAll static void baseline() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("warehouse_outbound_query");
    }
    @AfterAll static void closeBaseline() throws Exception { if (database != null) database.close(); }

    @BeforeEach void projection() throws Exception {
        connection = database.openConnection();
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE SCHEMA outbound_query_oracle");
            statement.execute("SET LOCAL search_path=outbound_query_oracle,public");
        }
        // Copy the actual migration head, without inventing columns or rewriting production functions.
        // Rollback-only projection facts omit command triggers; command invariants have separate oracles.
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                "warehouses", "clients", "suppliers", "employees", "departments", "goods", "colors", "units",
                "sales_shipments", "sales_shipment_items", "subcontract_material_issues", "subcontract_material_issue_items",
                "subcontract_material_plan_items", "subcontract_material_plans", "stock_documents", "stock_document_items",
                "production_material_discovery_requests", "production_material_discovery_lines",
                "production_planning_package_document_items", "production_execution_segments", "production_plans");
        jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
    }
    @AfterEach void rollback() throws Exception {
        if (connection != null) { connection.rollback(); connection.close(); }
    }

    @Test void allSourceAndDetailProjectionsExecuteAgainstRealMigratedColumnTypes() {
        for (WarehouseTaskScope scope : List.of(WarehouseTaskScope.ALL,
                new WarehouseTaskScope(true, List.of(UUID.randomUUID()), true))) {
            var plan = plan(scope, null, null);
            assertThat(jdbc.queryForObject(plan.countSql(), parameters(plan), Long.class)).isZero();
            assertThat(jdbc.queryForList(plan.rowsSql(), parameters(plan).addValue("limit", 20).addValue("offset", 0L))).isEmpty();
            assertThat(jdbc.queryForList(plan.facetsSql(), parameters(plan))).isEmpty();
            assertThat(jdbc.queryForList(plan.billNoFacetsSql(), parameters(plan))).isEmpty();
            assertThat(jdbc.queryForList(plan.identitySql(), parameters(plan).addValue("rowSource", "SALES")
                    .addValue("rowRecord", "SALES_SHIPMENT").addValue("rowId", UUID.randomUUID()))).isEmpty();
        }
        for (Row document : List.of(
                document("SALES", "SALES_SHIPMENT", "SALES_CANCELLED"),
                document("SUBCONTRACT", "SUBCONTRACT_MATERIAL_ISSUE", "SUBCONTRACT_WITHDRAWN"),
                document("DRAW", "STOCK_DOC", "DRAW_REVERSED"),
                document("OTHER", "STOCK_DOC", "OTHER_REVERSED"),
                document("FINISHED", "STOCK_DOC", "FINISHED_CLOSED"),
                document("DRAW", "MATERIAL_DISCOVERY", "DRAW_DISCOVERY_CANCELLED"),
                document("DRAW", "MATERIAL_DISCOVERY", "DRAW_DISCOVERY_CONFIGURED"))) {
            assertThat(jdbc.queryForList(WarehouseOutboundTaskCenterQueryService.physicalLines(document),
                    new MapSqlParameterSource("documentId", document.id()))).isEmpty();
        }
    }

    @Test void cancelledAndRetainedSourcesShareGlobalPagesButKeepIndependentIdentitiesAndPhysicalLines() throws Exception {
        UUID shared = UUID.randomUUID(), warehouse = UUID.randomUUID(), hiddenWarehouse = UUID.randomUUID();
        execute("""
                INSERT INTO sales_shipments(id,bill_no,bill_date,warehouse_id,owner_employee_id,finance_audit,status,
                    rejected,warehouse_work_status,review_revision,is_deleted)
                VALUES(:id,'SAME-3','2026-10-12',:warehouse,:owner,1,0,TRUE,'CANCELLED',4,FALSE)
                """, "id", shared, "warehouse", warehouse, "owner", ACTOR);
        execute("""
                INSERT INTO subcontract_material_issues(id,bill_no,bill_date,warehouse_id,maker_id,status,is_closed,is_deleted)
                VALUES(:id,'SAME-2','2026-10-12',:warehouse,:owner,0,FALSE,TRUE)
                """, "id", shared, "warehouse", warehouse, "owner", ACTOR);
        UUID materialPlan = UUID.randomUUID(), planItem = UUID.randomUUID(), retainedLine = UUID.randomUUID();
        execute("INSERT INTO subcontract_material_plans(id,order_bill_no) VALUES(:id,'ORDER')", "id", materialPlan);
        execute("INSERT INTO subcontract_material_plan_items(id,plan_id) VALUES(:id,:plan)", "id", planItem, "plan", materialPlan);
        execute("""
                INSERT INTO subcontract_material_issue_items(id,issue_id,plan_item_id,line_no,goods_code_snapshot,
                    goods_name_snapshot,qty,requested_qty,weight,is_deleted)
                VALUES(:id,:issue,:planItem,1,'PHYSICAL','保留物料',3,4,2,TRUE)
                """, "id", retainedLine, "issue", shared, "planItem", planItem);
        execute("""
                INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,maker_id,status,issue_status,is_closed,is_deleted)
                VALUES(:id,'OTHER_OUT','SAME-1','2026-10-12',:warehouse,:owner,-1,0,FALSE,FALSE)
                """, "id", shared, "warehouse", warehouse, "owner", ACTOR);
        execute("""
                INSERT INTO sales_shipments(id,bill_no,bill_date,warehouse_id,owner_employee_id,finance_audit,status,
                    rejected,warehouse_work_status,review_revision,is_deleted)
                VALUES(:id,'HIDDEN','2026-10-12',:warehouse,:owner,1,0,FALSE,'PENDING_PICK',1,FALSE)
                """, "id", UUID.randomUUID(), "warehouse", hiddenWarehouse, "owner", ACTOR);

        var plan = plan(new WarehouseTaskScope(true, List.of(warehouse), false), null, null);
        assertThat(jdbc.queryForObject(plan.countSql(), parameters(plan), Long.class)).isEqualTo(3);
        var first = jdbc.queryForList(plan.rowsSql(), parameters(plan).addValue("limit", 2).addValue("offset", 0L));
        var second = jdbc.queryForList(plan.rowsSql(), parameters(plan).addValue("limit", 2).addValue("offset", 2L));
        assertThat(first).extracting(row -> row.get("bill_no")).containsExactly("SAME-1", "SAME-2");
        assertThat(second).extracting(row -> row.get("bill_no")).containsExactly("SAME-3");
        assertThat(java.util.stream.Stream.concat(first.stream(), second.stream())
                .map(row -> row.get("source_type") + ":" + row.get("record_type") + ":" + row.get("id")).distinct().count()).isEqualTo(3);
        assertThat(first).allSatisfy(row -> assertThat(row.get("actionable")).isEqualTo(false));
        assertThat(second.getFirst().get("status")).isEqualTo("SALES_CANCELLED");
        assertThat(jdbc.queryForList(plan.billNoFacetsSql(), parameters(plan))).hasSize(3);

        var withdrawn = plan(new WarehouseTaskScope(true, List.of(warehouse), false), "SUBCONTRACT_WITHDRAWN", "SAME-2");
        assertThat(jdbc.queryForObject(withdrawn.countSql(), parameters(withdrawn), Long.class)).isEqualTo(1);
        var lines = jdbc.queryForList(WarehouseOutboundTaskCenterQueryService.physicalLines(
                new Row("SUBCONTRACT:SUBCONTRACT_MATERIAL_ISSUE:" + shared, shared, "SUBCONTRACT", "SUBCONTRACT_MATERIAL_ISSUE",
                        "SAME-2", null, LocalDate.of(2026, 10, 12), "", "", "", 1,
                        "SUBCONTRACT_WITHDRAWN", "委外出库 · 领料已撤回", "neutral", "HISTORY_DETAIL", shared, false, Map.of())),
                new MapSqlParameterSource("documentId", shared));
        assertThat(lines).hasSize(1);
        assertThat(lines.getFirst().get("id")).isEqualTo(retainedLine);
        assertThat(new ObjectMapper().findAndRegisterModules().writeValueAsString(List.of(first, second, lines)))
                .doesNotContain("price", "amount", "currency", "cost");
    }

    private static WarehouseOutboundTaskCenterSql.Plan plan(WarehouseTaskScope scope, String status, String billNo) {
        return WarehouseOutboundTaskCenterSql.build(new Filter("ALL", status, null, billNo, null, null, null, 1, 20, "billNo", "asc"),
                new WarehouseOutboundTaskCenterSql.Access(true, true, true, true, true, new OwnerScope(false, Set.of(ACTOR))), scope, ACTOR.toString());
    }
    private static MapSqlParameterSource parameters(WarehouseOutboundTaskCenterSql.Plan plan) {
        return new MapSqlParameterSource(plan.parameters());
    }
    private static Row document(String source, String record, String status) {
        UUID id = UUID.randomUUID();
        return new Row(source + ":" + record + ":" + id, id, source, record, null, null, null,
                "", "", "", 0, status, status, "neutral", "HISTORY_DETAIL", id, false, Map.of());
    }
    @Test void malformedFixtureBindingsFailBeforeAnyDatabaseWrite() {
        assertThatThrownBy(() -> execute("SELECT 1", "missingValue"))
                .isInstanceOf(IllegalArgumentException.class).hasMessage("SQL fixture parameters must be key/value pairs");
    }

    private void execute(String sql, Object... parameters) {
        if (parameters.length % 2 != 0) throw new IllegalArgumentException("SQL fixture parameters must be key/value pairs");
        MapSqlParameterSource values = new MapSqlParameterSource();
        for (int index = 0; index + 1 < parameters.length; index += 2) values.addValue((String) parameters[index], parameters[index + 1]);
        jdbc.update(sql, values);
    }
}
