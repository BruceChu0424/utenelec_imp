package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProductionExecutionWorkbenchQuantityExactJsonTest {
    private final ObjectMapper mapper=new ObjectMapper().findAndRegisterModules();

    @Test void remainingCapacityCompanionKeepsEverySignificantDigitAndDoesNotTrustIncomingCompanions() throws Exception {
        var row=mapper.readValue("""
                {"remainingReportQty":90071992547409.1236,"remainingReportQtyExact":"0"}
                """,ProductionExecutionWorkbenchSegment.class);
        var body=mapper.readTree(mapper.writeValueAsBytes(row));
        assertTrue(body.path("remainingReportQty").isNumber());
        assertTrue(body.path("remainingReportQtyExact").isTextual());
        assertEquals("90071992547409.1236",body.path("remainingReportQtyExact").textValue());
        assertEquals(row.remainingReportQty(),row.remainingReportQtyExact());
        var small=mapper.readValue("{\"remainingReportQty\":0.0001}",ProductionExecutionWorkbenchSegment.class);
        assertEquals("0.0001",mapper.valueToTree(small).path("remainingReportQtyExact").textValue());
    }

    @Test void unknownCapacityRemainsExplicitNullRatherThanZero() throws Exception {
        var row=mapper.readValue("{}",ProductionExecutionWorkbenchSegment.class);
        var body=mapper.valueToTree(row);
        assertNull(row.remainingReportQty());assertNull(row.remainingReportQtyExact());
        assertTrue(body.has("remainingReportQtyExact"));assertTrue(body.path("remainingReportQtyExact").isNull());
    }
}
