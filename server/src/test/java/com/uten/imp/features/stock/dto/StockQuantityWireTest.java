package com.uten.imp.features.stock.dto;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.junit.jupiter.api.Assertions.*;

class StockQuantityWireTest {
    private final ObjectMapper mapper = new ObjectMapper()
            .enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);

    @Test void maximumStockQuantitiesKeepNumericCompatibilityAndEveryExactDigit() {
        BigDecimal qty = new BigDecimal("99999999999999.1234");
        JsonNode json = mapper.valueToTree(item(qty));
        for (String name : new String[]{"qty","countQty","surplusQty","unitRate","issuedQty","requestedQty","reportedQty","baseQty"}) {
            assertEquals(qty, json.get(name).decimalValue(), name);
            assertEquals(qty.toPlainString(), json.get(name + "Exact").textValue(), name);
        }
        assertFalse(json.has("price"));
        assertFalse(json.has("amountOriginal"));
        assertFalse(json.has("amountLocal"));
    }

    @Test void missingStockQuantityFactsStayNull() {
        JsonNode json = mapper.valueToTree(item(null));
        for (String name : new String[]{"qty","countQty","surplusQty","unitRate","issuedQty","requestedQty","reportedQty","baseQty"}) {
            assertTrue(json.get(name).isNull(), name);
            assertTrue(json.get(name + "Exact").isNull(), name);
        }
    }

    @Test void balanceQuantityHasTheSameLosslessCompanionWithoutChangingItsConstructor() {
        BigDecimal qty = new BigDecimal("99999999999999.1234");
        JsonNode json = mapper.valueToTree(new BalanceRow(null,null,null,null,qty,null,null,false,null,true));
        assertEquals(qty, json.get("qty").decimalValue());
        assertEquals(qty.toPlainString(), json.get("qtyExact").textValue());
        assertTrue(mapper.valueToTree(new BalanceRow(null,null,null,null,null,null,null,false,null,false)).get("qtyExact").isNull());
    }

    private static StockDocItemDto item(BigDecimal amount) {
        return new StockDocItemDto(
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                amount,
                amount,
                amount,
                amount,
                null,
                null,
                null,
                null,
                null,
                amount,
                amount,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                amount,
                false,
                amount,
                false,
                null,
                null,
                null,
                false);
    }
}
