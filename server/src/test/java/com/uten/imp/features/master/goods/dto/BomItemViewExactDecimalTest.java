package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class BomItemViewExactDecimalTest {
    private final ObjectMapper json = new ObjectMapper();

    @Test void numericFieldsRemainCompatibleWhileTextCompanionsKeepEveryDecimalDigit() throws Exception {
        var view = view(new BigDecimal("1234567890123.12345"), new BigDecimal("12345678901234.5678"),
                new BigDecimal("9876543210.1234"), new BigDecimal("123456789012.123456"), new BigDecimal("0.00001000"));
        var serialized = json.readTree(json.writeValueAsBytes(view));

        for (String field : List.of("qty", "price", "total", "basisOutputQty", "unitWeightGrams")) {
            assertTrue(serialized.get(field).isNumber(), field + " must remain numeric for existing clients");
            assertTrue(serialized.get(field + "Text").isTextual());
        }
        assertEquals("1234567890123.12345", serialized.get("qtyText").asText());
        assertEquals("12345678901234.5678", serialized.get("priceText").asText());
        assertEquals("9876543210.1234", serialized.get("totalText").asText());
        assertEquals("123456789012.123456", serialized.get("basisOutputQtyText").asText());
        assertEquals("0.00001000", serialized.get("unitWeightGramsText").asText());
    }

    @Test void absentDecimalCompanionsStayNullInsteadOfBecomingZero() throws Exception {
        var serialized = json.readTree(json.writeValueAsBytes(view(null, null, null, null, null)));
        for (String field : List.of("qty", "price", "total", "basisOutputQty", "unitWeightGrams")) {
            assertTrue(serialized.get(field).isNull());
            assertTrue(serialized.get(field + "Text").isNull());
        }
    }

    private static BomItemView view(BigDecimal qty, BigDecimal price, BigDecimal total,
                                    BigDecimal basisOutputQty, BigDecimal unitWeightGrams) {
        return new BomItemView(UUID.randomUUID(), UUID.randomUUID(), "COMPONENT", "组件",
                null, null, null, null, null, null, null, null, null, qty, price, total,
                null, null, false, "采购", "START", "PER_UNIT", basisOutputQty, true, true,
                null, null, "ORDER", unitWeightGrams, List.of());
    }
}
