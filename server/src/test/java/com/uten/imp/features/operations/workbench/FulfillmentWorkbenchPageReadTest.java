package com.uten.imp.features.operations.workbench;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class FulfillmentWorkbenchPageReadTest {
    @Test void countsAndNullBucketsRetainIntegersBeyondJavascriptPrecision() {
        long large = 9_007_199_254_740_993L;
        assertEquals(large, FulfillmentWorkbenchPageRead.counts("{\"COMPLETED\":" + large + "}").get("COMPLETED"));
        var facets = FulfillmentWorkbenchPageRead.facets(
                "[[\"docNo\",null,null," + large + "],[\"goods\",\"id\",\"货品\",2]]");
        assertEquals(large, facets.nullCounts().get("docNo"));
        assertEquals("货品", facets.values().get("goods").getFirst().label());
        assertEquals(2L, facets.values().get("goods").getFirst().count());
    }

    @Test void invalidMetadataFailsRatherThanPublishingInventedZeroCounts() {
        assertThrows(IllegalStateException.class, () -> FulfillmentWorkbenchPageRead.counts("["));
        assertThrows(IllegalArgumentException.class, () -> FulfillmentWorkbenchPageRead.facets(null));
    }
}
