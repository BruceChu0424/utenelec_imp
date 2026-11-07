package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.common.export.ExportRowSelection;
import com.uten.imp.common.export.TableColumnProjection;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class WarehouseTaskCenterOutputIdentityTest {
    @Test void repeatedGoodsOnOneDocumentSelectTheOriginalPhysicalLine() {
        var inbound = mock(WarehouseInboundTaskCenterQueryService.class);
        UUID id = UUID.randomUUID();
        var document = new WarehouseTaskCenterContracts.Row("PURCHASE:RECEIPT:" + id, id,
                "PURCHASE", "RECEIPT", "同一单号", null, null, null, null, null, 2,
                "DONE", "已入库", "neutral", "NONE", null, false, Map.of());
        var first = document.withLine(new WarehouseTaskCenterContracts.Line("line-1", UUID.randomUUID(),
                1, "G1", "重复货品", null, null, "个", BigDecimal.ONE, null));
        var second = document.withLine(new WarehouseTaskCenterContracts.Line("line-2", UUID.randomUUID(),
                2, "G1", "重复货品", null, null, "个", BigDecimal.ONE, null));
        when(inbound.list(any(), eq(false))).thenReturn(new WarehouseTaskCenterContracts.Page(
                List.of(first, second), 1, 100, 2, 1, Map.of()));
        var service = new WarehouseTaskCenterExportService(mock(WarehouseOutboundTaskCenterQueryService.class), inbound);
        var payload = service.inbound(new WarehouseTaskCenterContracts.Filter("ALL", null, null, null,
                null, null, null, 1, 100));
        verify(inbound).list(any(), eq(false));
        verify(inbound, never()).list(any());
        var projection = new TableColumnProjection("warehouse.tasks", null, List.of(),
                List.of(Map.of("rowKey", second.rowKey())));
        var selection = new ExportRowSelection(projection);
        var selected = selection.select(payload.columns(), payload.rows());
        selection.verifyComplete();
        assertThat(selected).hasSize(1);
        assertThat(selected.getFirst()).containsEntry("rowKey", second.rowKey()).containsEntry("goodsCode", "G1");
        assertThat(payload.columns()).noneMatch(column -> column.key().equals("rowKey"));
    }
}
