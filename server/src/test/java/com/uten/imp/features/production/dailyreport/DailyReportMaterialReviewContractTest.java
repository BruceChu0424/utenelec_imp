package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.dailyreport.dto.*;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class DailyReportMaterialReviewContractTest {
    private final UUID report=UUID.randomUUID(), first=UUID.randomUUID(), second=UUID.randomUUID();
    @Test void actualUsageAndOptionalCountRespectNativeQuantityRangeAndKeepZeroValid() {
        var line=new DailyReportMaterialUsageLine();line.setDemandId(first);line.setQtyBase(new BigDecimal("99999999999999.9999"));
        assertDoesNotThrow(()->ProductionDailyReportService.requireValidMaterialLine(line));
        line.setQtyBase(BigDecimal.ZERO);assertDoesNotThrow(()->ProductionDailyReportService.requireValidMaterialLine(line));
        line.setQtyBase(new BigDecimal("100000000000000"));assertThrows(ApiException.class,()->ProductionDailyReportService.requireValidMaterialLine(line));
        line.setQtyBase(BigDecimal.ZERO);line.setCountedLeftoverQty(new BigDecimal("100000000000000"));
        assertThrows(ApiException.class,()->ProductionDailyReportService.requireValidMaterialLine(line));
    }
    @Test void compactHugeExponentCannotExpandBeforeCreateQuantityValidationOrChangeZeroCanonicalBytes() {
        var request=new DailyReportSaveRequest();var item=new DailyReportItemLine();item.setGoodsId(first);item.setQty(new BigDecimal("1E+1000000000"));request.setItems(List.of(item));
        assertTimeoutPreemptively(java.time.Duration.ofSeconds(2),()->assertThrows(ApiException.class,()->ProductionDailyReportService.createRequestHash(request)));
        item.setQty(BigDecimal.ONE);item.setWeight(new BigDecimal("0E+1000000000"));
        String zero=ProductionDailyReportService.createRequestHash(request);item.setWeight(BigDecimal.ZERO);
        assertEquals(zero,ProductionDailyReportService.createRequestHash(request));
    }
    @Test void v3RequiresVersionFingerprintAndCompleteDecisionContractWithoutPollutingOldProtocols() {
        var request=new DailyReportApproveRequest();request.setCommandVersion(3);request.setExpectedVersion(0L);
        assertThrows(ApiException.class,()->ProductionDailyReportService.approvalCommandVersion(request));
        request.setMaterialReviewFingerprint("a".repeat(64));request.setMaterialDecisions(List.of());
        assertEquals(3,ProductionDailyReportService.approvalCommandVersion(request));
        request.setCommandVersion(2);
        assertThrows(ApiException.class,()->ProductionDailyReportService.approvalCommandVersion(request));
        request.setMaterialReviewFingerprint(null);request.setMaterialDecisions(null);
        assertEquals(2,ProductionDailyReportService.approvalCommandVersion(request));
    }
    @Test void fingerprintVersionOrKeepToReturnChangeBindsANewCommandButRowOrderDoesNot() {
        var keep=List.of(new DailyReportMaterialDecision(first,"KEEP"),new DailyReportMaterialDecision(second,"RETURN"));
        String hash=ProductionDailyReportService.approveMaterialRequestHash(report,0L,"a".repeat(64),keep);
        assertEquals(hash,ProductionDailyReportService.approveMaterialRequestHash(report,0L,"a".repeat(64),keep.reversed()));
        assertNotEquals(hash,ProductionDailyReportService.approveMaterialRequestHash(report,1L,"a".repeat(64),keep));
        assertNotEquals(hash,ProductionDailyReportService.approveMaterialRequestHash(report,0L,"b".repeat(64),keep));
        assertNotEquals(hash,ProductionDailyReportService.approveMaterialRequestHash(report,0L,"a".repeat(64),
                List.of(new DailyReportMaterialDecision(first,"RETURN"),new DailyReportMaterialDecision(second,"RETURN"))));
    }
    @Test void missingDuplicateForeignAndBlockedReturnDecisionsAreRejected() {
        var review=new DailyReportMaterialReview(report,0,"a".repeat(64),List.of(row(first,true),row(second,false)));
        assertThrows(ApiException.class,()->DailyReportMaterialReviewService.normalizeDecisions(List.of(
                new DailyReportMaterialDecision(first,"KEEP"),new DailyReportMaterialDecision(first,"KEEP"))));
        assertThrows(ApiException.class,()->DailyReportMaterialReviewService.requireDecisions(review,List.of(new DailyReportMaterialDecision(first,"KEEP"))));
        assertThrows(ApiException.class,()->DailyReportMaterialReviewService.requireDecisions(review,List.of(
                new DailyReportMaterialDecision(first,"KEEP"),new DailyReportMaterialDecision(UUID.randomUUID(),"KEEP"))));
        assertThrows(ApiException.class,()->DailyReportMaterialReviewService.requireDecisions(review,List.of(
                new DailyReportMaterialDecision(first,"KEEP"),new DailyReportMaterialDecision(second,"RETURN"))));
        assertDoesNotThrow(()->DailyReportMaterialReviewService.requireDecisions(review,List.of(
                new DailyReportMaterialDecision(first,"RETURN"),new DailyReportMaterialDecision(second,"KEEP"))));
    }
    @Test void snapshotRoundTripsFullPrecisionAndNewReceiptKeepsItsOriginalProtection() throws Exception {
        var json=new ObjectMapper().findAndRegisterModules();
        var review=new DailyReportMaterialReview(report,7,"a".repeat(64),List.of(row(first,true)));
        var encoded=json.valueToTree(review);
        assertEquals("9999999999999.9999",encoded.path("rows").get(0).path("availableQtyExact").asText());
        assertEquals(review,json.readValue(json.writeValueAsBytes(review),DailyReportMaterialReview.class));
        var usage=new DailyReportMaterialUsageDto(UUID.randomUUID(),1,UUID.randomUUID(),first,UUID.randomUUID(),"HP001",
                UUID.randomUUID(),"M1","原料",null,"个",new BigDecimal("9999999999999.9999"),new BigDecimal("0.0001"));
        assertEquals("9999999999999.9999",json.valueToTree(usage).path("qtyBaseExact").asText());
        assertEquals("0.0001",json.valueToTree(usage).path("countedLeftoverQtyExact").asText());
        assertEquals("REVIEWED_MATERIAL_SNAPSHOT",new DailyReportApprovalReceipt(report,"review-key",3,7L,false,review.fingerprint()).getReviewProtection());
        assertEquals("REVIEWED_VERSION",new DailyReportApprovalReceipt(report,"review-key",2,7L,false).getReviewProtection());
    }
    private DailyReportMaterialReview.Row row(UUID demand,boolean canReturn) {
        return new DailyReportMaterialReview.Row(demand,UUID.randomUUID(),UUID.randomUUID(),"HP00001","M001","原料",null,"个",
                new BigDecimal("9999999999999.9999"),new BigDecimal("9999999999999.9998"),new BigDecimal("0.0001"),
                BigDecimal.ZERO,new BigDecimal("0.0001"),BigDecimal.ZERO,canReturn,null);
    }
}
