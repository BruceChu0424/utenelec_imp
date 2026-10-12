package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import static org.assertj.core.api.Assertions.assertThat;

/** Executes the real union/query builder against PostgreSQL, with isolated physical facts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseOutboundTaskCenterSqlPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("outbound_physical_facts").withUsername("uten").withPassword("uten-test-only");
    private static NamedParameterJdbcTemplate jdbc;
    private static final UUID ACTOR = UUID.randomUUID();
    private static final UUID OTHER = UUID.randomUUID();
    private static final UUID WAREHOUSE_A = UUID.randomUUID();
    private static final UUID WAREHOUSE_B = UUID.randomUUID();

    @BeforeAll
    static void start() {
        POSTGRES.start();
        jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        // This fixture isolates read-model paging and access composition; original command
        // tests own the production-request and warehouse-scope functions' business rules.
        jdbc.getJdbcTemplate().execute("""
                CREATE TABLE warehouses(id uuid PRIMARY KEY,name text);
                CREATE TABLE clients(id uuid PRIMARY KEY,name text);
                CREATE TABLE suppliers(id uuid PRIMARY KEY,name text);
                CREATE TABLE employees(id uuid PRIMARY KEY,full_name text);
                CREATE TABLE departments(id uuid PRIMARY KEY,name text);
                CREATE TABLE goods(id uuid PRIMARY KEY,code text,name text,stock_place text);
                CREATE TABLE sales_shipments(id uuid PRIMARY KEY,bill_no text,source_doc_no text,bill_date date,
                    client_id uuid,warehouse_id uuid,sender_id uuid,maker_id uuid,owner_employee_id uuid,
                    finance_audit int,status int,rejected boolean,warehouse_work_status text,review_revision bigint,is_deleted boolean);
                CREATE TABLE sales_shipment_items(id uuid PRIMARY KEY,shipment_id uuid,warehouse_id uuid,
                    goods_code_snapshot text,goods_name_snapshot text,is_deleted boolean,goods_id uuid);
                CREATE TABLE subcontract_material_issues(id uuid PRIMARY KEY,bill_no text,source_doc_no text,bill_date date,
                    supplier_id uuid,warehouse_id uuid,maker_id uuid,maker_name text,status int,is_deleted boolean,is_closed boolean DEFAULT false);
                CREATE TABLE subcontract_material_issue_items(id uuid PRIMARY KEY,issue_id uuid,plan_item_id uuid,
                    goods_code_snapshot text,goods_name_snapshot text,is_deleted boolean,goods_id uuid);
                CREATE TABLE subcontract_material_plan_items(id uuid PRIMARY KEY,plan_id uuid);
                CREATE TABLE subcontract_material_plans(id uuid PRIMARY KEY,order_bill_no text);
                CREATE TABLE stock_documents(id uuid PRIMARY KEY,doc_type text,bill_no text,plan_no text,source_doc_no text,bill_date date,
                    department_id uuid,client_id uuid,supplier_id uuid,warehouse_id uuid,to_warehouse_id uuid,
                    worker_id uuid,maker_id uuid,status int,issue_status int,is_closed boolean,is_deleted boolean,requested boolean);
                CREATE TABLE stock_document_items(id uuid PRIMARY KEY,doc_id uuid,goods_code_snapshot text,goods_name_snapshot text,is_deleted boolean,goods_id uuid);
                CREATE TABLE production_material_discovery_requests(id uuid PRIMARY KEY,request_no text,execution_segment_id uuid,
                    created_at timestamptz,requested_materials jsonb,status text,row_version bigint);
                CREATE TABLE production_material_discovery_lines(id uuid PRIMARY KEY,request_id uuid,demand_id uuid,warehouse_id uuid,goods_id uuid);
                CREATE TABLE production_planning_package_document_items(id uuid PRIMARY KEY,demand_id uuid,document_type text,document_id uuid);
                CREATE TABLE production_execution_segments(id uuid PRIMARY KEY,plan_id uuid,workshop_department_id uuid,
                    responsible_employee_id uuid,is_deleted boolean,status text);
                CREATE TABLE production_plans(id uuid PRIMARY KEY,bill_no text,is_deleted boolean,is_closed boolean,is_canceled boolean,is_stopped boolean);
                CREATE FUNCTION fn_production_draw_requested(document uuid) RETURNS boolean LANGUAGE sql AS $$
                    SELECT COALESCE((SELECT requested FROM stock_documents WHERE id=document),false) $$;
                CREATE FUNCTION fn_is_production_linked_stock_document(document uuid) RETURNS boolean LANGUAGE sql AS $$
                    SELECT EXISTS(SELECT 1 FROM production_planning_package_document_items
                        WHERE document_id=document AND document_type='DRAW') $$;
                CREATE FUNCTION fn_production_draw_pending(document uuid) RETURNS boolean LANGUAGE sql AS $$
                    SELECT COALESCE((SELECT requested AND status IN(0,1) AND issue_status<2 AND NOT is_closed
                        FROM stock_documents WHERE id=document),false) $$;
                CREATE FUNCTION fn_stock_document_matches_warehouse_scope(document uuid,warehouse_scope text,
                    unassigned boolean,own_maker text) RETURNS boolean LANGUAGE sql AS $$
                    SELECT EXISTS(SELECT 1 FROM stock_documents d WHERE d.id=document AND
                       (d.warehouse_id=ANY(CAST(string_to_array(NULLIF(warehouse_scope,''),',') AS uuid[]))
                        OR d.to_warehouse_id=ANY(CAST(string_to_array(NULLIF(warehouse_scope,''),',') AS uuid[]))
                        OR (unassigned AND d.warehouse_id IS NULL AND d.to_warehouse_id IS NULL)
                        OR (own_maker<>'' AND d.status=0 AND d.maker_id::text=own_maker))) $$;
                """);
        jdbc.update("INSERT INTO warehouses VALUES(:a,'A仓'),(:b,'B仓')", Map.of("a", WAREHOUSE_A, "b", WAREHOUSE_B));
        jdbc.update("INSERT INTO employees VALUES(:a,'本人员工'),(:b,'其他员工')", Map.of("a", ACTOR, "b", OTHER));
    }

    @BeforeEach
    void clear() {
        jdbc.getJdbcTemplate().execute("""
                TRUNCATE sales_shipments,sales_shipment_items,subcontract_material_issues,subcontract_material_issue_items,
                    subcontract_material_plan_items,subcontract_material_plans,stock_documents,stock_document_items,
                    production_material_discovery_requests,production_material_discovery_lines,
                    production_planning_package_document_items,production_execution_segments,production_plans
                """);
    }

    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test
    void globalSortAndPagesKeepSameNumbersAndSameUuidsFromDifferentSources() {
        UUID shared = UUID.randomUUID();
        sale(shared, "SAME", WAREHOUSE_A);
        stock(shared, "OTHER_OUT", "SAME", ACTOR, WAREHOUSE_A, 0, 0, false);
        sale(UUID.randomUUID(), "B-SALES", WAREHOUSE_A);
        stock(UUID.randomUUID(), "OTHER_OUT", "A-OTHER", ACTOR, WAREHOUSE_A, 1, 0, false);
        subcontract(UUID.randomUUID(), "C-SC", WAREHOUSE_A, 1, false, false);
        stock(UUID.randomUUID(), "WDRAW", "SHOULD-BE-INBOUND", ACTOR, WAREHOUSE_A, 0, 0, false);
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
        stock(UUID.randomUUID(), "OTHER_OUT", "MY-A", ACTOR, WAREHOUSE_A, 0, 0, false);
        stock(UUID.randomUUID(), "OTHER_OUT", "OTHER-A", OTHER, WAREHOUSE_A, 0, 0, false);
        stock(UUID.randomUUID(), "OTHER_OUT", "MY-B", ACTOR, WAREHOUSE_B, 0, 0, false);
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
        stock(draw, "DRAW", "DRAW-1", OTHER, WAREHOUSE_A, 1, 1, true);
        UUID request = discovery("CONFIGURED");
        UUID demand = UUID.randomUUID();
        jdbc.update("INSERT INTO production_material_discovery_lines VALUES(:id,:request,:demand,:warehouse,NULL)",
                Map.of("id", UUID.randomUUID(), "request", request, "demand", demand, "warehouse", WAREHOUSE_A));
        jdbc.update("INSERT INTO production_planning_package_document_items VALUES(:id,:demand,'DRAW',:doc)",
                Map.of("id", UUID.randomUUID(), "demand", demand, "doc", draw));
        discovery("PENDING");
        UUID ownedManual = UUID.randomUUID();
        stock(ownedManual, "DRAW", "MY-MANUAL-DRAW", ACTOR, WAREHOUSE_A, 0, 0, true);
        stock(UUID.randomUUID(), "DRAW", "OTHER-MANUAL-DRAW", OTHER, WAREHOUSE_A, 0, 0, true);
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
    private static void stock(UUID id, String type, String bill, UUID owner, UUID warehouse, int status, int issued, boolean requested) {
        jdbc.update("""
                INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,maker_id,status,issue_status,is_closed,is_deleted,requested)
                VALUES(:id,:type,:bill,'2026-10-01',:warehouse,:owner,:status,:issued,false,false,:requested)
                """, Map.of("id", id, "type", type, "bill", bill, "warehouse", warehouse, "owner", owner,
                "status", status, "issued", issued, "requested", requested));
    }
    private static void subcontract(UUID id, String bill, UUID warehouse, int status, boolean deleted, boolean linked) {
        jdbc.update("""
                INSERT INTO subcontract_material_issues(id,bill_no,bill_date,warehouse_id,status,is_deleted)
                VALUES(:id,:bill,'2026-10-01',:warehouse,:status,:deleted)
                """, Map.of("id", id, "bill", bill, "warehouse", warehouse, "status", status, "deleted", deleted));
        if (linked) {
            UUID plan = UUID.randomUUID(), line = UUID.randomUUID();
            jdbc.update("INSERT INTO subcontract_material_plans VALUES(:id,'ORDER-1')", Map.of("id", plan));
            jdbc.update("INSERT INTO subcontract_material_plan_items VALUES(:id,:plan)", Map.of("id", line, "plan", plan));
            jdbc.update("INSERT INTO subcontract_material_issue_items(id,issue_id,plan_item_id,goods_code_snapshot,goods_name_snapshot,is_deleted) VALUES(:id,:issue,:line,'M','物料',:deleted)",
                    Map.of("id", UUID.randomUUID(), "issue", id, "line", line, "deleted", deleted));
        }
    }
    private static UUID discovery(String status) {
        UUID plan = UUID.randomUUID(), segment = UUID.randomUUID(), request = UUID.randomUUID();
        jdbc.update("INSERT INTO production_plans VALUES(:id,'PLAN-1',false,false,false,false)", Map.of("id", plan));
        jdbc.update("INSERT INTO production_execution_segments VALUES(:id,:plan,NULL,NULL,false,'READY')", Map.of("id", segment, "plan", plan));
        jdbc.update("""
                INSERT INTO production_material_discovery_requests VALUES(:id,:number,:segment,'2026-10-01 00:00:00+00',
                    '[{"goodsName":"待填写","qty":2}]'::jsonb,:status,1)
                """, Map.of("id", request, "number", "MD-" + request, "segment", segment, "status", status));
        return request;
    }
}
