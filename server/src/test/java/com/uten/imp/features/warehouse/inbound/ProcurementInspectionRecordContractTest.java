package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionRecordContracts.InspectionDecisionRecord;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionRecordContracts.InspectionDecisionRecordPage;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.RecordComponent;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProcurementInspectionRecordContractTest {

    @Test
    void controllerExposesReadOnlyRecordRoutesWithIqcViewAuthority()
            throws Exception {
        RequestMapping root = ProcurementInspectionRecordController.class
                .getAnnotation(RequestMapping.class);
        assertThat(root.value())
                .containsExactly("/api/procurement/inspection/records");

        var list = ProcurementInspectionRecordController.class.getMethod(
                "list", String.class, String.class,
                OffsetDateTime.class, OffsetDateTime.class,
                int.class, int.class);
        var detail = ProcurementInspectionRecordController.class.getMethod(
                "detail", UUID.class);
        assertThat(list.getAnnotation(GetMapping.class).value()).isEmpty();
        assertThat(detail.getAnnotation(GetMapping.class).value())
                .containsExactly("/{recordId}");
        assertThat(list.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('procurement_inspection:view')");
        assertThat(detail.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('procurement_inspection:view')");
    }

    @Test
    void responseShapeMatchesTheSharedQualityRecordContract() {
        assertThat(componentNames(InspectionDecisionRecord.class))
                .containsExactly(
                        "recordId", "domain", "sourceType", "inspectionId",
                        "sourceId", "sourceItemId", "sourceNo", "sourceDate",
                        "referenceNo", "partnerId", "partnerName", "warehouseId",
                        "warehouseName", "goodsId", "goodsCode", "goodsName",
                        "colorId", "colorName", "unitId", "unitName",
                        "inspectedQty", "currentPassedQty", "currentFailedQty",
                        "currentRemainingQty", "decision", "passQty", "failQty",
                        "dispositionCode", "reason", "inspectorEmployeeId",
                        "inspectorName", "decidedAt", "currentStatus", "effective");
        assertThat(componentNames(InspectionDecisionRecordPage.class))
                .containsExactly(
                        "items", "page", "size", "total", "totalPages", "metrics");
    }

    @Test
    void filtersFailClosedAndKeepCanonicalPaging() {
        var filter = ProcurementInspectionRecordQueryService.normalizeFilter(
                " pass ", "  ABC  ", null, null, 0, 500);
        assertThat(filter.decision()).isEqualTo("PASS");
        assertThat(filter.keyword()).isEqualTo("abc");
        assertThat(filter.page()).isEqualTo(1);
        assertThat(filter.size()).isEqualTo(100);

        assertThatThrownBy(() ->
                ProcurementInspectionRecordQueryService.normalizeFilter(
                        "UNKNOWN", "", null, null, 1, 40))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() ->
                ProcurementInspectionRecordQueryService.normalizeFilter(
                        "ALL", "",
                        OffsetDateTime.parse("2026-08-31T12:00:00Z"),
                        OffsetDateTime.parse("2026-08-30T12:00:00Z"),
                        1, 40))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void queryUsesDecisionEventsAndPreservesReversalSemantics()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementInspectionRecordQueryService.java"));
        assertThat(source)
                .contains("event.action IN ('PASS', 'FAIL', 'RECEIPT_REVERSED')")
                .contains("WHEN 'RECEIPT_REVERSED' THEN 'CANCELLED'")
                .contains("ELSE inspection.status <> 'REVERSED'")
                .contains("GROUP BY record.decision")
                .contains("ORDER BY record.decided_at DESC, record.record_id DESC")
                .doesNotContain("received_amount_local");
    }

    private static List<String> componentNames(Class<?> recordType) {
        return Arrays.stream(recordType.getRecordComponents())
                .map(RecordComponent::getName)
                .toList();
    }
}
