package com.uten.imp.features.stock;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

class StockDrawIssueBatchReceiptsTest {
    @Test void normalizationIgnoresOrderDuplicatesWhitespaceAndEquivalentWeightScale() {
        UUID first = UUID.randomUUID(), last = UUID.randomUUID(), item = UUID.randomUUID();
        var a = request(List.of(first, last, first), " 夜班发料 ",
                List.of(new StockDocIssueBatchRequest.ItemWeight(item, new BigDecimal("2.5000"), null)));
        var b = request(List.of(last, first), "夜班发料",
                List.of(new StockDocIssueBatchRequest.ItemWeight(item, new BigDecimal("2.5"), false)));
        a.setIdempotencyKey("  canonical-key-1  ");
        var normalized = StockDrawIssueBatchReceipts.normalize(a);
        assertEquals(StockDrawIssueBatchReceipts.normalize(b), normalized);
        assertEquals(2, normalized.documents().size());
        assertEquals("canonical-key-1", normalized.key());
        assertEquals("夜班发料", normalized.reason());
        assertEquals(64, normalized.hash().length());
    }

    @Test void everyMaterialIntentFieldParticipatesInTheFingerprint() {
        UUID first = UUID.randomUUID(), last = UUID.randomUUID(), item = UUID.randomUUID();
        var base = request(List.of(first), "发料", List.of(new StockDocIssueBatchRequest.ItemWeight(item, BigDecimal.ONE, false)));
        String expected = StockDrawIssueBatchReceipts.normalize(base).hash();
        for (var changed : List.of(
                request(List.of(last), "发料", base.getWeights()),
                request(List.of(first, last), "发料", base.getWeights()),
                request(List.of(first), "另一备注", base.getWeights()),
                request(List.of(first), "发料", List.of(new StockDocIssueBatchRequest.ItemWeight(item, BigDecimal.TEN, false))),
                request(List.of(first), "发料", List.of(new StockDocIssueBatchRequest.ItemWeight(item, BigDecimal.ONE, true))),
                request(List.of(first), "发料", List.of(new StockDocIssueBatchRequest.ItemWeight(last, BigDecimal.ONE, false))))) {
            assertNotEquals(expected, StockDrawIssueBatchReceipts.normalize(changed).hash());
        }
    }

    @Test void emptyWeightsAreSemanticallyAbsentButDuplicateRowsRemainInvalid() {
        UUID document = UUID.randomUUID(), item = UUID.randomUUID();
        var absent = StockDrawIssueBatchReceipts.normalize(request(List.of(document), null, null));
        var zero = request(List.of(document), "  ",
                List.of(new StockDocIssueBatchRequest.ItemWeight(item, BigDecimal.ZERO, null)));
        assertEquals(absent, StockDrawIssueBatchReceipts.normalize(zero));
        zero.setWeights(List.of(zero.getWeights().getFirst(), zero.getWeights().getFirst()));
        assertThrows(ApiException.class, () -> StockDrawIssueBatchReceipts.normalize(zero));
    }

    @Test void serviceBoundaryRejectsInvalidAndOversizedRequests() {
        assertThrows(ApiException.class, () -> StockDrawIssueBatchReceipts.normalize(null));
        List<UUID> documents = new ArrayList<>();
        for (int i = 0; i < 51; i++) documents.add(UUID.randomUUID());
        assertThrows(ApiException.class, () -> StockDrawIssueBatchReceipts.normalize(request(documents, null, null)));
        assertThrows(ApiException.class, () -> StockDrawIssueBatchReceipts.normalize(request(List.of(UUID.randomUUID()), "长".repeat(201), null)));
        var request = request(List.of(UUID.randomUUID()), null, null);
        request.setIdempotencyKey("bad key !");
        assertThrows(ApiException.class, () -> StockDrawIssueBatchReceipts.normalize(request));
    }

    @Test void snapshotIncludesNullReasonAndCanonicalDetailsWithoutRetainingMutableClientCollections() {
        UUID document = UUID.randomUUID(), item = UUID.randomUUID();
        var ids = new ArrayList<>(List.of(document));
        var raw = request(ids, null, List.of(new StockDocIssueBatchRequest.ItemWeight(item, BigDecimal.ONE, true)));
        var command = StockDrawIssueBatchReceipts.normalize(raw);
        ids.clear();
        assertEquals(List.of(document), command.documents());
        assertThrows(UnsupportedOperationException.class, () -> command.documents().clear());
        assertThrows(UnsupportedOperationException.class, () -> command.weights().clear());
        var json = new ObjectMapper().valueToTree(command);
        assertTrue(json.get("reason").isNull());
        assertEquals(document.toString(), json.get("documents").get(0).asText());
        assertTrue(json.get("weights").get(item.toString()).get("qtyFromWeight").asBoolean());
    }

    private StockDocIssueBatchRequest request(List<UUID> documents, String reason,
                                              List<StockDocIssueBatchRequest.ItemWeight> weights) {
        var request = new StockDocIssueBatchRequest();
        request.setIdempotencyKey("canonical-key-1");
        request.setDocIds(documents);
        request.setReason(reason);
        request.setWeights(weights);
        return request;
    }
}
