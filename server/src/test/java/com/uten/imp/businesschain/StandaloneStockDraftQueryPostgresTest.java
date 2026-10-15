package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.features.documents.DocumentDraftCountQueryService;
import com.uten.imp.features.master.warehouse.WarehouseKeeperService;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Real HTTP, JPA predicates, owner/warehouse policies and badge SQL on isolated PostgreSQL. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.workshop-material.auto-close.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@Transactional
class StandaloneStockDraftQueryPostgresTest {
    private static final List<String> TYPES = List.of("TRANSFER", "CHECK", "OTHER_IN", "OTHER_OUT",
            "DRAW", "WDRAW", "WASTE", "FINISHED_IN", "FINISHED_OUT");
    private static final Map<String, String> PREFIX = Map.of("TRANSFER", "CB", "CHECK", "PQ",
            "OTHER_IN", "QR", "OTHER_OUT", "QC", "DRAW", "SL", "WDRAW", "ST", "WASTE", "QW",
            "FINISHED_IN", "CR", "FINISHED_OUT", "CC");
    private static final AtomicInteger SEQUENCE = new AtomicInteger(900000);
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired DocumentDraftCountQueryService drafts;
    @Autowired WarehouseTaskScopePort scopes;
    @Autowired WarehouseKeeperService keepers;
    @Autowired com.uten.imp.features.stock.StockDocAccessPolicy stockAccess;
    private FullChainEndToEndTest fixture;
    private UUID keeper, other, employee, otherEmployee, warehouseA, warehouseB, material, unit;

