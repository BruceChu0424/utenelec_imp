package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import org.springframework.beans.factory.annotation.Autowired;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Real HTTP, owner-scoped grouped SQL, literal word filtering, facets and ranking before paging. */
class SalesOrderProgressSearchPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired private DocNumberService numbers;
    @Test void progressRanksCustomerNamesAndSharesLiteralCompoundFilteringWithFacets() throws Exception {
        String token = adminToken(), word = nextBill();
        UUID exact = order(word, nextBill());
        UUID prefix = order(word + "后缀", nextBill());
        UUID contains = order("前" + word, nextBill());
        UUID bill = order("普通客户", word);
        List<UUID> ranked = List.of(exact, prefix, contains, bill);
        for (int index = 0; index < ranked.size(); index++) {
            JsonNode page = search(token, word, index + 1, 1);
            assertEquals(4, page.path("total").asInt(), page.toString());
            assertEquals(ranked.get(index).toString(), page.path("items").get(0).path("orderId").asText());
        }
        String exactBill = jdbc.queryForObject("SELECT bill_no FROM sales_orders WHERE id=?", String.class, exact);
        assertEquals(1, search(token, exactBill + " " + word, 1, 10).path("total").asInt());
        String literal = "M3_20%\\A" + word;
        UUID literalOrder = order("字面螺丝 " + literal, nextBill());
        order("字面螺丝 M3X20AZA" + word, nextBill());
        assertEquals(literalOrder.toString(), search(token, "字面螺丝 " + literal, 1, 10).path("items").get(0).path("orderId").asText());
        MvcResult facets = mvc.perform(get("/api/sales/orders/progress/facets").param("keyword", exactBill + " " + word)
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, facets.getResponse().getStatus(), body(facets));
        assertEquals(1, json(facets).path("billNo").size(), body(facets));
        assertEquals(0, search(token, word + " 不存在", 1, 10).path("total").asInt());
        assertEquals(401, mvc.perform(get("/api/sales/orders/progress").param("keyword", word)).andReturn().getResponse().getStatus());
    }
    private JsonNode search(String token, String keyword, int page, int size) throws Exception {
        MvcResult result = mvc.perform(get("/api/sales/orders/progress").param("keyword", keyword)
                .param("page", Integer.toString(page)).param("size", Integer.toString(size))
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }
    private String nextBill() { return numbers.nextNumber(DocNumberPrefix.SALES_ORDER); }

    private UUID order(String name, String bill) {
        UUID client = UUID.randomUUID(), order = UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,code_sequence) VALUES (?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))", client, "CL-" + client, name);
        jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,status,finance_confirmed) VALUES (?,?,DATE '2026-10-01',?,1,TRUE)", order, bill, client);
        return order;
    }
}
