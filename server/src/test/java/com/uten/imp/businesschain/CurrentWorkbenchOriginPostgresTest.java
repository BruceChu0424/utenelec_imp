package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Real login, full migrated schema and read endpoints: current work never includes imported roots. */
class CurrentWorkbenchOriginPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired private DocNumberService numbers;

    @Test
    void dashboardKeepsNativeActiveOrdersButNeverCountsImportedRawStates() throws Exception {
        String token = adminToken();
        UUID maker = UUID.fromString(newEmployee(token).employeeId());
        UUID client = client();
        long before = salesActive(read(token, "/api/dashboard/overview", "", "CURRENT"));
        order(client, maker, (short) 0, null);
        order(client, maker, (short) 1, null);
        long withNative = salesActive(read(token, "/api/dashboard/overview", "", "CURRENT"));
        assertEquals(before + 1, withNative, "native approved, open work must remain counted");

        int legacy = legacyBase();
        List<UUID> imported = List.of(
                order(client, maker, (short) 0, legacy),
                order(client, maker, (short) 1, legacy + 1),
                order(client, maker, (short) -1, legacy + 2));
        List<String> original = imported.stream().map(id -> original("sales_orders", id)).toList();
        for (String origin : List.of("CURRENT", "ALL", "LEGACY")) {
            assertEquals(withNative, salesActive(read(token, "/api/dashboard/overview", "", origin)),
                    "an origin query parameter cannot broaden the current dashboard: " + origin);
        }
        assertEquals(original, imported.stream().map(id -> original("sales_orders", id)).toList(),
                "dashboard reads must preserve every source field, including raw status and provenance");
    }

    @Test
    void productionCurrentListFacetsAndCountCannotBeBroadenedByOriginScope() throws Exception {
        Employee actor = newEmployee(adminToken(), "DEPT_ENG");
        // Task reads deliberately ignore the technical administrator's catalog expansion.
        // Use explicit, current grants and a fresh real login for the business actor.
        UUID actorId = UUID.fromString(actor.userId());
        UUID grantor = jdbc.queryForObject("SELECT id FROM users WHERE login_account=?", UUID.class, ADMIN_LOGIN);
        for (String code : List.of("production_execution:overview", "production_plan:edit",
                "production_plan:view", "production_plan:view:all", "sales_order:view")) {
            assertEquals(1, jdbc.update("""
                    INSERT INTO user_permission_overrides(user_id,permission_id,effect,active,authority_source,source_actor_user_id,row_version)
                    SELECT ?,id,'grant',true,'SUPER_ADMIN_CONFIRMED',?,1 FROM permissions WHERE code=?
                    """, actorId, grantor, code), "the real permission catalog must contain " + code);
        }
        String token = login(actor.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        String keyword = "CURRENTWORK" + UUID.randomUUID().toString().replace("-", "");
        UUID maker = UUID.fromString(actor.employeeId());
        UUID goods = goods(keyword), unit = unit(), client = client();
        long before = read(token, "/api/production/execution-workbench/count", "", "CURRENT")
                .path("count").asLong();
        Plan nativePlan = plan(maker, goods, unit, null);
        UUID salesOrder = order(client, maker, (short) 1, null);
        String salesBill = jdbc.queryForObject("SELECT bill_no FROM sales_orders WHERE id=?", String.class, salesOrder);
        UUID salesItem = salesItem(salesOrder, goods, unit);
        UUID analysis = analysis(maker, goods, unit, salesItem);
        long withNative = read(token, "/api/production/execution-workbench/count", "", "CURRENT")
                .path("count").asLong();
        assertEquals(before + 2, withNative, "both real PLAN and ANALYSIS roots must remain current work");

        Plan imported = plan(maker, goods, unit, legacyBase());
        String originalPlan = original("production_plans", imported.id());
        String originalItem = original("production_plan_items", imported.itemId());
        assertEquals("PLAN", jdbc.queryForObject(
                "SELECT root_type FROM v_production_execution_workbench_roots WHERE root_id=?", String.class, imported.id()),
                "the fixture must actually reach the production root view before endpoint filtering");

        for (String origin : List.of("CURRENT", "ALL", "LEGACY")) {
            JsonNode nativePage = read(token, "/api/production/execution-workbench", nativePlan.bill(), origin);
            assertEquals(1, nativePage.path("total").asInt(), nativePage.toString());
            assertEquals(nativePlan.id().toString(), nativePage.path("items").get(0).path("rootId").asText());
            assertEquals("PLAN", nativePage.path("items").get(0).path("rootType").asText());
            assertEquals(0, read(token, "/api/production/execution-workbench", imported.bill(), origin)
                    .path("total").asInt(), "imported unfinished raw plans are historical, never a current task");
            assertEquals(withNative, read(token, "/api/production/execution-workbench/count", "", origin)
                    .path("count").asLong(), "the global count must be pinned to CURRENT, independent of the request");

            JsonNode analysisPage = read(token, "/api/production/execution-workbench", keyword, origin);
            assertEquals(1, analysisPage.path("total").asInt(), analysisPage.toString());
            assertEquals(analysis.toString(), analysisPage.path("items").get(0).path("rootId").asText());
            assertEquals("ANALYSIS", analysisPage.path("items").get(0).path("rootType").asText());
            JsonNode facets = read(token, "/api/production/execution-workbench/facets", keyword, origin);
            assertEquals(1, facets.path("orders").size(), facets.toString());
            assertEquals(salesBill, facets.path("orders").get(0).path("value").asText(), facets.toString());
            assertEquals(1, facets.path("orders").get(0).path("count").asInt(), facets.toString());
        }
        JsonNode history = read(token, "/api/production/plans/" + imported.id() + "/history", "", "LEGACY");
        assertTrue(history.path("legacyImported").asBoolean(), history.toString());
        assertTrue(history.path("historyReadOnly").asBoolean(), history.toString());
        assertEquals(1, history.path("status").asInt(), "history must not fabricate a terminal source status");
        assertFalse(history.path("closed").asBoolean(), "history must not fabricate a source closed flag");
        assertEquals(originalPlan, original("production_plans", imported.id()));
        assertEquals(originalItem, original("production_plan_items", imported.itemId()));
    }

    private UUID client() {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,code_sequence) VALUES (?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))",
                id, "CW-" + id, "当前任务来源测试客户");
        return id;
    }

    private UUID goods(String name) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES (?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                id, "CW-" + id, name);
        return id;
    }

    private UUID unit() {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO units(id,code,name) VALUES (?,?,'件')", id, "CW-" + id);
        return id;
    }

    private UUID order(UUID client, UUID maker, short status, Integer legacy) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,maker_id,status,finance_confirmed,legacy_id)
                VALUES (?,?,CURRENT_DATE,?,?,?,?,?)
                """, id, numbers.nextNumber(DocNumberPrefix.SALES_ORDER), client, maker, status, status == 1, legacy);
        return id;
    }

    private UUID salesItem(UUID order, UUID goods, UUID unit) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO sales_order_items(id,bill_no,bill_date,order_id,goods_id,unit_id,unit_rate,qty,chain_status,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                SELECT ?,orders.bill_no,orders.bill_date,orders.id,goods.id,?,1,10,1,
                    goods.code,goods.name,'MASTER_AT_APPROVAL',now()
                FROM sales_orders orders CROSS JOIN goods WHERE orders.id=? AND goods.id=?
                """, id, unit, order, goods);
        return id;
    }

    private UUID analysis(UUID maker, UUID goods, UUID unit, UUID salesItem) {
        UUID id = UUID.randomUUID(), warehouse = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name) VALUES (?,?,'当前任务测试仓')", warehouse, "CW-" + warehouse);
        jdbc.update("""
                INSERT INTO production_material_analyses(id,warehouse_id,status,fingerprint,initial_idempotency_key,maker_id)
                VALUES (?,?,'ACTIVE',?,?,?)
                """, id, warehouse, "a".repeat(64), "current-work-analysis-" + id, maker);
        jdbc.update("""
                INSERT INTO production_material_analysis_items(id,analysis_id,source_type,sales_order_item_id,goods_id,unit_id,requested_qty)
                VALUES (?,?,'SALES_ORDER_ITEM',?,?,?,10)
                """, UUID.randomUUID(), id, salesItem, goods, unit);
        return id;
    }

    private Plan plan(UUID maker, UUID goods, UUID unit, Integer legacy) {
        UUID id = UUID.randomUUID(), item = UUID.randomUUID();
        String bill = numbers.nextNumber(DocNumberPrefix.PRODUCTION_PLAN);
        jdbc.update("INSERT INTO production_plans(id,bill_no,bill_date,status,maker_id,legacy_id) VALUES (?,?,CURRENT_DATE,1,?,?)",
                id, bill, maker, legacy);
        String productNo = jdbc.queryForObject("SELECT fn_allocate_production_product_no(?)", String.class, id);
        jdbc.update("""
                INSERT INTO production_plan_items(id,bill_no,bill_date,plan_id,product_no,goods_id,unit_id,unit_rate,qty,iqty)
                VALUES (?,?,CURRENT_DATE,?,?,?,?,1,10,0)
                """, item, bill, id, productNo, goods, unit);
        return new Plan(id, item, bill);
    }

    private static int legacyBase() {
        return 1_700_000_000 + Math.floorMod(UUID.randomUUID().hashCode(), 100_000_000);
    }

    private String original(String table, UUID id) {
        if (!List.of("sales_orders", "production_plans", "production_plan_items").contains(table)) {
            throw new IllegalArgumentException("Unexpected fixture table");
        }
        return jdbc.queryForObject("SELECT to_jsonb(document)::text FROM " + table + " document WHERE id=?", String.class, id);
    }

    private static long salesActive(JsonNode dashboard) {
        for (JsonNode metric : dashboard.path("metrics")) {
            if ("sales-active".equals(metric.path("id").asText())) return metric.path("value").asLong();
        }
        throw new AssertionError("authenticated administrator must receive sales-active");
    }

    private JsonNode read(String token, String path, String keyword, String origin) throws Exception {
        var response = mvc.perform(get(path).param("keyword", keyword).param("originScope", origin)
                .param("size", "100").header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, response.getResponse().getStatus(), body(response));
        return json(response);
    }

    private record Plan(UUID id, UUID itemId, String bill) {}
}
