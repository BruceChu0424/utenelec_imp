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
                "production_planning_package_document_items", "production_execution_segments", "production_plans",
                "production_planning_package_documents", "production_material_demands");
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
        return WarehouseOutboundTaskCenterSql.build(new Filter("ALL", status, null, billNo, null, null, null, 1, 20, "billNo", "asc",
                WarehouseTaskCenterContracts.TaskView.ALL),
                new WarehouseOutboundTaskCenterSql.Access(true, true, true, true, true, new OwnerScope(false, Set.of(ACTOR))), scope, ACTOR.toString());
    }

    @Test void typedHeadersKeepOwnerAndWarehouseScopeAndUseExactPhysicalNumbersBeforeAllPagesAndFacets() {
        UUID warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        int index=0;
        for(UUID id:List.of(first,second,UUID.randomUUID(),UUID.randomUUID())) {
            index++;
            execute("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,maker_id,status,issue_status,is_closed,is_deleted,source_doc_no)"
                    +" VALUES(:id,'OTHER_OUT',:bill,'2026-10-28',:warehouse,:owner,0,0,FALSE,FALSE,'SOURCE%_A')",
                    "id",id,"bill","HEADER-"+index,"warehouse",index==3?outside:warehouse,"owner",index==4?UUID.randomUUID():ACTOR);
            execute("INSERT INTO stock_document_items(id,doc_id,line_no,goods_name_snapshot,goods_code_snapshot,qty,is_deleted)"
                    +" VALUES(:id,:document,1,:name,'CODE%_A',CAST(:quantity AS numeric),FALSE)",
                    "id",UUID.randomUUID(),"document",id,"name",index==2?"物料%_扩展":"物料%_",
                    "quantity",index==1?"99999999999999.0001":"99999999999999.0002");
        }
        var filter=new Filter("OTHER",null,"物料%_",null,null,null,warehouse,1,1,"quantity","desc",TaskView.ACTIVE)
                .withColumnSearch(Map.of("goodsName","物料%_","goodsCode","CODE%_A","sourceDocNo","SOURCE%_A",
                        "quantity",">99999999999999","businessDate","2026-10-01..2026-10-28"));
        assertThat(WarehouseOutboundTaskCenterQueryService.normalize(filter).columnSearch()).isEqualTo(filter.columnSearch());
        var plan=WarehouseOutboundTaskCenterSql.build(filter,
                new WarehouseOutboundTaskCenterSql.Access(false,false,false,true,false,new OwnerScope(false,Set.of(ACTOR))),
                new WarehouseTaskScope(true,List.of(warehouse),false),"");
        assertThat(jdbc.queryForObject(plan.countSql(),parameters(plan),Long.class)).isEqualTo(2);
        var one=jdbc.queryForList(plan.rowsSql(),parameters(plan).addValue("limit",1).addValue("offset",0L));
        var two=jdbc.queryForList(plan.rowsSql(),parameters(plan).addValue("limit",1).addValue("offset",1L));
        assertThat(one.getFirst().get("id")).isEqualTo(second);
        assertThat(two.getFirst().get("id")).isEqualTo(first);
        assertThat(jdbc.queryForList(plan.facetsSql(),parameters(plan)).getFirst().get("count")).isEqualTo(2L);
        assertThat(jdbc.queryForList(plan.billNoFacetsSql(),parameters(plan))).hasSize(2);
        var ownDrafts=WarehouseOutboundTaskCenterSql.build(filter,
                new WarehouseOutboundTaskCenterSql.Access(false,false,false,true,false,new OwnerScope(false,Set.of(ACTOR))),
                new WarehouseTaskScope(true,List.of(warehouse),false),ACTOR.toString());
        assertThat(jdbc.queryForObject(ownDrafts.countSql(),parameters(ownDrafts),Long.class)).isEqualTo(3);
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
                .isInstanceOf(IllegalArgumentException.class).hasMessage("Fixture values must contain complete key/value pairs");
    }

    /** 生产工单列（2026-10-29 用户批注）：领料单按三条权威链路聚合工单号，非领料行为空。 */
    @Test void productionOrderNoAggregatesSegmentCodesAcrossAllAuthoritativeLinks() throws Exception {
        UUID warehouse = UUID.randomUUID(), document = UUID.randomUUID(), item = UUID.randomUUID();
        UUID packageSegment = UUID.randomUUID(), itemSegment = UUID.randomUUID(), plainSegment = UUID.randomUUID();
        UUID packagePlan = UUID.randomUUID(), itemPlan = UUID.randomUUID();
        execute("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,maker_id,status,issue_status,is_closed,is_deleted)"
                        + " VALUES(:id,'DRAW','LL-1','2026-10-28',:warehouse,:owner,-1,0,FALSE,FALSE)",
                "id", document, "warehouse", warehouse, "owner", ACTOR);
        execute("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,maker_id,status,issue_status,is_closed,is_deleted)"
                        + " VALUES(:id,'OTHER_OUT','OTHER-1','2026-10-28',:warehouse,:owner,-1,0,FALSE,FALSE)",
                "id", UUID.randomUUID(), "warehouse", warehouse, "owner", ACTOR);
        execute("INSERT INTO stock_document_items(id,doc_id,line_no,qty,is_deleted,execution_segment_id)"
                + " VALUES(:id,:document,1,2,FALSE,:segment)",
                "id", item, "document", document, "segment", itemSegment);
        execute("INSERT INTO production_execution_segments(id,plan_id,segment_code,status,is_deleted)"
                + " VALUES(:id,:plan,:code,'READY',FALSE)",
                "id", packageSegment, "plan", packagePlan, "code", "GD-" + packageSegment.toString().substring(0, 4));
        execute("INSERT INTO production_execution_segments(id,plan_id,segment_code,status,is_deleted)"
                + " VALUES(:id,:plan,:code,'READY',FALSE)",
                "id", itemSegment, "plan", itemPlan, "code", "GD-" + itemSegment.toString().substring(0, 4));
        execute("INSERT INTO production_execution_segments(id,segment_code,status,is_deleted)"
                + " VALUES(:id,:code,'READY',FALSE)",
                "id", plainSegment, "code", "GD-" + plainSegment.toString().substring(0, 4));
        // 计划包单据链路（文档级）与计划包明细-需求链路（行级）都指向同一工单时应去重；
        // 红冲领料单可见性走 provenance 分支（production_planning_package_document_items）。
        execute("INSERT INTO production_planning_package_documents(id,document_type,document_id,execution_segment_id)"
                + " VALUES(:id,'DRAW',:document,:segment)", "id", UUID.randomUUID(), "document", document, "segment", packageSegment);
        execute("INSERT INTO production_planning_package_document_items(id,document_type,document_id,document_item_id,demand_id)"
                + " VALUES(:id,'DRAW',:document,:item,:demand)", "id", UUID.randomUUID(), "document", document,
                "item", item, "demand", UUID.randomUUID());

        var filter = new Filter("DRAW", null, null, null, null, null, null, 1, 20, null, null, TaskView.ALL);
        var plan = WarehouseOutboundTaskCenterSql.build(filter,
                new WarehouseOutboundTaskCenterSql.Access(true, true, true, true, true, new OwnerScope(false, Set.of(ACTOR))),
                WarehouseTaskScope.ALL, ACTOR.toString());
        var rows = jdbc.queryForList(plan.rowsSql(), parameters(plan).addValue("limit", 20).addValue("offset", 0L));
        assertThat(rows).hasSize(1);
        assertThat(rows.getFirst().get("bill_no")).isEqualTo("LL-1");
        // string_agg 按工单号字典序聚合去重（两条链路指向的两个工单都出现）。
        var expectedCodes = java.util.stream.Stream.of(
                        "GD-" + packageSegment.toString().substring(0, 4),
                        "GD-" + itemSegment.toString().substring(0, 4))
                .sorted().toList();
        assertThat((String) rows.getFirst().get("production_order_no"))
                .isEqualTo(String.join("、", expectedCodes));
        // 逐单 {code,planId} 载荷同源聚合（弹窗按单跳生产计划详情的通道）。
        var ordersJson = new ObjectMapper().readTree((String) rows.getFirst().get("production_orders"));
        assertThat(ordersJson.size()).isEqualTo(2);
        for (var order : ordersJson) {
            if (order.get("code").asText().equals(expectedCodes.getFirst())) {
                assertThat(order.get("planId").asText()).isEqualTo(
                        expectedCodes.getFirst().endsWith(packageSegment.toString().substring(0, 4))
                                ? packagePlan.toString() : itemPlan.toString());
            }
        }

        // 按生产工单排序走外层 LATERAL 投影列（列搜索不开放该列：值不在 source_rows CTE）。
        var sorted = WarehouseOutboundTaskCenterSql.build(
                new Filter("DRAW", null, null, null, null, null, null, 1, 20, "productionOrderNo", "desc", TaskView.ALL),
                new WarehouseOutboundTaskCenterSql.Access(true, true, true, true, true, new OwnerScope(false, Set.of(ACTOR))),
                WarehouseTaskScope.ALL, ACTOR.toString());
        assertThat(jdbc.queryForList(sorted.rowsSql(), parameters(sorted).addValue("limit", 20).addValue("offset", 0L))).hasSize(1);

        // 非领料行（其它出库）在生产工单列上保持为空，不影响可见性。
        var other = WarehouseOutboundTaskCenterSql.build(
                new Filter("OTHER", null, null, null, null, null, null, 1, 20, null, null, TaskView.ALL),
                new WarehouseOutboundTaskCenterSql.Access(true, true, true, true, true, new OwnerScope(false, Set.of(ACTOR))),
                WarehouseTaskScope.ALL, ACTOR.toString());
        var otherRows = jdbc.queryForList(other.rowsSql(), parameters(other).addValue("limit", 20).addValue("offset", 0L));
        assertThat(otherRows).hasSize(1);
        assertThat(otherRows.getFirst().get("production_order_no")).isNull();
    }

    private void execute(String sql, Object... parameters) {
        var values = new MapSqlParameterSource(com.uten.imp.support.KeyValueTestData.map(parameters));
        jdbc.update(sql, values);
    }
}
