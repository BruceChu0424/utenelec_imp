package com.uten.imp.features.stock.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.mockito.ArgumentCaptor;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Warehouse master exports retain the same physical stock scope through every query page. */
class StockReportWarehouseInventoryScopeTest {

    @ParameterizedTest
    @CsvSource(value = {"true,true", "TRUE,true", "false,false", "NULL,false"}, nullValues = "NULL")
    void exportPreservesWarehouseScopeAndOwningWarehouseColumnAcrossPages(String related, boolean expectedRelated) {
        UUID warehouse = UUID.randomUUID();
        var settings = mock(SystemSettingsService.class);
        var query = mock(StockQueryService.class);
        var service = new StockReportService(mock(EntityManager.class), settings, query, mock(StockCostMasker.class));
        when(settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS)).thenReturn(1000);
        var row = mock(InstantInventoryRow.class);
        when(row.getOwningWarehouseName()).thenReturn("主档归属仓");
        when(query.instantInventoryRows(any(), anyInt(), eq(500), eq("name"), eq("asc")))
                .thenReturn(new PageResponse<>(Collections.nCopies(500, row), 1, 500, 501, 2))
                .thenReturn(new PageResponse<>(List.of(row), 2, 500, 501, 2));
        var params = new LinkedHashMap<String, String>();
        params.put("warehouseId", warehouse.toString());
        if (related != null) params.put("warehouseRelatedOnly", related);

        var payload = service.export("instant-inventory", params, "name", "asc");

        var filters = ArgumentCaptor.forClass(StockQueryService.InstantInventoryFilter.class);
        var pages = ArgumentCaptor.forClass(Integer.class);
        verify(query, times(2)).instantInventoryRows(filters.capture(), pages.capture(), eq(500), eq("name"), eq("asc"));
        assertThat(pages.getAllValues()).containsExactly(1, 2);
        assertThat(filters.getAllValues()).allSatisfy(filter -> {
            assertThat(filter.warehouseId()).isEqualTo(warehouse);
            assertThat(filter.warehouseRelatedOnly()).isEqualTo(expectedRelated);
        });
        assertThat(payload.total()).isEqualTo(501);
        assertThat(payload.columns()).filteredOn(column -> column.key().equals("owningWarehouse"))
                .singleElement().satisfies(column -> {
                    assertThat(column.label()).isEqualTo("归属仓库");
                    assertThat(column.type()).isEqualTo(ExportColumn.TEXT);
                });
        assertThat(payload.rows()).allSatisfy(value -> assertThat(value).containsEntry("owningWarehouse", "主档归属仓"));
    }
}
