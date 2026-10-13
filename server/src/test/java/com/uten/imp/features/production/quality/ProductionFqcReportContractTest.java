package com.uten.imp.features.production.quality;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.quality.ProductionFqcContracts.*;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.PostMapping;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

class ProductionFqcReportContractTest {
    @Test void rowsKeepTheExactOriginalLotAndInspectionHashesIncludingAutoQuantity() {
        UUID lot = UUID.randomUUID(), inspection = UUID.randomUUID();
        var lotRequest = new LotDecisionRequest(new BigDecimal("1.2500"), new BigDecimal("0.2500"),
                "REWORK", "返工恢复", "report-lot-original");
        var singleRequest = new DecisionRequest("PASS", null, null, null, null, "report-single-original");
        var normalized = ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(List.of(
                new ReportDecisionItem("LOT", lot, "PARTIAL", lotRequest.passQty(), lotRequest.failQty(),
                        lotRequest.dispositionCode(), lotRequest.reason(), lotRequest.idempotencyKey()),
                new ReportDecisionItem("INSPECTION", inspection, singleRequest.decision(), null, null,
                        null, null, singleRequest.idempotencyKey()))));
        assertEquals(ProductionFqcInspectionService.normalizeLotDecision(lot, lotRequest), normalized.getFirst().lot());
        assertEquals(ProductionFqcInspectionService.normalizeRequest(singleRequest), normalized.getLast().single());
        assertNull(normalized.getLast().single().requestedPassQty());
    }

    @Test void invalidOrRepeatedTargetsAndLotKeysFailBeforeWriting() {
        var row = new ReportDecisionItem("LOT", UUID.randomUUID(), "PASS", BigDecimal.ONE, BigDecimal.ZERO,
                null, null, "report-original-key");
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(null));
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(List.of())));
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(List.of(row, row))));
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(Collections.nCopies(101, row))));
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(List.of(
                row, new ReportDecisionItem("LOT", UUID.randomUUID(), "PASS", BigDecimal.ONE, BigDecimal.ZERO,
                null, null, row.idempotencyKey())))));
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(List.of(
                new ReportDecisionItem(null, UUID.randomUUID(), "PASS", BigDecimal.ONE, BigDecimal.ZERO,
                        null, null, "missing-target-type")))));
    }

    @Test void lotQuantitiesAndDispositionCannotBeSilentlyChangedByTheEnvelope() {
        UUID lot = UUID.randomUUID();
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(List.of(
                new ReportDecisionItem("LOT", lot, "PASS", BigDecimal.ONE, BigDecimal.ONE,
                        "REWORK", "不良返工", "mismatch-quantity")))));
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(List.of(
                new ReportDecisionItem("LOT", lot, null, BigDecimal.ONE, BigDecimal.ONE,
                        "REWORK", null, "missing-reason-key")))));
        assertThrows(ApiException.class, () -> ProductionFqcInspectionService.normalizeReport(new ReportDecisionRequest(List.of(
                new ReportDecisionItem("INSPECTION", lot, "PASS", BigDecimal.ONE, BigDecimal.ZERO,
                        null, null, "zero-is-not-auto-key")))));
    }

    @Test void reportHasItsOwnAuthenticatedAtomicControllerAndServiceBoundary() throws Exception {
        var controller = ProductionFqcInspectionController.class.getDeclaredMethod("decideReport", ReportDecisionRequest.class);
        assertArrayEquals(new String[]{"/decisions/report"}, controller.getAnnotation(PostMapping.class).value());
        var service = ProductionFqcInspectionService.class.getDeclaredMethod("decideReport", ReportDecisionRequest.class);
        for (var method : List.of(controller, service)) {
            String security = method.getAnnotation(PreAuthorize.class).value();
            assertTrue(security.contains("production_quality_inspection:view"));
            assertTrue(security.contains("production_quality_inspection:approve"));
        }
        assertNotNull(service.getAnnotation(Transactional.class));
    }
}
