package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real PostgreSQL and HTTP method security; all actors and business data are isolated fixtures. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.workshop-material.auto-close.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@Import(BusinessMasterReferenceHttpPostgresTest.PublicationProbeConfiguration.class)
class BusinessMasterReferenceHttpPostgresTest {
    private static final String API = "/api/business-references";
    private static final Set<String> PARTY_FIELDS = Set.of("id", "code", "name", "categoryId", "status", "defaultSettlementMethodId", "selectable");
    private static final Set<String> PRIVATE_PARTY = Set.of("phone", "phone2", "mobile", "fax", "bank", "bankAccount", "taxId", "address", "credit", "initTotal", "initTotal2");
    private static final Set<String> GOODS_COMMERCIAL = Set.of("price", "purchasePrice", "salePrice", "discount", "discountRate", "stockQty", "stockQuantity", "stockAmount", "cost", "costPrice", "initBalance");
    private static final Set<String> ACCOUNT_PRIVATE = Set.of("bankAccountNo", "bankAccount", "bankNo", "initBalance", "balanceCurrent", "receiptsTotal", "paymentsTotal", "balanceAdjustmentsTotal", "balanceFloor");

    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired PlatformTransactionManager transactionManager;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private String tag;

    @BeforeEach void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        tag = "BREF" + UUID.randomUUID().toString().replace("-", "").substring(0, 12);
        world = fixture.seedWorld(tag);
    }

    @AfterEach void clear() {
        ClientPublicationProbe.PENDING.remove();
        SecurityContextHolder.clearContext();
    }

    private void fixtureWrite(Runnable work) {
        new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
            db.queryForObject("SELECT set_config('app.actor_id', ?, true)", String.class, world.superAdminUserId().toString());
            work.run();
        });
    }

    private UUID login(String suffix, String... codes) {
        UUID actor = new TransactionTemplate(transactionManager).execute(status -> {
            db.queryForObject("SELECT set_config('app.actor_id', ?, true)", String.class, world.superAdminUserId().toString());
            return fixture.createUserWithPerms(world, tag + suffix, codes);
        });
        fixture.loginAs(actor);
        var initial = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        Set<String> requested = Set.of(codes);
        Set<String> inherited = new HashSet<>(initial.getPermissions());
        inherited.removeAll(requested);
        // FullChain deliberately resolves the fresh database's baseline. Use
        // explicit personal revokes for this synthetic actor rather than
        // changing that global baseline or constructing a fake authority set.
        fixtureWrite(() -> inherited.forEach(code -> db.update(
                "INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code=? ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='revoke',active=TRUE",
                actor, code)));
        fixture.loginAs(actor);
        var principal = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        assertFalse(principal.isSuperAdmin());
        assertEquals(requested, principal.getPermissions());
        return actor;
    }

    private JsonNode read(String path, Map<String, String> parameters, int expected) throws Exception {
        var actor = SecurityContextHolder.getContext().getAuthentication();
        var request = get(path).with(authentication(actor));
        parameters.forEach(request::param);
        try {
            var response = http.perform(request).andReturn().getResponse();
            assertEquals(expected, response.getStatus(), response.getContentAsString());
            return response.getContentAsByteArray().length == 0 ? json.nullNode() : json.readTree(response.getContentAsByteArray());
        } finally {
            SecurityContextHolder.getContext().setAuthentication(actor);
        }
    }

    private JsonNode search(String path, Map<String, Object> body, int expected) throws Exception {
        return search(path, body, Map.of(), expected);
    }

    private JsonNode search(String path, Map<String, Object> body, Map<String, String> parameters, int expected) throws Exception {
        var actor = SecurityContextHolder.getContext().getAuthentication();
        try {
            var request = post(path).with(authentication(actor)).with(csrf().asHeader()).contentType("application/json")
                    .content(json.writeValueAsBytes(body));
            parameters.forEach(request::param);
            var response = http.perform(request).andReturn().getResponse();
            assertEquals(expected, response.getStatus(), response.getContentAsString());
            return json.readTree(response.getContentAsByteArray());
        } finally {
            SecurityContextHolder.getContext().setAuthentication(actor);
        }
    }

    private Set<String> fields(JsonNode row) {
        Set<String> names = new HashSet<>();
        row.fieldNames().forEachRemaining(names::add);
        return names;
    }

    private Set<String> ids(JsonNode rows) {
        Set<String> ids = new HashSet<>();
        rows.forEach(row -> ids.add(row.path("id").asText()));
        return ids;
    }

    private void noFields(JsonNode node, Set<String> forbidden) {
        if (node.isObject()) {
            assertTrue(Collections.disjoint(fields(node), forbidden), node::toString);
            node.elements().forEachRemaining(child -> noFields(child, forbidden));
        } else if (node.isArray()) node.forEach(child -> noFields(child, forbidden));
    }

    @Test void receiptActorUsesMinimumReferencesAndCannotReadFullMasters() throws Exception {
        login("-receipt", "warehouse_inbound:view", "warehouse_inbound:stock_in");
        JsonNode supplier = read(API + "/suppliers", Map.of("keyword", tag), 200).path("items").get(0);
        assertTrue(PARTY_FIELDS.containsAll(fields(supplier)));
        assertEquals(world.supplierId().toString(), supplier.path("id").asText());
        noFields(supplier, PRIVATE_PARTY);
        JsonNode supplierPost = search(API + "/suppliers/search", Map.of("keyword", tag), 200).path("items");
        assertEquals(Set.of(world.supplierId().toString()), ids(supplierPost));
        var realAuthentication = SecurityContextHolder.getContext().getAuthentication();
        var real = (AuthUser) realAuthentication.getPrincipal();
        var simulated = new AuthUser(real.getId(), real.getEmployeeId(), real.getLoginAccount(), real.getPermissions(),
                false, true, false, false, world.superAdminUserId());
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(simulated, null, simulated.getAuthorities()));
        try {
            assertEquals(Set.of(world.supplierId().toString()), ids(search(API + "/suppliers/search", Map.of("keyword", tag), 200).path("items")));
        } finally {
            SecurityContextHolder.getContext().setAuthentication(realAuthentication);
        }
        JsonNode goods = read(API + "/goods", Map.of("keyword", tag), 200).path("items");
        assertEquals(5, goods.size());
        noFields(goods, GOODS_COMMERCIAL);
        assertTrue(goods.get(0).has("issueMethod"));
        assertTrue(goods.get(0).has("periodicCostBasis"));
        assertFalse(goods.get(0).path("writable").asBoolean());
        for (String path : List.of("/supplier-categories", "/goods/categories", "/departments", "/warehouses")) {
            JsonNode data = read(API + path, Map.of(), 200);
            assertTrue(data.isArray(), path);
            noFields(data, Set.of("managerId", "managerName", "headcount", "phone", "bankAccount"));
        }
        read("/api/master/units/dict", Map.of(), 200);
        read("/api/master/suppliers", Map.of(), 403);
        read("/api/master/suppliers/" + world.supplierId(), Map.of(), 403);
        read("/api/master/goods", Map.of(), 403);
        read("/api/master/goods/" + world.goodsA(), Map.of(), 403);
        read("/api/org/departments/tree", Map.of(), 403);
        read("/api/org/departments/" + world.departmentId(), Map.of(), 403);
    }

    @Test void purchaseCreateAloneCanSelectSupplierWithoutMasterView() throws Exception {
        login("-buyer", "purchase_order:create");
        JsonNode rows = read(API + "/suppliers", Map.of("keyword", tag), 200).path("items");
        assertEquals(Set.of(world.supplierId().toString()), ids(rows));
        noFields(rows, PRIVATE_PARTY);
        read("/api/master/suppliers/" + world.supplierId(), Map.of(), 403);
        read(API + "/clients", Map.of(), 403);
    }

    @Test void salesCreateRetainsCustomerObjectScopeAndDoesNotSearchHiddenContactData() throws Exception {
        UUID actor = login("-seller", "sales_order:create");
        UUID employee = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, actor);
        String phone = "HIDDENCLIENTPHONE" + UUID.randomUUID().toString().replace("-", "");
        String bank = "HIDDENCLIENTBANK" + UUID.randomUUID().toString().replace("-", "");
        String tax = "HIDDENCLIENTTAX" + UUID.randomUUID().toString().replace("-", "");
        UUID hidden = UUID.randomUUID();
        fixtureWrite(() -> {
            db.update("UPDATE clients SET owner_employee_id=?, phone=?, bank_account=?, tax_id=? WHERE id=?", employee, phone, bank, tax, world.clientId());
            db.update("INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id) VALUES(?,?,?,'使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients),?)",
                    hidden, "HIDDEN-" + tag, "Hidden customer " + tag, world.employeeId());
        });
        JsonNode rows = read(API + "/clients", Map.of("keyword", tag), 200).path("items");
        assertEquals(Set.of(world.clientId().toString()), ids(rows));
        noFields(rows, PRIVATE_PARTY);
        assertEquals(ids(rows), ids(search(API + "/clients/search", Map.of("keyword", tag), 200).path("items")));
        for (String keyword : List.of(phone, bank, tax)) {
            assertEquals(0, read(API + "/clients", Map.of("keyword", keyword), 200).path("total").asLong());
            assertEquals(0, search(API + "/clients/search-context", Map.of("keyword", keyword), 200).path("totalMatches").asLong());
        }
        read("/api/master/clients", Map.of(), 403);
        read("/api/master/clients/" + world.clientId(), Map.of(), 403);
    }

    @Test void suppliersHidePrivateSearchColumnsAndKeepOriginalDisabledLookupSemantics() throws Exception {
        login("-supplier-search", "purchase_order:create");
        String phone = "HIDDENSUPPLIERPHONE" + UUID.randomUUID().toString().replace("-", "");
        String bank = "HIDDENSUPPLIERBANK" + UUID.randomUUID().toString().replace("-", "");
        String tax = "HIDDENSUPPLIERTAX" + UUID.randomUUID().toString().replace("-", "");
        String fullName = "Reference supplier full legal name " + tag;
        UUID disabled = UUID.randomUUID(), internal = UUID.randomUUID();
        fixtureWrite(() -> {
            db.update("UPDATE suppliers SET phone=?,bank_account=?,tax_id=?,name='',description=? WHERE id=?", phone, bank, tax, fullName, world.supplierId());
            db.update("INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES(?,?,?,'禁用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers))", disabled, "DIS-" + tag, "Disabled supplier " + tag);
            db.update("INSERT INTO suppliers(id,code,name,status,code_sequence,is_internal_workshop) VALUES(?,?,?,'使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers),true)", internal, "INT-" + tag, "Internal workshop " + tag);
        });
        JsonNode selected = read(API + "/suppliers", Map.of("keyword", tag), 200).path("items");
        assertEquals(Set.of(world.supplierId().toString()), ids(selected));
        assertEquals(fullName, selected.get(0).path("name").asText());
        JsonNode postSelected = search(API + "/suppliers/search", Map.of("keyword", tag), 200).path("items");
        assertEquals(Set.of(world.supplierId().toString()), ids(postSelected));
        assertEquals(fullName, postSelected.get(0).path("name").asText());
        for (String keyword : List.of(phone, bank, tax)) {
            assertEquals(0, read(API + "/suppliers", Map.of("keyword", keyword), 200).path("total").asLong());
            assertEquals(0, search(API + "/suppliers/search-context", Map.of("keyword", keyword), 200).path("totalMatches").asLong());
        }
        JsonNode history = read("/api/master/suppliers/lookup", Map.of("ids", disabled + "," + internal), 200);
        assertEquals(Set.of(disabled.toString()), ids(history), "Original lookup excludes internal workshops but retains disabled names");
        assertEquals("禁用", history.get(0).path("status").asText());
        noFields(history, PRIVATE_PARTY);
    }

    @Test void categorySearchAndPaginationUseTheSameRestrictedSupplierPredicate() throws Exception {
        login("-category", "warehouse_inbound:view", "warehouse_inbound:stock_in");
        UUID parent = UUID.randomUUID(), child = UUID.randomUUID(), outside = UUID.randomUUID();
        UUID insideSupplier = UUID.randomUUID(), outsideSupplier = UUID.randomUUID();
        fixtureWrite(() -> {
            db.update("INSERT INTO supplier_categories(id,code,name,level) VALUES(?,?,?,0)", parent, "SC-" + tag, "Reference category " + tag);
            db.update("INSERT INTO supplier_categories(id,code,name,level,parent_id) VALUES(?,?,?,1,?)", child, "CH-" + tag, "Child category " + tag, parent);
            db.update("INSERT INTO supplier_categories(id,code,name,level) VALUES(?,?,?,0)", outside, "OUT-" + tag, "Other category " + tag);
            db.update("UPDATE suppliers SET category_id=? WHERE id=?", parent, world.supplierId());
            db.update("INSERT INTO suppliers(id,code,name,status,category_id,code_sequence) VALUES(?,?,?,'使用',?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers))", insideSupplier, "IN-" + tag, "Inside supplier " + tag, child);
            db.update("INSERT INTO suppliers(id,code,name,status,category_id,code_sequence) VALUES(?,?,?,'使用',?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers))", outsideSupplier, "SUP-OUT-" + tag, "Outside supplier " + tag, outside);
        });
        var query = new HashMap<>(Map.of("categoryId", parent.toString(), "keyword", tag, "size", "1"));
        JsonNode first = read(API + "/suppliers", query, 200);
        query.put("page", "2");
        JsonNode second = read(API + "/suppliers", query, 200);
        assertEquals(2, first.path("total").asInt());
        assertEquals(2, first.path("totalPages").asInt());
        Set<String> observed = new HashSet<>(ids(first.path("items")));
        observed.addAll(ids(second.path("items")));
        assertEquals(Set.of(world.supplierId().toString(), insideSupplier.toString()), observed);
        JsonNode postPage = search(API + "/suppliers/search", Map.of("keyword", tag),
                Map.of("categoryId", parent.toString(), "size", "1", "page", "1"), 200);
        assertEquals(2, postPage.path("total").asInt());
        assertEquals(ids(first.path("items")), ids(postPage.path("items")));
        JsonNode context = search(API + "/suppliers/search-context", Map.of("categoryId", parent, "keyword", tag), 200);
        assertEquals(2, context.path("totalMatches").asInt());
        Set<String> categories = new HashSet<>();
        context.path("categories").forEach(row -> categories.add(row.path("categoryId").asText()));
        assertEquals(Set.of(parent.toString(), child.toString()), categories);
    }

    @Test void goodsFiltersAndMatchingCategoriesDoNotExposeCommercialColumns() throws Exception {
        login("-goods", "warehouse_inbound:view", "warehouse_inbound:stock_in");
        UUID category = UUID.randomUUID();
        fixtureWrite(() -> {
            db.update("INSERT INTO material_categories(id,code,name,level) VALUES(?,?,?,0)", category, "MC-" + tag, "Goods category " + tag);
            db.update("UPDATE goods SET category_id=? WHERE id=?", category, world.goodsA());
        });
        JsonNode page = read(API + "/goods", Map.of("categoryId", category.toString(), "keyword", tag, "size", "1"), 200);
        assertEquals(1, page.path("total").asInt());
        assertEquals(world.goodsA().toString(), page.path("items").get(0).path("id").asText());
        noFields(page.path("items"), GOODS_COMMERCIAL);
        JsonNode none = read(API + "/goods", Map.of("categoryId", category.toString(), "keyword", tag, "sourceType", "采购"), 200);
        assertEquals(0, none.path("total").asInt());
        JsonNode categories = read(API + "/goods/search-category-ids", Map.of("categoryRootIds", category.toString(), "keyword", tag), 200);
        assertEquals(1, categories.size());
        assertEquals(category.toString(), categories.get(0).asText());
        JsonNode facets = read(API + "/goods/facets", Map.of("categoryId", category.toString(), "keyword", tag), 200);
        assertEquals(0, facets.path("paper").size());
        noFields(facets.path("nullCounts"), GOODS_COMMERCIAL);
        read(API + "/goods/facet-values", Map.of("categoryId", category.toString(), "keyword", tag, "field", "name"), 200);
        read(API + "/goods/facet-values", Map.of("categoryId", category.toString(), "keyword", tag, "field", "stockQty"), 422);
    }

    @Test void financeAccountAndPaymentCategoryChoicesDoNotContainOpeningOrBankBalances() throws Exception {
        login("-finance", "finance_payment:create");
        UUID account = UUID.randomUUID(), style = UUID.randomUUID();
        fixtureWrite(() -> {
            db.update("INSERT INTO payment_styles(id,code,name,category,level,status,init_balance) VALUES(?,?,?,'ACCOUNT',0,'使用',987654.32)", style, "PS-" + tag, "Reference account style " + tag);
            db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,bank_account_no) VALUES(?,?,?,'BANK',?,'使用',?,'SENSITIVE-BANK-DO-NOT-RETURN')", account, "AC-" + tag, "Reference account " + tag, world.currencyId(), style);
            db.update("UPDATE payment_styles SET linked_account_id=? WHERE id=?", account, style);
        });
        JsonNode accounts = read(API + "/accounts", Map.of(), 200);
        JsonNode selected = null;
        for (JsonNode row : accounts) if (row.path("id").asText().equals(account.toString())) selected = row;
        assertNotNull(selected);
        noFields(accounts, ACCOUNT_PRIVATE);
        assertEquals(world.currencyId().toString(), selected.path("currencyId").asText());
        read("/api/master/accounts", Map.of(), 403);
        read("/api/master/accounts/" + account, Map.of(), 403);
        JsonNode styles = read("/api/master/payment-styles/tree", Map.of(), 200);
        JsonNode selectedStyle = findById(styles, style.toString());
        assertNotNull(selectedStyle);
        assertTrue(!selectedStyle.has("initBalance") || selectedStyle.path("initBalance").isNull());
        assertEquals(account.toString(), selectedStyle.path("linkedAccountId").asText());
    }

    @Test void unpublishedStockColumnsCannotBeInferredThroughAuxiliaryFiltersOrSort() throws Exception {
        login("-stock-probe", "production_plan:create");
        read(API + "/goods", Map.of("keyword", tag), 200);
        var actor = SecurityContextHolder.getContext().getAuthentication();
        for (Map<String, String> query : List.of(
                Map.of("keyword", tag, "search.stockQty", ">=123"),
                Map.of("keyword", tag, "sort", "stockQty", "order", "desc"))) {
            var request = get(API + "/goods").with(authentication(actor));
            query.forEach(request::param);
            var response = http.perform(request).andReturn().getResponse();
            assertTrue(Set.of(403, 422).contains(response.getStatus()), response.getContentAsString());
            SecurityContextHolder.getContext().setAuthentication(actor);
        }
    }

    private JsonNode findById(JsonNode rows, String id) {
        for (JsonNode row : rows) {
            if (row.path("id").asText().equals(id)) return row;
            JsonNode child = findById(row.path("children"), id);
            if (child != null) return child;
        }
        return null;
    }

    @Test void unrelatedHrVisitorAndAnonymousActorsDoNotGainBusinessResourceAccess() throws Exception {
        for (String code : List.of("employee:view", "notice:read")) {
            login("-unrelated-" + code.replace(':', '-'), code);
            for (String path : List.of("/suppliers", "/clients", "/goods", "/accounts")) read(API + path, Map.of(), 403);
        }
        var visitor = AuthUser.visitor(UUID.randomUUID(), "synthetic-reference-visitor", "V-REF", Set.of("warehouse_inbound:view", "warehouse_inbound:stock_in"));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(visitor, null, visitor.getAuthorities()));
        read(API + "/suppliers", Map.of(), 403);
        read(API + "/goods", Map.of(), 403);
        SecurityContextHolder.clearContext();
        var anonymous = http.perform(get(API + "/suppliers")).andReturn().getResponse();
        assertTrue(Set.of(401, 403).contains(anonymous.getStatus()));
        assertFalse(anonymous.getContentAsString().contains(world.supplierId().toString()));
    }

    @Test void customerSharingRevokeStopsAlreadyBuiltBusinessAndLegacyReferenceResponses() throws Exception {
        UUID actor = login("-shared-client", "sales_order:create");
        UUID employee = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, actor);
        fixtureWrite(() -> {
            db.update("UPDATE clients SET owner_employee_id=? WHERE id=?", world.employeeId(), world.clientId());
            db.update("INSERT INTO client_visibility_grants(client_id,grantee_employee_id,active,row_version,granted_by_user_id) VALUES(?,?,true,1,?)",
                    world.clientId(), employee, world.superAdminUserId());
        });
        for (String path : List.of(API + "/clients", "/api/master/clients/dict", "/api/master/clients/lookup")) {
            fixtureWrite(() -> db.update("UPDATE client_visibility_grants SET active=true,row_version=row_version+1,revoked_at=NULL,revoked_by_user_id=NULL WHERE client_id=? AND grantee_employee_id=?", world.clientId(), employee));
            var parameters = path.endsWith("lookup") ? Map.of("ids", world.clientId().toString())
                    : path.equals(API + "/clients") ? Map.of("keyword", tag) : Map.<String, String>of();
            JsonNode visible = read(path, parameters, 200);
            assertTrue(ids(visible.isArray() ? visible : visible.path("items")).contains(world.clientId().toString()), path);
            ClientPublicationProbe.PENDING.set(() -> fixtureWrite(() ->
                    db.update("UPDATE client_visibility_grants SET active=false,row_version=row_version+1,revoked_at=clock_timestamp(),revoked_by_user_id=? WHERE client_id=? AND grantee_employee_id=?", world.superAdminUserId(), world.clientId(), employee)));
            JsonNode denied = read(path, parameters, 403);
            assertEquals("READ_SCOPE_CHANGED", denied.path("code").asText(), path);
            JsonNode fresh = read(path, parameters, 200);
            assertFalse(ids(fresh.isArray() ? fresh : fresh.path("items")).contains(world.clientId().toString()), path);
        }
    }

    @TestConfiguration(proxyBeanMethods=false)
    static class PublicationProbeConfiguration {
        @Bean ClientPublicationProbe businessMasterClientPublicationProbe() {
            return new ClientPublicationProbe();
        }
    }

    @org.springframework.web.bind.annotation.RestControllerAdvice
    @org.springframework.core.annotation.Order(org.springframework.core.Ordered.HIGHEST_PRECEDENCE + 25)
    static class ClientPublicationProbe implements org.springframework.web.servlet.mvc.method.annotation.ResponseBodyAdvice<Object> {
        static final ThreadLocal<Runnable> PENDING = new ThreadLocal<>();
        @Override public boolean supports(org.springframework.core.MethodParameter parameter,
                Class<? extends org.springframework.http.converter.HttpMessageConverter<?>> converter) { return true; }
        @Override public Object beforeBodyWrite(Object body, org.springframework.core.MethodParameter parameter,
                org.springframework.http.MediaType mediaType,
                Class<? extends org.springframework.http.converter.HttpMessageConverter<?>> converter,
                org.springframework.http.server.ServerHttpRequest request,
                org.springframework.http.server.ServerHttpResponse response) {
            Runnable pending = PENDING.get();
            if (pending != null && Set.of(API + "/clients", "/api/master/clients/dict", "/api/master/clients/lookup").contains(request.getURI().getPath())) {
                PENDING.remove();
                pending.run();
            }
            return body;
        }
    }
}
