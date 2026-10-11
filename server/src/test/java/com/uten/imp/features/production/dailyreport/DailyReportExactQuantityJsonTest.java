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
                {"maxReportQty":9999999999999.9999,"unitRate":999999999999.999999,
                 "plannedQty":9999999999999.9999,"producedQty":0.0001,
                 "remainingActualSurplusQty":0.0001,"pendingSupplementQty":9999999999999.9999,
                 "remainingActualSurplusQtyExact":"999","plannedQtyExact":"1"}
                """, ReportablePlanLine.class);
        var sourceJson = mapper.valueToTree(source);
        assertEquals(QUANTITY, sourceJson.path("maxReportQtyExact").textValue());
        assertEquals("999999999999.999999", sourceJson.path("unitRateExact").textValue());
        assertEquals(QUANTITY, sourceJson.path("plannedQtyExact").textValue());
        assertEquals("0.0001", sourceJson.path("producedQtyExact").textValue());
        assertEquals("0.0001", sourceJson.path("remainingActualSurplusQtyExact").textValue());
        assertEquals(QUANTITY, sourceJson.path("pendingSupplementQtyExact").textValue());
        for (Class<?> response : new Class<?>[]{ActualOutputSupplementContracts.Preview.class,
                ActualOutputSupplementContracts.View.class, ActualOutputSupplementContracts.RelatedSupplement.class}) {
            Object value = mapper.readValue("{\"actualQty\":" + QUANTITY + "}", response);
            assertEquals(QUANTITY, mapper.valueToTree(value).path("actualQtyExact").textValue(), response.getSimpleName());
        }
    }

    @Test
    void materialCapacityAndUsageBasisKeepOriginalDecimalsAndMissingFactsStayNull() throws Exception {
        var row=mapper.readValue("""
                {"availableToSettleQty":9999999999999.9999,"requiredQty":9999999999999.9999,
                 "issuedQty":9999999999999.9999,"perProductQty":0.000001,"requiredForProductQty":0.0001,
                 "availableToSettleQtyExact":"1","perProductQtyExact":"999"}
                """, com.uten.imp.features.stock.allocation.dto.ProductionMaterialClearanceRow.class);
        var json=mapper.valueToTree(row);
        assertEquals(QUANTITY,json.path("availableToSettleQtyExact").textValue());
        assertEquals(QUANTITY,json.path("requiredQtyExact").textValue());
        assertEquals(QUANTITY,json.path("issuedQtyExact").textValue());
        assertEquals("0.000001",json.path("perProductQtyExact").textValue());
        assertEquals("0.0001",json.path("requiredForProductQtyExact").textValue());
        var missing=mapper.readValue("{}", com.uten.imp.features.stock.allocation.dto.ProductionMaterialClearanceRow.class);
        assertNull(missing.availableToSettleQtyExact());assertNull(missing.perProductQtyExact());
        var source=mapper.readValue("{}",ReportablePlanLine.class);
        assertNull(source.remainingActualSurplusQtyExact());assertNull(source.pendingSupplementQtyExact());
    }

    @Test
    void physicalBatchAndDestinationGroupsExposeExactTotalsAndOwnershipShares() throws Exception {
        var group=new com.uten.imp.features.production.dailyreport.dto.DailyReportOutputGroup(
                java.util.UUID.randomUUID(), java.util.List.of(java.util.UUID.randomUUID()), "WAREHOUSE", null, null,
                new BigDecimal(QUANTITY),new BigDecimal("9999999999999.9998"),BigDecimal.ZERO,new BigDecimal("0.0001"),null,null,null);
        var batch=new com.uten.imp.features.production.dailyreport.dto.DailyReportOutputBatch(
                java.util.UUID.randomUUID(),group.itemIds().getFirst(),group.itemIds(),new BigDecimal(QUANTITY),null,java.util.List.of(group));
        var json=mapper.valueToTree(batch);var destination=json.path("groups").get(0);
        assertEquals(QUANTITY,json.path("qtyExact").textValue());assertEquals(QUANTITY,destination.path("qtyExact").textValue());
        assertEquals("9999999999999.9998",destination.path("demandQtyExact").textValue());
        assertEquals("0",destination.path("publicQtyExact").textValue());assertEquals("0.0001",destination.path("actualSurplusQtyExact").textValue());
        var replay=mapper.readValue(mapper.writeValueAsBytes(batch),com.uten.imp.features.production.dailyreport.dto.DailyReportOutputBatch.class);
        assertEquals(batch,replay);
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
