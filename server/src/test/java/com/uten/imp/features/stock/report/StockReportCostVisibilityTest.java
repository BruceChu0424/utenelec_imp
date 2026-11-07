package com.uten.imp.features.stock.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 即时库存导出: 成本列按 goods:cost:view 整列增减; 重量紧跟库存数量、整列一个导出单位 (默认千克)、
 * 估算/未称另列说明; 页面的全部筛选 (含线边仓开关与表头筛选) 原样进导出; 走只取行的查询。
 */
class StockReportCostVisibilityTest {

    private final EntityManager entityManager = mock(EntityManager.class);

    private final StockQueryService stockQueryService = mock(StockQueryService.class);
    private final StockCostMasker costMasker = mock(StockCostMasker.class);
    private StockReportService service;

    @BeforeEach
    void setUp() {
        service = new StockReportService(
                entityManager, stockQueryService, costMasker);

        when(stockQueryService.instantInventoryRows(
                any(StockQueryService.InstantInventoryFilter.class), anyInt(), anyInt(), isNull(), isNull()))
                .thenReturn(new PageResponse<>(List.of(
                        row(new BigDecimal("2.5000"), false),
                        row(new BigDecimal("1.2345"), true),
                        row(null, false)), 1, 500, 3, 1));
    }

    @Test
    void unprivilegedExportRemovesCostColumnAndValue() {
        when(costMasker.canView()).thenReturn(false);

        ExportPayload payload =
                service.export("instant-inventory", Map.of(), null, null);

        assertThat(payload.columns()).extracting(ExportColumn::key)
                .contains("goodsCode", "series", "stockPlace", "weight",
                        "qty", "pendingQty", "periodInQty", "periodOutQty", "closingQty")
                .doesNotContain("costAmount", "costPrice", "periodCostAmount", "moreQty");
        assertThat(payload.rows()).allSatisfy(row -> assertThat(row).doesNotContainKeys("costAmount", "costPrice", "periodCostAmount", "moreQty"));
    }

    @Test
    void defaultExportOrderMatchesTheSharedInventoryColumnContract() throws Exception {
        try (var input = getClass().getResourceAsStream("/contracts/instant-inventory-column-order.json")) {
            assertThat(input).isNotNull();
            var contract = new com.fasterxml.jackson.databind.ObjectMapper().readTree(input);
            var expected = java.util.stream.StreamSupport.stream(contract.path("columns").spliterator(), false)
                    .map(com.fasterxml.jackson.databind.JsonNode::asText).toList();
            var costs = java.util.stream.StreamSupport.stream(contract.path("costColumns").spliterator(), false)
                    .map(com.fasterxml.jackson.databind.JsonNode::asText).toList();
            var exportOnly = java.util.stream.StreamSupport.stream(contract.path("exportOnlyColumns").spliterator(), false)
                    .map(com.fasterxml.jackson.databind.JsonNode::asText).toList();
            for (boolean allowed : List.of(false, true)) {
                var keys = StockReportService.instantExportColumns(com.uten.imp.common.measure.WeightUnit.KG, allowed)
                        .stream().map(ReportColumn::key).toList();
                assertThat(keys.stream().filter(key -> !exportOnly.contains(key)).toList())
                        .containsExactlyElementsOf(expected.stream().filter(key -> allowed || !costs.contains(key)).toList());
                assertThat(keys.indexOf("weightStatus")).isEqualTo(keys.indexOf("weight") + 1);
            }
        }
    }

