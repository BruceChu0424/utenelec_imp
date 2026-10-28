package com.uten.imp.features.master.goods.importing;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

class GoodsImportReviewExactDecimalTest {
    private final ObjectMapper json = new ObjectMapper();

    @Test void adjacentLargeDecimalChangesRemainExactTextOnBothSidesOfTheJsonBoundary() throws Exception {
        var change = new GoodsImportReviewRow.Change("price", "价格",
                new BigDecimal("12345678901234.1234"), new BigDecimal("12345678901234.1235"), "CONFLICT");

        var serialized = json.readTree(json.writeValueAsBytes(change));

        assertTrue(serialized.path("oldValue").isTextual());
        assertTrue(serialized.path("newValue").isTextual());
        assertEquals("12345678901234.1234", serialized.path("oldValue").asText());
        assertEquals("12345678901234.1235", serialized.path("newValue").asText());
    }

    @Test void fractionalScaleAndTrailingZerosArePreservedInPlainDecimalText() throws Exception {
        var change = new GoodsImportReviewRow.Change("minOrderQty", "最小起订量",
                new BigDecimal("35.3000"), new BigDecimal("0.00001000"), "CONFLICT");

        assertEquals("35.3000", change.oldValue());
        assertEquals("0.00001000", change.newValue());
        var serialized = json.readTree(json.writeValueAsBytes(change));
        assertEquals("35.3000", serialized.path("oldValue").asText());
        assertEquals("0.00001000", serialized.path("newValue").asText());
    }

    @Test void nullAndExplicitTextRemainUnchanged() throws Exception {
        String text = " 00123.4000 ";
        var change = new GoodsImportReviewRow.Change("name", "货品名称", null, text, "FILL");

        assertNull(change.oldValue());
        assertSame(text, change.newValue());
        var serialized = json.readTree(json.writeValueAsBytes(change));
        assertTrue(serialized.path("oldValue").isNull());
        assertEquals(text, serialized.path("newValue").asText());
    }

    @Test void nonDecimalValuesKeepTheirOriginalTypes() throws Exception {
        Integer previous = 7;
        var change = new GoodsImportReviewRow.Change("other", "其他", previous, Boolean.TRUE, "CONFLICT");

        assertSame(previous, change.oldValue());
        assertSame(Boolean.TRUE, change.newValue());
        var serialized = json.readTree(json.writeValueAsBytes(change));
        assertTrue(serialized.path("oldValue").isIntegralNumber());
        assertTrue(serialized.path("newValue").isBoolean());
    }
}
