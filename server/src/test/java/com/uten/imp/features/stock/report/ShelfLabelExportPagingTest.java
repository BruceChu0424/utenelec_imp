package com.uten.imp.features.stock.report;

import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.dto.ShelfLabelRow;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ShelfLabelExportPagingTest {
    @Test void completeShelfExportUsesThePagedAuthorityAndDoesNotRetainAllRowsInTheSinkMode() {
        var stock = mock(StockQueryService.class);
        var settings = mock(SystemSettingsService.class);
        when(settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS)).thenReturn(100_000);
        UUID warehouse = UUID.randomUUID();
        when(stock.shelfLabelRowsPage(eq("A"), eq("物料"), eq(warehouse), eq(true), anyInt(), eq(500)))
                .thenAnswer(call -> {
                    int start = ((int) call.getArgument(4) - 1) * 500;
                    return IntStream.range(start, Math.min(1001, start + 500)).mapToObj(i -> new ShelfLabelRow(
                            UUID.randomUUID(), "A", "A-1-1", "C-" + i, "系列", "物料", "红", "件",
                            new BigDecimal("1.000000000000000001"), false, 1, 1, true,
                            warehouse, "实际仓库", null, "WAREHOUSE_MASTER")).toList();
                });
        var service = new StockReportService(mock(EntityManager.class), settings, stock, mock(StockCostMasker.class));
        List<ExportPayload> pages = new ArrayList<>();
        ExportPayload result;
        try (var ignored = ExportPageSink.open(pages::add)) {
            result = service.export("shelf-labels", Map.of("rack", "A", "keyword", "物料",
                    "warehouseId", warehouse.toString(), "includeDisabled", "true"), null, null);
        }
        assertThat(result.total()).isEqualTo(1001);
        assertThat(result.rows()).isEmpty();
        assertThat(pages).extracting(page -> page.rows().size()).containsExactly(500, 500, 1);
        assertThat(pages.getLast().rows().getFirst()).containsEntry("goodsCode", "C-1000")
                .containsEntry("warehouseName", "实际仓库")
                .containsEntry("qty", new BigDecimal("1.000000000000000001"));
        verify(stock, never()).shelfLabelRows(any(), any(), any(), anyBoolean());
    }
}