    @Test
    void forgedOrSavedCostProjectionCannotRestoreSensitiveExportColumns() throws Exception {
        when(costMasker.canView()).thenReturn(false);
        ExportPayload payload = service.export("instant-inventory", Map.of(), null, null);
        var projectionService = new com.uten.imp.common.export.ExportTableProjectionService(
                mock(com.uten.imp.common.platformcolumns.PlatformColumnService.class));
        for (String key : List.of("costPrice", "periodCostAmount", "costAmount")) {
            var request = new com.uten.imp.common.export.TableColumnProjection("inventory", "view_warehouse",
                    List.of(new com.uten.imp.common.export.TableColumnProjection.Column(key, "金额", 120d, "money", null)));
            assertThatThrownBy(() -> projectionService.project(payload.columns(), payload.rows(), request, "view_warehouse"))
                    .isInstanceOfSatisfying(ApiException.class,
                            error -> assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));
        }
        byte[] file = new com.uten.imp.common.export.XlsxExportService().build(payload.columns(), payload.rows());
        try (var workbook = new org.apache.poi.xssf.usermodel.XSSFWorkbook(new java.io.ByteArrayInputStream(file))) {
            var header = workbook.getSheetAt(0).getRow(0);
            for (var cell : header) assertThat(cell.getStringCellValue()).doesNotContain("成本", "多排");
        }
    }

    @Test
    void costPermissionRestoresCostColumnAndValue() {
        when(costMasker.canView()).thenReturn(true);

        ExportPayload payload =
                service.export("instant-inventory", Map.of(), null, null);

        assertThat(payload.columns()).extracting(ExportColumn::key)
                .contains("costPrice", "periodCostAmount");
        assertThat(payload.columns())
                .filteredOn(column -> "periodCostAmount".equals(column.key()))
                .singleElement()
                .extracting(ExportColumn::label)
                .isEqualTo("成本金额");
        assertThat(payload.rows().getFirst()).containsEntry("periodCostAmount", "请选择时间范围");
    }

    @Test
    void weightFollowsQuantityInOneExportUnitWithAStatusColumn() {
        when(costMasker.canView()).thenReturn(false);

        ExportPayload kg = service.export("instant-inventory", Map.of(), null, null);
        List<String> keys = kg.columns().stream().map(ExportColumn::key).toList();
        assertThat(keys.indexOf("weight")).isEqualTo(keys.indexOf("qty") + 1);
        assertThat(keys.indexOf("weightStatus")).isEqualTo(keys.indexOf("weight") + 1);
        assertThat(kg.columns()).filteredOn(c -> "weight".equals(c.key())).singleElement()
                .satisfies(c -> {
                    assertThat(c.label()).isEqualTo("库存重量(千克)");
                    assertThat(c.type()).isEqualTo(ExportColumn.NUMBER);
                });
        // 2026-11-04 显式精度选择契约（0aaffa3aa/d533807ca 范式）：导出重量完整保留（尾零剥离），按数值比较。
        assertThat((BigDecimal) kg.rows().get(0).get("weight")).isEqualByComparingTo("2.5");
        assertThat(kg.rows().get(0)).containsEntry("weightStatus", "");
        assertThat(kg.rows().get(1)).containsEntry("weightStatus", "估算");
        // 未知重量绝不写 0: 数值为空, 状态「未称」。
        assertThat(kg.rows().get(2)).containsEntry("weightStatus", "未称");
        assertThat(kg.rows().get(2).get("weight")).isNull();

        ExportPayload grams = service.export("instant-inventory", Map.of("weightUnit", "G"), null, null);
        assertThat(grams.columns()).filteredOn(c -> "weight".equals(c.key())).singleElement()
                .extracting(ExportColumn::label).isEqualTo("库存重量(克)");
        assertThat(grams.rows().get(1)).containsEntry("weight", new BigDecimal("1234.5"));

        // 文件不做自动单位: 前端把「自动」换成具体单位再传, AUTO 与不认识的单位一样 400。
        assertThatThrownBy(() -> service.export("instant-inventory", Map.of("weightUnit", "AUTO"), null, null))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.export("instant-inventory", Map.of("weightUnit", "stone"), null, null))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void exportCarriesEveryPageFilterIncludingLineSideAndHeaderFilters() {
        when(costMasker.canView()).thenReturn(false);
        UUID owning = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        UUID unit = UUID.randomUUID();

        service.export("instant-inventory", Map.of(
                "includeLineSide", "true", "includeDefective", "false", "keyword", "螺丝",
                "owningWarehouse", owning.toString(), "colorId", color.toString(), "series", "五金件",
                "unitId", unit.toString()), null, null);

        ArgumentCaptor<StockQueryService.InstantInventoryFilter> filter =
                ArgumentCaptor.forClass(StockQueryService.InstantInventoryFilter.class);
        verify(stockQueryService).instantInventoryRows(filter.capture(), anyInt(), anyInt(), isNull(), isNull());
        assertThat(filter.getValue().includeLineSide()).isTrue();
        assertThat(filter.getValue().includeDefective()).isFalse();
        assertThat(filter.getValue().keyword()).isEqualTo("螺丝");
        assertThat(filter.getValue().owningWarehouse()).isEqualTo(owning);
        assertThat(filter.getValue().colorId()).isEqualTo(color);
        assertThat(filter.getValue().series()).isEqualTo("五金件");
        assertThat(filter.getValue().unitId()).isEqualTo(unit);
    }

    @Test
    void documentReportWeightColumnsExportAsKilogramNumbers() {
        ExportColumn weight = StockReportService.exportColumn(
                new ReportColumn("weight", "重量", "weight", null));
        assertThat(weight.label()).isEqualTo("重量(千克)");
        assertThat(weight.type()).isEqualTo(ExportColumn.NUMBER);
        assertThat(StockReportService.exportColumn(ReportColumn.text("billNo", "单号")).type()).isEqualTo("text");
    }

    private static InstantInventoryRow row(BigDecimal weight, boolean estimated) {
        return new InstantInventoryRow(
                null,
                null,
                "五金",
                "M1",
                "C1",
                "螺丝",
                "S1",
                "银色",
                "件",
                "外购",
                weight,
                new BigDecimal("10"),
                new BigDecimal("123.45"),
                new BigDecimal("3"),
                "MAT-001",
                "五金件",
                "A-01",
                new BigDecimal("4"),
                BigDecimal.ZERO,
                estimated,
                weight == null,
                null,
                null,
                false);
    }
}
