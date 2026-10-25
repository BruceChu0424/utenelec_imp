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

/** Real session/SQL regression for imported drafts leaking through the separate progress family. */
class SalesOrderProgressHistoryPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired private DocNumberService numbers;

    @Test void importsAreReadOnlyHistoryAcrossProgressFacetsAndAllTaskCounters() throws Exception {
        String token = adminToken(), keyword = "HistoryProgress" + UUID.randomUUID();
        UUID client = UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,code_sequence) VALUES (?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))",
                client, "CL-" + client, keyword);
        UUID nativeDraft = order(client, (short) 0, null);
        UUID nativePending = order(client, (short) 1, null);
        JsonNode nativeCounts = read(token, "/api/sales/orders/progress/stage-counts", "", "", "CURRENT");

        UUID oldDraft = order(client, (short) 0, 990001L);
        UUID oldApproved = order(client, (short) 1, 990002L);
        UUID oldReversed = order(client, (short) -1, 990003L);
        List<UUID> imported = List.of(oldDraft, oldApproved, oldReversed);
        List<String> originalRows = imported.stream().map(this::original).toList();

        JsonNode drafts = read(token, "/api/sales/orders/progress", keyword, "DRAFT", "CURRENT");
        assertEquals(1, drafts.path("total").asInt(), drafts.toString());
        assertEquals(nativeDraft.toString(), drafts.path("items").get(0).path("orderId").asText());
        assertFalse(drafts.path("items").get(0).path("historyReadOnly").asBoolean());
        JsonNode current = read(token, "/api/sales/orders/progress", keyword, "IN_PROGRESS", "CURRENT");
        assertEquals(1, current.path("total").asInt(), current.toString());
        assertEquals(nativePending.toString(), current.path("items").get(0).path("orderId").asText());
        JsonNode draftFacets = read(token, "/api/sales/orders/progress/facets", keyword, "DRAFT", "CURRENT");
        assertEquals(1, draftFacets.path("billNo").size(), draftFacets.toString());
        assertEquals(nativeCounts, read(token, "/api/sales/orders/progress/stage-counts", "", "", "ALL"),
                "even an ALL request cannot turn imported history into an action counter");

        JsonNode history = read(token, "/api/sales/orders/progress", keyword, "", "ALL");
        assertEquals(4, history.path("total").asInt(), history.toString());
        for (UUID id : imported) {
            JsonNode row = null;
            for (JsonNode candidate : history.path("items")) {
                if (id.toString().equals(candidate.path("orderId").asText())) row = candidate;
            }
            assertNotNull(row, "history must include raw draft and reversed imports: " + id);
            assertTrue(row.path("legacyImported").asBoolean(), row.toString());
            assertTrue(row.path("historyReadOnly").asBoolean(), row.toString());
            assertEquals("CLOSED", row.path("stage").asText(), row.toString());
            assertFalse(row.path("closed").asBoolean(), "the raw source closed flag was not fabricated");
        }
        JsonNode historyFacets = read(token, "/api/sales/orders/progress/facets", keyword, "", "ALL");
        assertEquals(4, historyFacets.path("billNo").size(), historyFacets.toString());
        JsonNode legacy = read(token, "/api/sales/orders/progress", keyword, "", "LEGACY");
        assertEquals(3, legacy.path("total").asInt(), legacy.toString());
        assertEquals(originalRows, imported.stream().map(this::original).toList(),
                "display classification must preserve complete original order rows");
    }

    private UUID order(UUID client, short status, Long legacy) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,status,finance_confirmed,legacy_id) VALUES (?,?,DATE '2026-10-01',?,?,?,?)",
                id, numbers.nextNumber(DocNumberPrefix.SALES_ORDER), client, status, status == 1, legacy);
        return id;
    }

    private String original(UUID id) {
        return jdbc.queryForObject("SELECT to_jsonb(o)::text FROM sales_orders o WHERE id=?", String.class, id);
    }

    private JsonNode read(String token, String path, String keyword, String stage, String origin) throws Exception {
        var response = mvc.perform(get(path).param("keyword", keyword).param("stage", stage)
                .param("originScope", origin).param("size", "100")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, response.getResponse().getStatus(), body(response));
        return json(response);
    }
}
