package com.uten.imp.features.stock.report;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

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
        when(settings.readInt("export_max_rows", 100000)).thenReturn(100000);
        when(stockQueryService.instantInventory(
                isNull(), isNull(), anyBoolean(), isNull(),
                anyInt(), anyInt(), isNull(), isNull()))
                .thenReturn(new PageResponse<>(List.of(row()), 1, 500, 1, 1));
    }

    @Test
    void unprivilegedExportRemovesCostColumnAndValue() {
        when(costMasker.canView()).thenReturn(false);

        ExportPayload payload =
                service.export("instant-inventory", Map.of(), null, null);

        assertThat(payload.columns()).extracting(column -> column.key())
                .contains("goodsCode", "series", "stockPlace", "weight",
                        "qty", "pendingQty", "moreQty")
                .doesNotContain("costAmount");
        assertThat(payload.rows()).singleElement()
                .satisfies(row -> assertThat(row).doesNotContainKey("costAmount"));
    }

    @Test
    void costPermissionRestoresCostColumnAndValue() {
        when(costMasker.canView()).thenReturn(true);

        ExportPayload payload =
                service.export("instant-inventory", Map.of(), null, null);

        assertThat(payload.columns()).extracting(column -> column.key())
                .contains("costAmount");
        assertThat(payload.columns())
                .filteredOn(column -> "costAmount".equals(column.key()))
                .singleElement()
                .extracting(column -> column.label())
                .isEqualTo("库存台账金额");
        assertThat(payload.rows()).singleElement()
                .satisfies(row -> assertThat(row)
                        .containsEntry("costAmount", new BigDecimal("123.45")));
    }

    private static InstantInventoryRow row() {
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
                new BigDecimal("2.5"),
                new BigDecimal("10"),
                new BigDecimal("123.45"),
                new BigDecimal("3"),
                "MAT-001",
                "五金件",
                "A-01",
                new BigDecimal("4"),
                false);
    }
}
