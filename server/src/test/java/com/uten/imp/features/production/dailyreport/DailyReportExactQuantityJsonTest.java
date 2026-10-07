package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemDto;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportOutputAllocationLine;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.Arrays;

import static org.junit.jupiter.api.Assertions.*;

class DailyReportExactQuantityJsonTest {
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private static final String QUANTITY = "9999999999999.9999";

    @Test
    void directCandidateKeepsCapacityFactsInOriginalDecimalText() throws Exception {
        var candidate = mapper.readValue("""
                {"remainingQty":9999999999999.9999,"requiredQty":9999999999999.9999,"alreadyCoveredQty":0.0001}
                """, com.uten.imp.features.production.directtransfer.ProductionWorkshopDirectTransferService.Candidate.class);
        var json = mapper.valueToTree(candidate);
        assertEquals(QUANTITY, json.path("remainingQtyExact").textValue());
        assertEquals(QUANTITY, json.path("requiredQtyExact").textValue());
        assertEquals("0.0001", json.path("alreadyCoveredQtyExact").textValue());
    }

    @Test
    void reportContextKeepsQuantityDefectAndSixPlaceRateAndCannotTrustIncomingCompanions() throws Exception {
        var line = mapper.readValue("""
                {"qty":"9999999999999.9999","qtyExact":"1",
                 "defectQty":"0.0001","defectQtyExact":"999",
                 "unitRate":"0.000032","unitRateExact":"1",
                 "allocations":[{"qty":"9999999999999.9999","qtyExact":"2"}]}
                """, DailyReportItemLine.class);
        assertEquals(new BigDecimal(QUANTITY), line.getQty());
        var json = mapper.valueToTree(line);
        assertEquals(QUANTITY, json.path("qtyExact").textValue());
        assertEquals("0.0001", json.path("defectQtyExact").textValue());
        assertEquals("0.000032", json.path("unitRateExact").textValue());
        assertEquals(QUANTITY, json.path("allocations").get(0).path("qtyExact").textValue());
        var restored = mapper.readValue(mapper.writeValueAsBytes(line), DailyReportItemLine.class);
        assertEquals(line.getQty(), restored.getQty());
        assertEquals(line.getUnitRate(), restored.getUnitRate());
        assertEquals(new BigDecimal(QUANTITY), restored.getAllocations().getFirst().qty());
    }

    @Test
    void sourceDefaultsAndSupplementResponsesEmitExactOriginals() throws Exception {
        var source = mapper.readValue("""
                {"maxReportQty":9999999999999.9999,"unitRate":999999999999.999999}
                """, ReportablePlanLine.class);
        var sourceJson = mapper.valueToTree(source);
        assertEquals(QUANTITY, sourceJson.path("maxReportQtyExact").textValue());
        assertEquals("999999999999.999999", sourceJson.path("unitRateExact").textValue());
        for (Class<?> response : new Class<?>[]{ActualOutputSupplementContracts.Preview.class,
                ActualOutputSupplementContracts.View.class, ActualOutputSupplementContracts.RelatedSupplement.class}) {
            Object value = mapper.readValue("{\"actualQty\":" + QUANTITY + "}", response);
            assertEquals(QUANTITY, mapper.valueToTree(value).path("actualQtyExact").textValue(), response.getSimpleName());
        }
    }

    @Test
    void existingReportSlicesExposeOriginalBatchAndSliceQuantities() throws Exception {
        // The display DTO intentionally has an all-fields constructor; unrelated
        // identities stay null while the real getters/serializer are exercised.
        var constructor = DailyReportItemDto.class.getConstructors()[0];
        Object[] arguments = Arrays.stream(constructor.getParameterTypes())
                .map(type -> type == boolean.class ? Boolean.FALSE : null).toArray();
        var item = (DailyReportItemDto) constructor.newInstance(arguments);
        ReflectionTestUtils.setField(item, "qty", new BigDecimal(QUANTITY));
        ReflectionTestUtils.setField(item, "defectQty", new BigDecimal("0.0001"));
        ReflectionTestUtils.setField(item, "unitRate", new BigDecimal("0.000032"));
        item.setOutputBatchQty(new BigDecimal("99999999999999.9999"));
        var json = mapper.valueToTree(item);
        assertEquals(QUANTITY, json.path("qtyExact").textValue());
        assertEquals("99999999999999.9999", json.path("outputBatchQtyExact").textValue());
        assertEquals("0.0001", json.path("defectQtyExact").textValue());
        assertEquals("0.000032", json.path("unitRateExact").textValue());
        assertEquals(QUANTITY, mapper.valueToTree(DailyReportOutputAllocationLine.warehouse(
                new BigDecimal(QUANTITY))).path("qtyExact").textValue());
    }
}
