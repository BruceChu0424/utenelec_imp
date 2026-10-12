package com.uten.imp.features.production.plan.dto;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PlanItemQuantityWireTest {
    private final ObjectMapper mapper = new ObjectMapper()
            .enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);

    @Test
    void maximumValuesKeepLegacyNumericPropertiesAndLosslessExactTexts() throws Exception {
        BigDecimal qty=new BigDecimal("99999999999999.1234");
        BigDecimal oqty=new BigDecimal("88888888888888.4321");
        JsonNode json=mapper.readTree(mapper.writeValueAsString(dto(qty,oqty)));
        assertTrue(json.path("qty").isNumber());
        assertTrue(json.path("oqty").isNumber());
        assertEquals(qty,json.path("qty").decimalValue());
        assertEquals(oqty,json.path("oqty").decimalValue());
        assertEquals(qty.toPlainString(),json.path("qtyExact").asText());
        assertEquals(oqty.toPlainString(),json.path("oqtyExact").asText());
    }

    @Test
    void missingQuantitiesRemainNullInNumericAndExactProperties() throws Exception {
        JsonNode json=mapper.readTree(mapper.writeValueAsString(dto(null,null)));
        for(String key:new String[]{"qty","oqty","qtyExact","oqtyExact"}) assertTrue(json.path(key).isNull(),key);
    }

    @Test
    void exactQuantityTextUsesFinitePlainNotationWithoutChangingTheValue() throws Exception {
        JsonNode json=mapper.readTree(mapper.writeValueAsString(dto(new BigDecimal("1E+12"),new BigDecimal("12.3400"))));
        assertEquals("1000000000000",json.path("qtyExact").asText());
        assertEquals("12.34",json.path("oqtyExact").asText());
        assertEquals(0,json.path("oqty").decimalValue().compareTo(new BigDecimal(json.path("oqtyExact").asText())));
    }

    @Test
    void theExistingServerQuantityGuardAcceptsFourPlacesAndRejectsFiveAndOverflow() {
        BigDecimal maximum=new BigDecimal("99999999999999.1234");
        assertEquals(maximum,FinancialExactAmount.quantity(maximum,"生产计划数量"));
        assertEquals(new BigDecimal("1.2345"),FinancialExactAmount.quantity(new BigDecimal("1.2345"),"生产计划数量"));
        assertThrows(ApiException.class,()->FinancialExactAmount.quantity(new BigDecimal("1.23456"),"生产计划数量"));
        assertThrows(ApiException.class,()->FinancialExactAmount.quantity(new BigDecimal("100000000000000"),"生产计划数量"));
    }

    private static PlanItemDto dto(BigDecimal qty,BigDecimal oqty) {
        return new PlanItemDto(
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                oqty,
                qty,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null);
    }
}
