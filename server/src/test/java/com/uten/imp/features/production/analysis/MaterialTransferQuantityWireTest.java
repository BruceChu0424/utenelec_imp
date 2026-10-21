package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class MaterialTransferQuantityWireTest {
    private final ObjectMapper json = new ObjectMapper();
    @Test void candidatesExposeOriginalDecimalCapacities() throws Exception {
        String maximum = "99999999999999.9999";
        var row = new MaterialAnalysisContracts.CrossReallocationCandidate(UUID.randomUUID(), 4, "cas", UUID.randomUUID(),
                UUID.randomUUID(), "warehouse", "analysis", "product", null, new BigDecimal(maximum), new BigDecimal("0.0001"));
        var value = json.readTree(json.writeValueAsString(row));
        assertEquals(maximum, value.path("quantityFactsExact").path("sourceLendableQty").asText());
        assertEquals("0.0001", value.path("quantityFactsExact").path("shortageQty").asText());
        var future = json.readValue("{\"availableQty\":\"" + maximum + "\",\"receivedQty\":\"0.0001\",\"targetUncoveredQty\":\"" + maximum + "\"}", PreplanFutureSupplyTransfer.Source.class);
        var serialized = json.readTree(json.writeValueAsString(future));
        assertEquals(maximum, serialized.path("quantityFactsExact").path("availableQty").asText());
        assertEquals("0.0001", serialized.path("quantityFactsExact").path("receivedQty").asText());
    }
    @Test void decimalTextCommandsBindToTheExactBigDecimal() throws Exception {
        for (String quantity : new String[]{"0.0001", "1.2345", "99999999999999.9999", "90071992547409.0001"}) {
            String body = "{\"qty\":\"" + quantity + "\",\"sourceVersion\":4,\"targetVersion\":7}";
            var create = json.readValue(body, PreplanFutureSupplyTransfer.Create.class);
            var cancel = json.readValue(body, PreplanFutureSupplyTransfer.Cancel.class);
            var cross = json.readValue(body, MaterialAnalysisContracts.CrossReallocationRequest.class);
            assertEquals(quantity, create.qty().toPlainString());
            assertEquals(quantity, cancel.qty().toPlainString());
            assertEquals(quantity, cross.qty().toPlainString());
            assertEquals(4L, create.sourceVersion());
            assertEquals(7L, create.targetVersion());
        }
    }
}
