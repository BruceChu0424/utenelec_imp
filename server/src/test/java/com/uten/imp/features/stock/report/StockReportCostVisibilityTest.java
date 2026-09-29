package com.uten.imp.features.stock.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
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
    private final SystemSettingsService settings = mock(SystemSettingsService.class);
    private final StockQueryService stockQueryService = mock(StockQueryService.class);
    private final StockCostMasker costMasker = mock(StockCostMasker.class);
    private StockReportService service;

    @BeforeEach
    void setUp() {
        service = new StockReportService(
                entityManager, settings, stockQueryService, costMasker);
        when(settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS)).thenReturn(100000);
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
                        "qty", "pendingQty", "moreQty")
                .doesNotContain("costAmount");
        assertThat(payload.rows()).allSatisfy(row -> assertThat(row).doesNotContainKey("costAmount"));
    }

    @Test
    void costPermissionRestoresCostColumnAndValue() {
        when(costMasker.canView()).thenReturn(true);

        ExportPayload payload =
                service.export("instant-inventory", Map.of(), null, null);

        assertThat(payload.columns()).extracting(ExportColumn::key)
                .contains("costAmount");
        assertThat(payload.columns())
                .filteredOn(column -> "costAmount".equals(column.key()))
                .singleElement()
                .extracting(ExportColumn::label)
                .isEqualTo("库存台账金额");
        assertThat(payload.rows().getFirst()).containsEntry("costAmount", new BigDecimal("123.45"));
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
        assertThat(kg.rows().get(0)).containsEntry("weight", new BigDecimal("2.5000")).containsEntry("weightStatus", "");
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
