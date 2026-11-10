package com.uten.imp.features.stock;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 即时库存完整流（POST /api/stock/instant-inventory/summaries?complete=true）的请求体：
 * 与 GET /instant-inventory 同一套筛选口径，首批 50 行带合计与表头桶，续批按共享批次
 * 计划在同一个响应里连续分帧（2026-11-09：替代每批一次 OFFSET 请求的完整读取）。
 */
public record InstantInventoryCompleteRequest(
        @Valid @NotNull Filter filter,
        Integer page,
        Integer size,
        String sort,
        String order) {

    public record Filter(
            UUID categoryId,
            UUID warehouseId,
            Boolean includeDefective,
            Boolean includeLineSide,
            String keyword,
            UUID owningWarehouse,
            Boolean owningWarehouseNull,
            UUID colorId,
            String series,
            UUID unitId,
            String attention,
            Boolean includeRelated,
            Boolean warehouseRelatedOnly,
            LocalDate dateFrom,
            LocalDate dateTo) { }

    public int requestedPage() { return page == null ? 1 : page; }

    /** 契约与主档摘要一致：默认固定帧 100，完整流请求共享批次计划的最大批。 */
    public int requestedSize() {
        return size == null
                ? com.uten.imp.common.readsnapshot.MasterSummaryReadSupport.READ_BATCH_SIZE
                : size;
    }
}
