package com.uten.imp.features.production.quality;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.quality.ProductionFqcRecordContracts.InspectionDecisionRecord;
import com.uten.imp.features.production.quality.ProductionFqcRecordContracts.InspectionDecisionRecordPage;
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

class ProductionFqcRecordContractTest {

    @Test
    void controllerExposesReadOnlyRecordRoutesWithFqcViewAuthority()
            throws Exception {
        RequestMapping root = ProductionFqcRecordController.class
                .getAnnotation(RequestMapping.class);
        assertThat(root.value())
                .containsExactly("/api/production/quality-inspections/records");

        var list = ProductionFqcRecordController.class.getMethod(
                "list", String.class, String.class,
                OffsetDateTime.class, OffsetDateTime.class,
                String.class, String.class, String.class,
                int.class, int.class);
        var detail = ProductionFqcRecordController.class.getMethod(
                "detail", UUID.class);
        assertThat(list.getAnnotation(GetMapping.class).value()).isEmpty();
        assertThat(detail.getAnnotation(GetMapping.class).value())
                .containsExactly("/{recordId}");
        assertThat(list.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('production_quality_inspection:view')");
        assertThat(detail.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('production_quality_inspection:view')");
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
                        "inspectorName", "decidedAt", "currentStatus", "effective",
                        // V547 品质检查单：记录行回带检查单号（同仓一次送检合并的单号），
                        // 品质检测记录页作为一列展示（2026-09-11）。
                        "sheetNo");
        assertThat(componentNames(InspectionDecisionRecordPage.class))
                .containsExactly(
                        "items", "page", "size", "total", "totalPages", "metrics");
    }

    @Test
    void filtersFailClosedAndKeepCanonicalPaging() {
        var filter = ProductionFqcRecordQueryService.normalizeFilter(
                " cancelled ", "  SCRB  ", null, null, null, null, null, 0, 500);
        assertThat(filter.decision()).isEqualTo("CANCELLED");
        assertThat(filter.keyword()).isEqualTo("scrb");
        assertThat(filter.page()).isEqualTo(1);
        assertThat(filter.size()).isEqualTo(100);

        assertThatThrownBy(() ->
                ProductionFqcRecordQueryService.normalizeFilter(
                        "UNKNOWN", "", null, null, null, null, null, 1, 40))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() ->
                ProductionFqcRecordQueryService.normalizeFilter(
                        "ALL", "",
                        OffsetDateTime.parse("2026-08-31T12:00:00Z"),
                        OffsetDateTime.parse("2026-08-30T12:00:00Z"),
                        null, null, null, 1, 40))
                .isInstanceOf(ApiException.class);
        // 表头筛选三列（2026-09-16）：合法值归一、空白不过滤、非法值 fail-closed。
        var columnFilter = ProductionFqcRecordQueryService.normalizeFilter(
                "ALL", "", null, null, " production ", " active ", " scrap ", 1, 40);
        assertThat(columnFilter.sourceType()).isEqualTo("PRODUCTION");
        assertThat(columnFilter.effective()).isEqualTo("ACTIVE");
        assertThat(columnFilter.disposition()).isEqualTo("SCRAP");
        assertThatThrownBy(() ->
                ProductionFqcRecordQueryService.normalizeFilter(
                        "ALL", "", null, null, "PURCHASE", null, null, 1, 40))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() ->
                ProductionFqcRecordQueryService.normalizeFilter(
                        "ALL", "", null, null, null, "MAYBE", null, 1, 40))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() ->
                ProductionFqcRecordQueryService.normalizeFilter(
                        "ALL", "", null, null, null, null, "DONATE", 1, 40))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void queryUnionsDecisionAndCancellationEventsUnderExistingOwnerScope()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcRecordQueryService.java"));
        assertThat(source)
                .contains("FROM production_fqc_decision_events decision_event")
                .contains("FROM production_fqc_cancellation_events cancellation")
                .contains("inspection.status <> 'CANCELLED' AS effective")
                .contains("'CANCELLED'::text AS decision")
                .contains("taskAccess.canAccessQualityPool()")
                .contains("productionAccess.nativeReadScope(")
                .contains("\"record.owner_id\", \"fqcRecordOwners\"")
                .contains("inspection.report_maker_id AS owner_id")
                .doesNotContain("report.maker_id AS owner_id")
                .contains("GROUP BY record.decision")
                .contains("ORDER BY record.decided_at DESC, record.record_id DESC");
    }

    @Test
    void columnFiltersAreParameterizedPredicatesSharedByListAndMetrics()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcRecordQueryService.java"));
        // 表头三列（2026-09-16）全部走绑定参数等值；效力三档与列展示口径一致。
        assertThat(source)
                .contains("record.source_type = :sourceType")
                .contains("record.disposition_code = :disposition")
                .contains("\" AND record.effective AND record.decision <> 'CANCELLED'\"")
                .contains("\" AND NOT record.effective\"")
                .contains("\" AND record.decision = 'CANCELLED'\"");
    }

    private static List<String> componentNames(Class<?> recordType) {
        return Arrays.stream(recordType.getRecordComponents())
                .map(RecordComponent::getName)
                .toList();
    }
}
