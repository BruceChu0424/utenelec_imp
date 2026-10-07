package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProductionOverLimitDispositionJsonTest {
    @Test void newReportAndWorkbenchFactsHaveExactTextWithoutChangingOldNumericFields() throws Exception {
        var mapper=new ObjectMapper().findAndRegisterModules();
        for(String quantity:List.of("9999999999999.9999","0.0001")) {
            var amount=new BigDecimal(quantity);
            var report=new ActualOutputSupplementContracts.ReportLinePreview(0,UUID.randomUUID(),null,
                    amount,BigDecimal.ZERO,amount,BigDecimal.ZERO,false,"proof",BigDecimal.ZERO,BigDecimal.ZERO,
                    BigDecimal.ZERO,amount);
            var reported=mapper.readTree(mapper.writeValueAsString(report));
            assertEquals(quantity,reported.path("overLimitQty").textValue());
            assertEquals("0",reported.path("withinAuthorizationQty").textValue());
            assertEquals(quantity,reported.path("actualQtyExact").textValue());
            assertTrue(reported.path("actualQty").isNumber());
            var task=mapper.readValue("{\"overLimitPendingQty\":\""+quantity+"\"}",
                    com.uten.imp.features.production.execution.ProductionExecutionWorkbenchSegment.class);
            var workbench=mapper.readTree(mapper.writeValueAsString(task));
            assertEquals(quantity,workbench.path("overLimitPendingQtyExact").textValue());
            assertTrue(workbench.path("overLimitPendingQty").isNumber());
        }
    }

    @Test void allDispositionQuantityAndRateFieldsKeepTheirOriginalDecimalText() throws Exception {
        var mapper=new ObjectMapper();
        for(String quantity:List.of("9999999999999.9999","0.0001")) {
            var amount=new BigDecimal(quantity);
            var view=new ProductionOverLimitDispositionContracts.View(UUID.randomUUID(),"PENDING",7,
                    UUID.randomUUID(),"REPORT",UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),"SEGMENT",
                    UUID.randomUUID(),"PLAN","CODE","GOODS","COLOR","UNIT",amount,new BigDecimal("0.123456"),
                    amount,BigDecimal.ZERO,amount,"实际超限",null,null,null,null,true,null,List.of());
            // Detail and decision responses use View; list rows must preserve the same contract.
            var detail=mapper.readTree(mapper.writeValueAsString(view));
            var listed=mapper.readTree(mapper.writeValueAsString(Map.of("items",List.of(view)))).path("items").get(0);
            for(var payload:List.of(detail,listed)) {
                for(String field:List.of("plannedQty","actualBatchQty","overLimitQty")) {
                    assertTrue(payload.path(field).isTextual(),field+" must not cross a JSON-number/double boundary");
                    assertEquals(quantity,payload.path(field).textValue());
                }
                assertEquals("0",payload.path("withinAuthorizationQty").textValue());
                assertEquals("0.123456",payload.path("allowedRate").textValue());
                assertEquals(7,payload.path("rowVersion").asLong());
            }
        }
    }
}