    @BeforeEach void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String tag = "standalone-" + UUID.randomUUID().toString().substring(0, 8);
        var world = fixture.seedWorld(tag);
        material=world.goodsA(); unit=world.unitId();
        keeper = fixture.createUserWithPerms(world, "keeper-" + tag, "stock_doc:view");
        other = fixture.createUserWithPerms(world, "other-" + tag, "stock_doc:view");
        employee = employee(keeper);
        otherEmployee = employee(other);
        UUID department = db.queryForObject("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted", UUID.class);
        db.update("UPDATE employees SET department_id=? WHERE id=?", department, employee);
        // SUB_WH legitimately grants view-all. Explicitly deny that separate permission so this actor
        // exercises ordinary owner isolation while retaining warehouse-keeper responsibility.
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) "
                + "SELECT ?,id,'revoke' FROM permissions WHERE code='stock_doc:view:all'", keeper);
        List<UUID> roots = db.queryForList("SELECT id FROM warehouses WHERE code='001' AND NOT is_deleted", UUID.class);
        UUID root;
        if (roots.isEmpty()) {
            root = UUID.randomUUID();
            db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES (?,'001',?,'使用',true)",
                    root, "草稿范围主仓" + tag);
        } else root = roots.getFirst();
        warehouseA = warehouse(root);
        warehouseB = warehouse(root);
        fixture.loginAs(world.superAdminUserId());
        keepers.replaceKeepers(warehouseA, new WarehouseKeeperSaveRequest(List.of(employee)));
        fixture.loginAs(keeper);
        assertEquals(WarehouseTaskScopePort.Role.KEEPER, scopes.access().role());
        assertFalse(stockAccess.scope().seeAll(), "owner fixture must not inherit the department's view-all grant");
        assertEquals(0, drafts.counts().stockDocument(), "new owner's workspace starts empty");
    }

    @AfterEach void clearIdentity() { SecurityContextHolder.clearContext(); }

    @Test void allManualTypesAgreeWithTheBadgeAndProductionDraftsAreExcluded() throws Exception {
        Set<UUID> manual = new HashSet<>();
        for (String type : TYPES) manual.add(document(type, employee, warehouseA, null, 0, false));
        Set<UUID> automatic = productionDocuments(employee);
        document("OTHER_IN", employee, warehouseA, null, 1, false);
        document("OTHER_IN", employee, warehouseA, null, -1, false);
        document("OTHER_IN", employee, warehouseA, null, 0, true);
        validateFixture();

        assertEquals(manual.size(), drafts.counts().stockDocument());
        assertEquals(manual, workspace(Map.of("standaloneDrafts", "true")));
        assertEquals(1, drafts.counts().stockTransfer());
        assertEquals(1, drafts.counts().stockCheck());
        for (String type : TYPES) {
            JsonNode page = page(type, Map.of("standaloneDrafts", "true"));
            assertEquals(1, page.path("total").asLong(), type);
            assertEquals(0, page.path("items").get(0).path("status").asInt());
            assertFacetMatchesPage(type, Map.of("standaloneDrafts", "true"), page);
        }
        for (UUID id : automatic) {
            assertTrue(db.queryForObject("SELECT fn_is_production_linked_stock_document(?)", Boolean.class, id));
            assertEquals(0, db.queryForObject("SELECT status FROM stock_documents WHERE id=?", Integer.class, id));
        }
    }

    @Test void absentFalseAndUnknownQueryOptionsKeepTheExistingListBehavior() throws Exception {
        document("OTHER_IN", employee, warehouseA, null, 0, false);
        document("OTHER_IN", employee, warehouseA, null, 1, false);
        Set<UUID> automatic = productionDocuments(employee);
        validateFixture();
        Set<UUID> legacy = workspace(Map.of());
        assertTrue(legacy.containsAll(automatic));
        assertEquals(legacy, workspace(Map.of("standaloneDrafts", "false")));
        assertEquals(legacy, workspace(Map.of("unrecognizedOption", "true")));
        for (String type : TYPES) assertFacetMatchesPage(type, Map.of(), page(type, Map.of()));
        assertEquals(1, workspace(Map.of("standaloneDrafts", "true")).size());
    }

    @Test void ownerAndWarehouseScopesStayInForceIncludingTheOwnDraftException() throws Exception {
        UUID ownA = document("OTHER_IN", employee, warehouseA, null, 0, false);
        UUID ownB = document("CHECK", employee, warehouseB, null, 0, false);
        UUID grantedA = document("OTHER_OUT", otherEmployee, warehouseA, null, 0, false);
        UUID transferIntoA = document("TRANSFER", otherEmployee, warehouseB, warehouseA, 0, false);
        document("OTHER_IN", otherEmployee, warehouseB, null, 0, false);
        document("OTHER_IN", null, warehouseA, null, 0, false);
        validateFixture();
        assertEquals(Set.of(ownA, ownB), workspace(Map.of("standaloneDrafts", "true")),
                "another owner and null ownership are not readable; own default-scope drafts survive outside warehouse A");
        db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES (?,'stock_doc',?)", keeper, otherEmployee);
        validateFixture();
        Set<UUID> expected = Set.of(ownA, ownB, grantedA, transferIntoA);
        assertEquals(expected.size(), drafts.counts().stockDocument());
        assertEquals(expected, workspace(Map.of("standaloneDrafts", "true")));
        Map<String, String> selected = Map.of("standaloneDrafts", "true", "scopeWarehouseId", warehouseA.toString());
        assertEquals(Set.of(ownA, grantedA, transferIntoA), workspace(selected));
        assertEquals(3L, scopes.withRequestedWarehouse(warehouseA, () -> drafts.counts().stockDocument()));
        for (String type : TYPES) assertFacetMatchesPage(type, selected, page(type, selected));
        read("/api/stock/docs", Map.of("docType", "OTHER_IN", "standaloneDrafts", "true",
                "scopeWarehouseId", warehouseB.toString()), 403);
        read("/api/stock/docs/facets", Map.of("docType", "OTHER_IN", "standaloneDrafts", "true",
                "scopeWarehouseId", warehouseB.toString()), 403);
    }

    @Test void standaloneFilterIntersectsOtherHeadersAndCannotExposeApprovedDocuments() throws Exception {
        document("OTHER_IN", employee, warehouseA, null, 0, false);
        document("OTHER_IN", employee, warehouseA, null, 1, false);
        validateFixture();
        Map<String, String> conflicting = Map.of("standaloneDrafts", "true", "status", "1", "excludeKey", "status");
        JsonNode page = page("OTHER_IN", conflicting);
        assertEquals(0, page.path("total").asLong());
        assertFacetMatchesPage("OTHER_IN", conflicting, page);
    }

    @Test void historyFlagsCannotPutDeletedDocumentsIntoTheStandaloneWorkspace() throws Exception {
        UUID live = document("OTHER_IN", employee, warehouseA, null, 0, false);
        UUID deleted = document("OTHER_IN", employee, warehouseA, null, 0, true);
        validateFixture();
        Map<String, String> withHistory = Map.of("standaloneDrafts", "true", "includeDeleted", "true",
                "excludeKey", "isDeleted");
        assertEquals(Set.of(live), workspace(withHistory));
        assertFacetMatchesPage("OTHER_IN", withHistory, page("OTHER_IN", withHistory));
        Map<String, String> onlyHistory = Map.of("standaloneDrafts", "true", "onlyDeleted", "true");
        assertTrue(workspace(onlyHistory).isEmpty());
        assertFacetMatchesPage("OTHER_IN", onlyHistory, page("OTHER_IN", onlyHistory));
        assertEquals(Set.of(live), workspace(Map.of("includeDeleted", "true")),
                "active workflow excludes deleted records even when history visibility was requested");
        assertEquals(Set.of(deleted), workspace(Map.of("view", "HISTORY", "includeDeleted", "true")));
        assertEquals(Set.of(deleted), workspace(Map.of("view", "HISTORY", "standaloneDrafts", "false", "onlyDeleted", "true")));
    }

    @Test void lifecycleFiltersActualPostedStatesBeforeHttpPagesAndHeaderFacets() throws Exception {
        UUID draft=document("OTHER_IN",employee,warehouseA,null,0,false);
        UUID pendingReturn=document("WDRAW",employee,warehouseA,null,0,false);
        UUID receivedReturn=document("WDRAW",employee,warehouseA,null,1,false);
        UUID posted=document("OTHER_IN",employee,warehouseA,null,1,false);
        UUID reversed=document("OTHER_IN",employee,warehouseA,null,-1,false);
        UUID hidden=document("OTHER_IN",otherEmployee,warehouseA,null,1,false);
        UUID deleted=document("OTHER_IN",employee,warehouseA,null,0,true);
        UUID draw=document("DRAW",employee,warehouseA,null,0,false);
        UUID line=UUID.randomUUID();
        db.update("""
                INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,unit_id,
                  unit_rate,qty,base_qty,issued_qty,goods_snapshot_source,goods_code_snapshot,goods_name_snapshot)
                SELECT ?,document.id,document.doc_type,document.bill_no,document.bill_date,1,goods.id,?,
                  1,2,2,0,'MASTER_AT_SAVE',goods.code,goods.name
                FROM stock_documents document JOIN goods ON goods.id=? WHERE document.id=?
                """,line,unit,material,draw);
        db.update("UPDATE stock_documents SET status=1 WHERE id=?",draw);
        validateFixture();
        assertTrue(db.queryForObject("SELECT fn_production_draw_pending(?)",Boolean.class,draw));
        assertEquals(Set.of(draft,pendingReturn,draw),workspace(Map.of()));
        assertEquals(Set.of(posted,reversed,receivedReturn),workspace(Map.of("view","HISTORY")));
        assertFalse(workspace(Map.of("view","HISTORY")).contains(hidden));
        assertFalse(workspace(Map.of("view","HISTORY")).contains(deleted));
        for(String type:TYPES) {
            assertFacetMatchesPage(type,Map.of(),page(type,Map.of()));
            assertFacetMatchesPage(type,Map.of("view","HISTORY"),page(type,Map.of("view","HISTORY")));
        }
        JsonNode second=read("/api/stock/docs",Map.of("docType","OTHER_IN","view","HISTORY","page","2","size","1"),200);
        assertEquals(2,second.path("total").asInt());
        assertEquals(2,second.path("totalPages").asInt());
        assertEquals(1,second.path("items").size());
        read("/api/stock/docs",Map.of("docType","OTHER_IN","view","ALL"),422);
    }

    @Test void standaloneParameterDoesNotBypassTheStockViewPermission() throws Exception {
        var world = fixture.seedWorld("no-stock-" + UUID.randomUUID().toString().substring(0, 8));
        UUID noView = fixture.createUserWithPerms(world, "no-view-" + UUID.randomUUID(), "notice:read");
        fixture.loginAs(noView);
        assertEquals(0, drafts.counts().stockDocument());
        read("/api/stock/docs", Map.of("docType", "CHECK", "standaloneDrafts", "true"), 403);
        read("/api/stock/docs/facets", Map.of("docType", "CHECK", "standaloneDrafts", "true"), 403);
    }

    private Set<UUID> productionDocuments(UUID maker) {
        UUID plan = UUID.randomUUID();
        db.update("INSERT INTO production_plans(id,bill_no,bill_date,status) VALUES (?,?,?,1)",
                plan, number("SJ"), LocalDate.of(2026, 10, 14));
        Set<UUID> result = new HashSet<>();
        for (String type : List.of("DRAW", "WDRAW", "FINISHED_IN")) {
            UUID id = document(type, maker, warehouseA, null, 0, false);
            db.update("INSERT INTO plan_draw_links(plan_id,draw_id) VALUES (?,?)", plan, id);
            result.add(id);
        }
        return result;
    }
    private UUID document(String type, UUID maker, UUID warehouse, UUID toWarehouse, int status, boolean deleted) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,maker_id,warehouse_id,to_warehouse_id,
                    status,is_deleted,deleted_at)
                VALUES (?,?,?,?,?,?,?,?,?,CASE WHEN ? THEN now() END)
                """, id, type, number(PREFIX.get(type)), LocalDate.of(2026, 10, 14), maker, warehouse,
                toWarehouse, (short) status, deleted, deleted);
        return id;
    }
    private UUID warehouse(UUID root) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES (?,?,?,?,'使用',true)",
                id, "SD-" + id.toString().substring(0, 8), "草稿仓" + id, root);
        return id;
    }
    private UUID employee(UUID user) { return db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, user); }
    private static String number(String prefix) {
        return prefix + LocalDate.of(2026, 10, 14).format(DateTimeFormatter.BASIC_ISO_DATE) + SEQUENCE.incrementAndGet();
    }
    private void validateFixture() { db.execute("SET CONSTRAINTS ALL IMMEDIATE"); }
    private Set<UUID> workspace(Map<String, String> options) throws Exception {
        Set<UUID> result = new HashSet<>();
        for (String type : TYPES) {
            JsonNode page = page(type, options);
            assertEquals(page.path("total").asInt(), page.path("items").size());
            for (JsonNode item : page.path("items")) assertTrue(result.add(UUID.fromString(item.path("id").asText())));
        }
        return result;
    }
    private JsonNode page(String type, Map<String, String> options) throws Exception {
        Map<String, String> query = new HashMap<>(options);
        query.put("docType", type); query.put("page", "1"); query.put("size", "100");
        return read("/api/stock/docs", query, 200);
    }
    private void assertFacetMatchesPage(String type, Map<String, String> options, JsonNode page) throws Exception {
        Map<String, String> query = new HashMap<>(options); query.put("docType", type);
        JsonNode buckets = read("/api/stock/docs/facets", query, 200).path("billNo");
        Map<String, Long> actual = new HashMap<>();
        for (JsonNode bucket : buckets) actual.put(bucket.path("value").asText(), bucket.path("count").asLong());
        Map<String, Long> expected = new HashMap<>();
        for (JsonNode item : page.path("items")) expected.merge(item.path("billNo").asText(), 1L, Long::sum);
        assertEquals(expected, actual, type + " facets must use the same owner/warehouse/draft/source predicates");
    }
    private JsonNode read(String path, Map<String, String> options, int expectedStatus) throws Exception {
        var actor = SecurityContextHolder.getContext().getAuthentication();
        var request = get(path).with(authentication(actor));
        options.forEach(request::param);
        try {
            var response = http.perform(request).andReturn().getResponse();
            assertEquals(expectedStatus, response.getStatus(), response.getContentAsString());
            return json.readTree(response.getContentAsByteArray());
        } finally {
            SecurityContextHolder.getContext().setAuthentication(actor);
        }
    }
}
