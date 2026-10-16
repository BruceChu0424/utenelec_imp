package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.MvcResult;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Real endpoints: relevance is applied before pagination; counts retain business scope. */
class ProductionPendingProgressSearchPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired DocNumberService numbers;

    @Test
    void pendingSearchRanksGoodsNamesAndKeepsLiteralMultiwordCountAndFacets() throws Exception {
        String token = adminToken(), word = "PSEARCH" + UUID.randomUUID().toString().replace("-", "");
        UUID client = UUID.randomUUID(), unit = unit();
        jdbc.update("INSERT INTO clients(id,code,name,code_sequence) VALUES (?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))",
                client, "C-" + client, "检索客户");
        UUID prefix = goods("G-" + UUID.randomUUID(), word + "扩展", "SZZX");
        UUID code = goods(word, "其他物料", "S%_X");
        UUID exact = goods("G-" + UUID.randomUUID(), word, "S%_X");
        pendingOrder(client, unit, prefix, "2001-01-01");
        String codeBill = pendingOrder(client, unit, code, "2001-01-02");
        pendingOrder(client, unit, exact, "2001-01-03");
        JsonNode first = request(token, "/api/production/schedule/pending", word, 1, 1);
        JsonNode second = request(token, "/api/production/schedule/pending", word, 2, 1);
        JsonNode third = request(token, "/api/production/schedule/pending", word, 3, 1);
        assertEquals(3, first.path("total").asInt());
        assertEquals(exact.toString(), first.path("items").get(0).path("goodsId").asText());
        assertEquals(prefix.toString(), second.path("items").get(0).path("goodsId").asText());
        assertEquals(code.toString(), third.path("items").get(0).path("goodsId").asText());
        String compound = "S%_X\t" + word;
        JsonNode literal = request(token, "/api/production/schedule/pending", compound, 1, 20);
        assertEquals(2, literal.path("total").asInt());
        assertEquals(10, literal.path("items").get(0).path("needQty").asInt());
        JsonNode facets = request(token, "/api/production/schedule/pending/facets", compound, 1, 20);
        assertEquals(2, facets.path("orderBillNo").size());
        assertTrue(facets.path("orderBillNo").toString().contains(codeBill));
        assertEquals(2, facets.path("status").get(0).path("count").asInt()
                + facets.path("status").get(1).path("count").asInt());
        assertEquals(0, request(token, "/api/production/schedule/pending", word + " 不存在", 1, 20).path("total").asInt());
        String candidates = "/api/production/material-analyses/sales-candidates";
        JsonNode candidatePage = request(token, candidates, word, 1, 1);
        assertEquals(3, candidatePage.path("total").asInt());
        assertEquals(exact.toString(), candidatePage.path("items").get(0).path("lines").get(0).path("goodsId").asText());
        JsonNode candidateOrder = request(token, candidates, word, 1, 20);
        assertEquals(exact.toString(), candidateOrder.path("items").get(0).path("lines").get(0).path("goodsId").asText());
        assertEquals(prefix.toString(), candidateOrder.path("items").get(1).path("lines").get(0).path("goodsId").asText());
        assertEquals(2, request(token, candidates, compound, 1, 20).path("total").asInt());
        assertEquals(2, request(token, candidates + "/facets", compound, 1, 20).path("orderNo").size());
    }

    @Test
    void analysisListNamesRankBeforeSourceReferencesWithoutShrinkingFullSourceQuantities() throws Exception {
        String token = adminToken(), word = "ASEARCH" + UUID.randomUUID().toString().replace("-", "");
        UUID maker = UUID.fromString(newEmployee(token).employeeId()), warehouse = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name) VALUES (?,?,'分析检索仓')", warehouse, "W-" + warehouse);
        UUID prefix = analysis(goods("G-" + UUID.randomUUID(), word + "扩展", null), warehouse, maker, "普通来源");
        analysis(goods("G-" + UUID.randomUUID(), "其他产品", null), warehouse, maker, word);
        UUID exactGoods = goods("G-" + UUID.randomUUID(), word, null);
        UUID exact = analysis(exactGoods, warehouse, maker, "ROOT-10%_");
        source(exact, goods("G-" + UUID.randomUUID(), "分析附带另一产品", null), "另一来源", 20);
        String endpoint = "/api/production/material-analyses";
        JsonNode page = request(token, endpoint, word, 1, 1);
        assertEquals(3, page.path("total").asInt());
        assertEquals(exact.toString(), page.path("items").get(0).path("analysisId").asText());
        assertEquals(30, page.path("items").get(0).path("requestedQty").asInt());
        assertEquals(2, page.path("items").get(0).path("sourceCount").asInt());
        assertEquals(prefix.toString(), request(token, endpoint, word, 2, 1).path("items").get(0).path("analysisId").asText());
        assertEquals(1, request(token, endpoint, word + "\t10%_", 1, 20).path("total").asInt());
        assertEquals(0, request(token, endpoint, word + " 10__", 1, 20).path("total").asInt());
        MvcResult sourceFilter = mvc.perform(get(endpoint).header("Authorization", "Bearer " + token)
                .param("keyword", word).param("sourceType", "TRIAL")).andReturn();
        assertEquals(200, sourceFilter.getResponse().getStatus(), body(sourceFilter));
        assertEquals(0, json(sourceFilter).path("total").asInt());
    }

    @Test
    void progressSearchKeepsWholePlanQuantitiesSummaryAndNestedChildren() throws Exception {
        String token = adminToken(), word = numbers.nextNumber(DocNumberPrefix.PRODUCTION_PLAN);
        UUID goods = goods("G-" + UUID.randomUUID(), "看板货品", null), unit = unit();
        UUID prefix = plan(numbers.nextNumber(DocNumberPrefix.PRODUCTION_PLAN), word + "扩展", "2001-01-01", goods, unit);
        plan(word, "其他车间", "2001-01-02", goods, unit);
        UUID exact = plan(numbers.nextNumber(DocNumberPrefix.PRODUCTION_PLAN), word, "2001-01-03", goods, unit);
        UUID child = plan(numbers.nextNumber(DocNumberPrefix.PRODUCTION_PLAN), "子车间", "2001-01-04", goods, unit);
        jdbc.update("INSERT INTO subplan_links(plan_id,subplan_id) VALUES (?,?)", exact, child);
        JsonNode first = request(token, "/api/production/plans/progress", word, 1, 1);
        assertEquals(3, first.path("total").asInt());
        assertEquals(exact.toString(), first.path("items").get(0).path("planId").asText());
        assertEquals(30, first.path("items").get(0).path("totalQty").asInt());
        assertEquals(child.toString(), first.path("items").get(0).path("subplans").get(0).path("planId").asText());
        JsonNode second = request(token, "/api/production/plans/progress", word, 2, 1);
        assertEquals(prefix.toString(), second.path("items").get(0).path("planId").asText());
        JsonNode summary = request(token, "/api/production/plans/progress/summary", word, 1, 20);
        assertEquals(3, summary.path("count").asInt());
        assertEquals(90, summary.path("sumQty").asInt());
        String bill = numbers.nextNumber(DocNumberPrefix.PRODUCTION_PLAN);
        UUID literal = plan(bill, "车间10%_", "2001-01-05", goods, unit);
        JsonNode match = request(token, "/api/production/plans/progress", "10%_ " + bill, 1, 20);
        assertEquals(1, match.path("total").asInt());
        assertEquals(literal.toString(), match.path("items").get(0).path("planId").asText());
        assertEquals(0, request(token, "/api/production/plans/progress", "10__ " + bill, 1, 20).path("total").asInt());
    }

    private JsonNode request(String token, String endpoint, String keyword, int page, int size) throws Exception {
        MvcResult result = mvc.perform(get(endpoint).header("Authorization", "Bearer " + token)
                .param("keyword", keyword).param("page", Integer.toString(page)).param("size", Integer.toString(size))).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    private UUID goods(String code, String name, String spec) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,spec,code_sequence) VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                id, code, name, spec);
        return id;
    }

    private UUID unit() {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO units(id,code,name) VALUES (?,?,'件')", id, "U-" + id);
        return id;
    }

    private UUID analysis(UUID goods, UUID warehouse, UUID maker, String reference) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analyses(id,warehouse_id,status,fingerprint,initial_idempotency_key,maker_id)
                VALUES (?,?,'ACTIVE',?,?,?)
                """, id, warehouse, id.toString().replace("-", "").repeat(2), "analysis-search-" + id, maker);
        source(id, goods, reference, 10);
        return id;
    }

    private void source(UUID analysis, UUID goods, String reference, int quantity) {
        jdbc.update("""
                INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,source_ref,source_reason,requested_qty)
                VALUES (?,?,'OTHER',?,?,?,'查询回归来源',?)
                """, UUID.randomUUID(), analysis, goods, unit(), reference, quantity);
    }

    private String pendingOrder(UUID client, UUID unit, UUID goods, String date) {
        UUID order = UUID.randomUUID(); String bill = numbers.nextNumber(DocNumberPrefix.SALES_ORDER);
        jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,status,finance_confirmed) VALUES (?,?,CAST(? AS date),?,1,TRUE)",
                order, bill, date, client);
        jdbc.update("""
                INSERT INTO sales_order_items(id,bill_no,bill_date,order_id,goods_id,unit_id,unit_rate,qty,chain_status,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                SELECT ?,?,CAST(? AS date),?,id,?,1,10,1,code,name,'MASTER_AT_APPROVAL',now() FROM goods WHERE id=?
                """, UUID.randomUUID(), bill, date, order, unit, goods);
        return bill;
    }

    private UUID plan(String bill, String workshop, String date, UUID goods, UUID unit) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO production_plans(id,bill_no,bill_date,workshop_name,status) VALUES (?,?,CAST(? AS date),?,1)",
                id, bill, date, workshop);
        for (int line = 1; line <= 2; line++) {
            String productNo = jdbc.queryForObject("SELECT fn_allocate_production_product_no(?)", String.class, id);
            jdbc.update("""
                    INSERT INTO production_plan_items(id,bill_no,bill_date,plan_id,product_no,goods_id,unit_id,qty)
                    VALUES (?,?,CAST(? AS date),?,?,?,?,?)
                    """, UUID.randomUUID(), bill, date, id, productNo, goods, unit, line * 10);
        }
        return id;
    }
}
