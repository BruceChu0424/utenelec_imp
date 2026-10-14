package com.uten.imp.features.warehouse.taskcenter;

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
import java.util.LinkedHashMap;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import static org.assertj.core.api.Assertions.assertThat;

/** Migrated catalog projections execute the real quantity, provenance and warehouse-scope functions. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseOutboundTaskCenterSqlPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private static NamedParameterJdbcTemplate jdbc;
    private static Map<String, String> authoritativeFunctions;
    private static final List<String> FUNCTION_SIGNATURES = List.of(
            "public.fn_production_draw_requested(uuid)", "public.fn_production_draw_pending(uuid)",
            "public.fn_production_draw_item_requested_qty(uuid)", "public.fn_is_production_linked_stock_document(uuid)",
            "public.fn_stock_document_matches_warehouse_scope(uuid,text,boolean,text)");
    private static final String[] TABLES = {
            "warehouses", "clients", "suppliers", "employees", "departments", "goods", "units",
            "sales_shipments", "sales_shipment_items", "subcontract_material_issues", "subcontract_material_issue_items",
            "subcontract_material_plan_items", "subcontract_material_plans", "stock_documents", "stock_document_items",
            "production_material_discovery_requests", "production_material_discovery_lines",
            "production_planning_packages", "production_planning_package_documents", "production_planning_package_document_items",
            "production_execution_segments", "production_execution_segment_events", "production_plans",
            "production_material_stock_postings", "plan_draw_links", "production_material_demands"};
    private static final UUID ACTOR = UUID.randomUUID();
    private static final UUID OTHER = UUID.randomUUID();
    private static final UUID WAREHOUSE_A = UUID.randomUUID();
    private static final UUID WAREHOUSE_B = UUID.randomUUID();
    private static final UUID GOODS = UUID.randomUUID();
    private static final UUID UNIT = UUID.randomUUID();

    @BeforeAll static void baseline() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("outbound_physical_facts");
        try (var connection = database.openConnection()) {
            jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            authoritativeFunctions = functionDefinitions();
        }
    }

    @BeforeEach void projection() throws Exception {
        connection = database.openConnection();
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE SCHEMA outbound_physical_oracle");
            statement.execute("SET LOCAL search_path=outbound_physical_oracle,public");
        }
        // Query-only rollback projections keep every real column. No authority function is replaced;
        // request visibility comes from the original document/segment/event/item facts below.
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection, TABLES);
        jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
        jdbc.update("INSERT INTO warehouses(id,name,is_line_side,is_deleted) VALUES(:a,'A仓',FALSE,FALSE),(:b,'B仓',FALSE,FALSE)",
                Map.of("a", WAREHOUSE_A, "b", WAREHOUSE_B));
        jdbc.update("INSERT INTO employees(id,full_name,is_deleted) VALUES(:a,'本人员工',FALSE),(:b,'其他员工',FALSE)",
                Map.of("a", ACTOR, "b", OTHER));
        jdbc.update("INSERT INTO units(id,code,name,is_deleted) VALUES(:id,'QUERY-UNIT','kg',FALSE)", Map.of("id", UNIT));
        jdbc.update("INSERT INTO goods(id,code,name,unit_id,is_deleted) VALUES(:id,'QUERY-MATERIAL','真实字段物料',:unit,FALSE)",
                Map.of("id", GOODS, "unit", UNIT));
    }

    @AfterEach void rollback() throws Exception {
        if (connection != null) { connection.rollback(); connection.close(); }
    }
    @AfterAll static void closeBaseline() throws Exception { if (database != null) database.close(); }

    @Test
    void globalSortAndPagesKeepSameNumbersAndSameUuidsFromDifferentSources() {
        UUID shared = UUID.randomUUID();
        sale(shared, "SAME", WAREHOUSE_A);
        stock(shared, "OTHER_OUT", "SAME", ACTOR, WAREHOUSE_A, 0, 0);
        sale(UUID.randomUUID(), "B-SALES", WAREHOUSE_A);
        stock(UUID.randomUUID(), "OTHER_OUT", "A-OTHER", ACTOR, WAREHOUSE_A, 1, 0);
        subcontract(UUID.randomUUID(), "C-SC", WAREHOUSE_A, 1, false, false);
        stock(UUID.randomUUID(), "WDRAW", "SHOULD-BE-INBOUND", ACTOR, WAREHOUSE_A, 0, 0);
        var plan = plan("ALL", null, null, "billNo", "asc", full(), WarehouseTaskScope.ALL, "");
        assertThat(count(plan)).isEqualTo(5);
        var pageTwo = rows(plan, 2, 2);
        assertThat(pageTwo).extracting(row -> row.get("bill_no")).containsExactly("C-SC", "SAME");
        assertThat(pageTwo.get(1).get("source_type")).isEqualTo("OTHER");
        assertThat(rows(plan, 3, 2).getFirst().get("source_type")).isEqualTo("SALES");
        assertThat(rows(plan, 3, 2).getFirst().get("id")).isEqualTo(shared);
        var same = plan("ALL", null, "SAME", null, null, full(), WarehouseTaskScope.ALL, "");
        assertThat(count(same)).isEqualTo(2);
        assertThat(jdbc.queryForList(same.billNoFacetsSql(), parameters(same))).hasSize(4);
    }

    @Test
    void scopeAndOwnerPredicatesApplyToCountRowsAndFacetsAcrossSources() {
        UUID insideByLine = UUID.randomUUID();
        sale(insideByLine, "LINE-IN-SCOPE", WAREHOUSE_B);
        jdbc.update("INSERT INTO sales_shipment_items(id,shipment_id,warehouse_id,goods_code_snapshot,goods_name_snapshot,is_deleted) VALUES(:id,:doc,:warehouse,'A','A物料',false)",
                Map.of("id", UUID.randomUUID(), "doc", insideByLine, "warehouse", WAREHOUSE_A));
        sale(UUID.randomUUID(), "OUT-OF-SCOPE", WAREHOUSE_B);
        stock(UUID.randomUUID(), "OTHER_OUT", "MY-A", ACTOR, WAREHOUSE_A, 0, 0);
        stock(UUID.randomUUID(), "OTHER_OUT", "OTHER-A", OTHER, WAREHOUSE_A, 0, 0);
        stock(UUID.randomUUID(), "OTHER_OUT", "MY-B", ACTOR, WAREHOUSE_B, 0, 0);
        var access = new WarehouseOutboundTaskCenterSql.Access(true, false, false, true, false, new OwnerScope(false, Set.of(ACTOR)));
        var scope = new WarehouseTaskScope(true, List.of(WAREHOUSE_A), false);
        var selected = plan("ALL", null, null, null, null, access, scope, "");
        assertThat(count(selected)).isEqualTo(2);
        assertThat(rows(selected, 1, 20)).extracting(row -> row.get("bill_no")).containsExactlyInAnyOrder("LINE-IN-SCOPE", "MY-A");
        assertThat(jdbc.queryForList(selected.billNoFacetsSql(), parameters(selected))).extracting(row -> row.get("bill_no"))
                .containsExactlyInAnyOrder("LINE-IN-SCOPE", "MY-A");
        var ownDrafts = plan("OTHER", null, null, null, null, access, scope, ACTOR.toString());
        assertThat(count(ownDrafts)).isEqualTo(2);
    }

    @Test
    void drawUsesOneDocumentIdentityAndConfiguredDiscoveryDoesNotDuplicateIt() {
        UUID draw = UUID.randomUUID();
        UUID drawItem = stock(draw, "DRAW", "DRAW-1", OTHER, WAREHOUSE_A, 1, 1);
        UUID request = discovery("CONFIGURED");
        UUID demand = UUID.randomUUID();
        executionDraw(draw, drawItem, request, demand, true);
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_requested(:id)", Map.of("id", draw), Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_pending(:id)", Map.of("id", draw), Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_item_requested_qty(:id)", Map.of("id", drawItem), java.math.BigDecimal.class))
                .isEqualByComparingTo("2");
        discovery("PENDING");
        UUID ownedManual = UUID.randomUUID();
        stock(ownedManual, "DRAW", "MY-MANUAL-DRAW", ACTOR, WAREHOUSE_A, 0, 0);
        stock(UUID.randomUUID(), "DRAW", "OTHER-MANUAL-DRAW", OTHER, WAREHOUSE_A, 0, 0);
        var productionRole = new WarehouseOutboundTaskCenterSql.Access(false, false, false, true, true, new OwnerScope(false, Set.of(ACTOR)));
        var plan = plan("DRAW", null, null, null, null, productionRole, WarehouseTaskScope.ALL, "");
        assertThat(count(plan)).isEqualTo(3);
        assertThat(rows(plan, 1, 20)).extracting(row -> row.get("status"))
                .containsExactlyInAnyOrder("DRAW_PARTIAL", "DRAW_DISCOVERY_PENDING", "DRAW_PENDING");
        assertThat(rows(plan, 1, 20).stream().filter(row -> row.get("id").equals(draw)).findFirst().orElseThrow()
                .get("request_id")).isEqualTo(request);
        assertThat(rows(plan, 1, 20).stream().filter(row -> row.get("id").equals(ownedManual)).findFirst().orElseThrow()
                .get("actionable")).isEqualTo(false);
        var ordinaryOwner = new WarehouseOutboundTaskCenterSql.Access(false, false, false, true, false, new OwnerScope(false, Set.of(ACTOR)));
        var own = plan("DRAW", null, null, null, null, ordinaryOwner, WarehouseTaskScope.ALL, "");
        assertThat(count(own)).isEqualTo(1);
        assertThat(rows(own, 1, 20).getFirst().get("id")).isEqualTo(ownedManual);
    }

    @Test
    void workshopCustodyDrawsStayOutOfEveryTaskProjectionWhileTheirDocumentsRemainIntact() {
        // Warehouse names do not establish custody: the explicit business flag does.
        jdbc.update("UPDATE warehouses SET name='同名仓',is_line_side=(id=:lineSide)", Map.of("lineSide", WAREHOUSE_A));
        UUID pending = UUID.randomUUID(), partial = UUID.randomUUID(), issued = UUID.randomUUID(), reversed = UUID.randomUUID();
        stock(pending, "DRAW", "INTERNAL-PENDING", ACTOR, WAREHOUSE_A, 1, 0);
        stock(partial, "DRAW", "INTERNAL-PARTIAL", ACTOR, WAREHOUSE_A, 1, 1);
        UUID issuedItem = stock(issued, "DRAW", "INTERNAL-ISSUED", OTHER, WAREHOUSE_A, 1, 2);
        UUID reversedItem = stock(reversed, "DRAW", "INTERNAL-REVERSED", ACTOR, WAREHOUSE_A, -1, 2);
        // Include real execution provenance, so neither a requested DRAW nor retained reversal
        // can re-enter through production access or the historical provenance exception.
        executionDraw(issued, issuedItem, discovery("CONFIGURED"), UUID.randomUUID(), true);
        executionDraw(reversed, reversedItem, discovery("CONFIGURED"), UUID.randomUUID(), true);
        stock(UUID.randomUUID(), "DRAW", "ORDINARY-PENDING", ACTOR, WAREHOUSE_B, 1, 0);
        stock(UUID.randomUUID(), "DRAW", "ORDINARY-ISSUED", OTHER, WAREHOUSE_B, 1, 2);
        stock(UUID.randomUUID(), "OTHER_OUT", "OTHER-INTERNAL-LOCATION", ACTOR, WAREHOUSE_A, 1, 0);

        assertThat(jdbc.queryForObject("SELECT fn_production_draw_requested(:id)", Map.of("id", issued), Boolean.class)).isTrue();
        var draw = plan("DRAW", null, null, null, null, full(), WarehouseTaskScope.ALL, "");
        assertThat(count(draw)).isEqualTo(2);
        assertThat(rows(draw, 1, 20)).extracting(row -> row.get("bill_no"))
                .containsExactlyInAnyOrder("ORDINARY-PENDING", "ORDINARY-ISSUED");
        assertThat(jdbc.queryForList(draw.facetsSql(), parameters(draw))).extracting(row -> row.get("status"))
                .containsExactlyInAnyOrder("DRAW_PENDING", "DRAW_SHIPPED");
        assertThat(jdbc.queryForList(draw.billNoFacetsSql(), parameters(draw))).extracting(row -> row.get("bill_no"))
                .containsExactlyInAnyOrder("ORDINARY-PENDING", "ORDINARY-ISSUED");
        assertThat(count(plan("DRAW", "DRAW_REVERSED", "INTERNAL-REVERSED", null, null, full(), WarehouseTaskScope.ALL, ""))).isZero();
        assertThat(count(plan("DRAW", null, null, null, null, full(),
                new WarehouseTaskScope(true, List.of(WAREHOUSE_A), false), ""))).isZero();
        assertThat(count(plan("ALL", null, null, null, null, full(), WarehouseTaskScope.ALL, ""))).isEqualTo(3);
        assertThat(count(plan("DRAW", null, null, null, null,
                new WarehouseOutboundTaskCenterSql.Access(false, false, false, true, false, new OwnerScope(false, Set.of(ACTOR))),
                WarehouseTaskScope.ALL, ""))).isEqualTo(1);

        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM stock_documents WHERE id IN (:ids)",
                Map.of("ids", List.of(pending, partial, issued, reversed)), Long.class)).isEqualTo(4);
        assertThat(jdbc.queryForObject("SELECT SUM(issued_qty) FROM stock_document_items WHERE doc_id IN (:ids)",
                Map.of("ids", List.of(pending, partial, issued, reversed)), java.math.BigDecimal.class)).isEqualByComparingTo("5");
        assertThat(functionDefinitions()).isEqualTo(authoritativeFunctions);
    }

    @Test
    void taskOnlySubcontractGrantCannotReadTerminalOrWithdrawnHistory() {
        subcontract(UUID.randomUUID(), "PENDING", WAREHOUSE_A, 0, false, true);
        subcontract(UUID.randomUUID(), "SHIPPED", WAREHOUSE_A, 1, false, true);
        subcontract(UUID.randomUUID(), "WITHDRAWN", WAREHOUSE_A, 0, true, true);
        var taskOnly = new WarehouseOutboundTaskCenterSql.Access(false, true, false, false, false, new OwnerScope(false, Set.of()));
        var pending = plan("SUBCONTRACT", null, null, null, null, taskOnly, WarehouseTaskScope.ALL, "");
        assertThat(count(pending)).isEqualTo(1);
        assertThat(rows(pending, 1, 20).getFirst().get("status")).isEqualTo("SUBCONTRACT_PENDING");
        var all = plan("SUBCONTRACT", null, null, null, null, full(), WarehouseTaskScope.ALL, "");
        assertThat(count(all)).isEqualTo(3);
        var withdrawn = plan("SUBCONTRACT", "SUBCONTRACT_WITHDRAWN", null, null, null, full(), WarehouseTaskScope.ALL, "");
        assertThat(count(withdrawn)).isEqualTo(1);
        assertThat(rows(withdrawn, 1, 20).getFirst().get("actionable")).isEqualTo(false);
        assertThat(jdbc.queryForList(withdrawn.facetsSql(), parameters(withdrawn))).hasSize(3);
    }

    private static WarehouseOutboundTaskCenterSql.Access full() {
        return new WarehouseOutboundTaskCenterSql.Access(true, true, true, true, true, new OwnerScope(true, Set.of()));
    }
    private static WarehouseOutboundTaskCenterSql.Plan plan(String source, String status, String billNo, String sort, String order,
            WarehouseOutboundTaskCenterSql.Access access, WarehouseTaskScope scope, String own) {
        return WarehouseOutboundTaskCenterSql.build(new Filter(source, status, null, billNo, null, null, null, 1, 20, sort, order), access, scope, own);
    }
    private static MapSqlParameterSource parameters(WarehouseOutboundTaskCenterSql.Plan plan) {
        return new MapSqlParameterSource(plan.parameters());
    }
    private static long count(WarehouseOutboundTaskCenterSql.Plan plan) {
        return jdbc.queryForObject(plan.countSql(), parameters(plan), Long.class);
    }
    private static List<Map<String,Object>> rows(WarehouseOutboundTaskCenterSql.Plan plan, int page, int size) {
        return jdbc.queryForList(plan.rowsSql(), parameters(plan).addValue("limit", size).addValue("offset", (long)(page-1)*size));
    }
    private static void sale(UUID id, String bill, UUID warehouse) {
        jdbc.update("""
                INSERT INTO sales_shipments(id,bill_no,bill_date,warehouse_id,owner_employee_id,finance_audit,status,rejected,
                    warehouse_work_status,review_revision,is_deleted)
                VALUES(:id,:bill,'2026-10-01',:warehouse,:owner,1,0,false,'PENDING_PICK',7,false)
                """, Map.of("id", id, "bill", bill, "warehouse", warehouse, "owner", ACTOR));
    }
    private static UUID stock(UUID id, String type, String bill, UUID owner, UUID warehouse, int status, int issued) {
        jdbc.update("""
                INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,maker_id,status,issue_status,is_closed,is_deleted)
                VALUES(:id,:type,:bill,'2026-10-01',:warehouse,:owner,:status,:issued,FALSE,FALSE)
                """, Map.of("id", id, "type", type, "bill", bill, "warehouse", warehouse, "owner", owner,
                "status", status, "issued", issued));
        UUID item = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO stock_document_items(id,doc_id,line_no,goods_id,goods_code_snapshot,goods_name_snapshot,
                    unit_id,unit_rate,qty,issued_qty,is_deleted)
                VALUES(:id,:doc,1,:goods,'QUERY-MATERIAL','真实字段物料',:unit,1,2,:issued,FALSE)
                """, Map.of("id", item, "doc", id, "goods", GOODS, "unit", UNIT, "issued", issued == 2 ? 2 : issued == 1 ? 1 : 0));
        return item;
    }
    private static void subcontract(UUID id, String bill, UUID warehouse, int status, boolean deleted, boolean linked) {
        jdbc.update("""
                INSERT INTO subcontract_material_issues(id,bill_no,bill_date,warehouse_id,status,is_deleted,is_closed)
                VALUES(:id,:bill,'2026-10-01',:warehouse,:status,:deleted,FALSE)
                """, Map.of("id", id, "bill", bill, "warehouse", warehouse, "status", status, "deleted", deleted));
        if (linked) {
            UUID plan = UUID.randomUUID(), line = UUID.randomUUID();
            jdbc.update("INSERT INTO subcontract_material_plans(id,order_bill_no) VALUES(:id,'ORDER-1')", Map.of("id", plan));
            jdbc.update("INSERT INTO subcontract_material_plan_items(id,plan_id) VALUES(:id,:plan)", Map.of("id", line, "plan", plan));
            jdbc.update("INSERT INTO subcontract_material_issue_items(id,issue_id,plan_item_id,goods_code_snapshot,goods_name_snapshot,is_deleted) VALUES(:id,:issue,:line,'M','物料',:deleted)",
                    Map.of("id", UUID.randomUUID(), "issue", id, "line", line, "deleted", deleted));
        }
    }
    private static UUID discovery(String status) {
        UUID plan = UUID.randomUUID(), pack = UUID.randomUUID(), segment = UUID.randomUUID(), request = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_plans(id,bill_no,status,is_deleted,is_closed,is_canceled,is_stopped)
                VALUES(:id,'PLAN-1',1,FALSE,FALSE,FALSE,FALSE)
                """, Map.of("id", plan));
        jdbc.update("""
                INSERT INTO production_planning_packages(id,plan_id,warehouse_id,status,is_deleted,idempotency_key,
                    request_hash,preview_fingerprint,lock_version)
                VALUES(:id,:plan,:warehouse,'CONFIRMED',FALSE,:key,:hash,:hash,0)
                """, Map.of("id", pack, "plan", plan, "warehouse", WAREHOUSE_A,
                "key", "warehouse-query-" + pack, "hash", "1".repeat(64)));
        jdbc.update("""
                INSERT INTO production_execution_segments(id,plan_id,package_id,is_deleted,status,lock_version,material_requirement_mode)
                VALUES(:id,:plan,:package,FALSE,'READY',1,'DEMANDED')
                """, Map.of("id", segment, "plan", plan, "package", pack));
        jdbc.update("""
                INSERT INTO production_material_discovery_requests(id,request_no,execution_segment_id,created_at,
                    requested_materials,status,row_version)
                VALUES(:id,:number,:segment,'2026-10-01 00:00:00+00','[{"goodsName":"待填写","qty":2}]'::jsonb,:status,1)
                """, Map.of("id", request, "number", "MD-" + request, "segment", segment, "status", status));
        return request;
    }

    private static void executionDraw(UUID document, UUID item, UUID request, UUID demand, boolean requested) {
        UUID segment = jdbc.queryForObject("SELECT execution_segment_id FROM production_material_discovery_requests WHERE id=:id",
                Map.of("id", request), UUID.class);
        UUID pack = jdbc.queryForObject("SELECT package_id FROM production_execution_segments WHERE id=:id",
                Map.of("id", segment), UUID.class);
        jdbc.update("""
                INSERT INTO production_material_demands(id,package_id,plan_id,execution_segment_id,warehouse_id,
                    goods_id,unit_id,required_qty,released_qty,supply_route,status,is_deleted,idempotency_key,lock_version)
                SELECT :id,:package,plan_id,:segment,:warehouse,:goods,:unit,2,0,'BUY','ALLOCATED',FALSE,:key,0
                FROM production_execution_segments WHERE id=:segment
                """, Map.of("id", demand, "package", pack, "segment", segment, "warehouse", WAREHOUSE_A,
                "goods", GOODS, "unit", UNIT, "key", "warehouse-query-demand-" + demand));
        jdbc.update("""
                INSERT INTO production_material_discovery_lines(id,request_id,demand_id,warehouse_id,goods_id,unit_id,qty,created_by)
                VALUES(:id,:request,:demand,:warehouse,:goods,:unit,2,:actor)
                """, Map.of("id", UUID.randomUUID(), "request", request, "demand", demand, "warehouse", WAREHOUSE_A,
                "goods", GOODS, "unit", UNIT, "actor", ACTOR));
        jdbc.update("""
                INSERT INTO production_planning_package_documents(id,package_id,document_type,document_id,execution_segment_id)
                VALUES(:id,:package,'DRAW',:doc,:segment)
                """, Map.of("id", UUID.randomUUID(), "package", pack, "doc", document, "segment", segment));
        jdbc.update("""
                INSERT INTO production_planning_package_document_items(id,package_id,demand_id,document_type,document_id,document_item_id)
                VALUES(:id,:package,:demand,'DRAW',:doc,:item)
                """, Map.of("id", UUID.randomUUID(), "package", pack, "demand", demand, "doc", document, "item", item));
        if (requested) {
            jdbc.update("""
                    INSERT INTO production_execution_segment_events(id,execution_segment_id,action,expected_version,resulting_version,
                        draw_document_ids,draw_item_quantities,created_by,created_at)
                    VALUES(:id,:segment,'DRAW_REQUEST',0,1,ARRAY[CAST(:doc AS uuid)],
                        jsonb_build_object(CAST(:item AS text),2),:actor,now())
                    """, Map.of("id", UUID.randomUUID(), "segment", segment, "doc", document, "item", item, "actor", ACTOR));
        }
    }

    @Test void aLinkedExecutionDrawNeedsItsRealRequestAndRemainingPhysicalQuantity() {
        UUID document = UUID.randomUUID();
        UUID item = stock(document, "DRAW", "REQUEST-GATE", OTHER, WAREHOUSE_A, 1, 0);
        UUID request = discovery("CONFIGURED");
        executionDraw(document, item, request, UUID.randomUUID(), false);
        var access = new WarehouseOutboundTaskCenterSql.Access(false, false, false, true, true, new OwnerScope(false, Set.of(ACTOR)));
        var plan = plan("DRAW", null, null, null, null, access, WarehouseTaskScope.ALL, "");
        assertThat(jdbc.queryForObject("SELECT fn_is_production_linked_stock_document(:id)", Map.of("id", document), Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_requested(:id)", Map.of("id", document), Boolean.class)).isFalse();
        // The unrequested execution DRAW stays hidden; its configured discovery remains readable history.
        assertThat(count(plan)).isEqualTo(1);
        assertThat(rows(plan, 1, 20)).extracting(row -> row.get("record_type"))
                .containsExactly("MATERIAL_DISCOVERY");
        assertThat(rows(plan, 1, 20).getFirst().get("id")).isEqualTo(request);
        assertThat(rows(plan, 1, 20).getFirst().get("actionable")).isEqualTo(false);
        jdbc.update("""
                INSERT INTO production_execution_segment_events(id,execution_segment_id,action,expected_version,resulting_version,
                    draw_document_ids,draw_item_quantities,created_by,created_at)
                SELECT :id,execution_segment_id,'DRAW_REQUEST',0,1,ARRAY[CAST(:doc AS uuid)],
                    jsonb_build_object(CAST(:item AS text),2),:actor,now()
                FROM production_material_discovery_requests WHERE id=:request
                """, Map.of("id", UUID.randomUUID(), "doc", document, "item", item, "actor", ACTOR, "request", request));
        assertThat(count(plan)).isEqualTo(1);
        assertThat(rows(plan, 1, 20).getFirst().get("actionable")).isEqualTo(true);
        jdbc.update("UPDATE warehouses SET is_line_side=TRUE WHERE id=:id", Map.of("id", WAREHOUSE_A));
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_pending(:id)", Map.of("id", document), Boolean.class)).isFalse();
        assertThat(count(plan)).isZero();
        assertThat(rows(plan, 1, 20)).isEmpty();
        jdbc.update("UPDATE warehouses SET is_line_side=FALSE WHERE id=:id", Map.of("id", WAREHOUSE_A));
        jdbc.update("UPDATE stock_document_items SET issued_qty=qty WHERE id=:id", Map.of("id", item));
        jdbc.update("UPDATE stock_documents SET issue_status=2 WHERE id=:id", Map.of("id", document));
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_pending(:id)", Map.of("id", document), Boolean.class)).isFalse();
        assertThat(rows(plan, 1, 20).getFirst().get("status")).isEqualTo("DRAW_SHIPPED");
        assertThat(rows(plan, 1, 20).getFirst().get("actionable")).isEqualTo(false);
    }

    @Test void projectionsKeepCanonicalColumnsAndEveryAuthorityFunctionUnchanged() {
        for (String table : TABLES) {
            String sql = "SELECT column_name,udt_name,numeric_precision,numeric_scale FROM information_schema.columns"
                    + " WHERE table_schema=:schema AND table_name=:table ORDER BY ordinal_position";
            var live = jdbc.queryForList(sql, Map.of("schema", "public", "table", table));
            var copied = jdbc.queryForList(sql, Map.of("schema", "outbound_physical_oracle", "table", table));
            assertThat(copied).as(table).isEqualTo(live).isNotEmpty();
        }
        assertThat(functionDefinitions()).isEqualTo(authoritativeFunctions);
    }

    private static Map<String, String> functionDefinitions() {
        Map<String, String> definitions = new LinkedHashMap<>();
        for (String signature : FUNCTION_SIGNATURES) {
            definitions.put(signature, jdbc.queryForObject("SELECT pg_get_functiondef(CAST(:signature AS regprocedure))",
                    Map.of("signature", signature), String.class));
        }
        return definitions;
    }
}
