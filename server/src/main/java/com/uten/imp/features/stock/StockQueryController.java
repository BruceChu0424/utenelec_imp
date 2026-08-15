package com.uten.imp.features.stock;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.dto.BalanceRow;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import com.uten.imp.features.stock.dto.MovementRow;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 库存查询 API（库存管理，stock:view）：
 *
 * - GET /api/stock/balances?warehouseId=&goodsId=&page=&size= → 当前余额分页
 * - GET /api/stock/movements?warehouseId=&goodsId=&movementType=&dateFrom=&dateTo=&page=&size= → 出入库流水分页
 */
@RestController
@RequestMapping("/api/stock")
@RequiredArgsConstructor
public class StockQueryController {

    private final StockQueryService service;

    @GetMapping("/balances")
    @PreAuthorize("hasAuthority('stock:view')")
    public PageResponse<BalanceRow> balances(
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.balances(warehouseId, goodsId, page, size, sort, order);
    }

    @GetMapping("/movements")
    @PreAuthorize("hasAuthority('stock:view')")
    public PageResponse<MovementRow> movements(
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) Short movementType,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE_TIME) OffsetDateTime dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE_TIME) OffsetDateTime dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.movements(warehouseId, goodsId, movementType, dateFrom, dateTo, page, size, sort, order);
    }

    /**
     * 即时库存（对标老系统「即时库存」窗口，仓库管理 hub 入口）：
     * 货品+颜色 粒度聚合余额，左货品分类树（含子树）+ 仓库下拉 + 关键字过滤。
     *
     * GET /api/stock/instant-inventory?categoryId=&warehouseId=&includeDefective=&keyword=&page=&size=&sort=&order=
     */
    @GetMapping("/instant-inventory")
    @PreAuthorize("hasAuthority('stock:view')")
    public PageResponse<InstantInventoryRow> instantInventory(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(defaultValue = "true") boolean includeDefective,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.instantInventory(categoryId, warehouseId, includeDefective, keyword, page, size, sort, order);
    }

    /**
     * 即时库存左侧统一搜索定位：字段、删除口径与 instantInventory 完全一致，
     * 只返回命中货品所在分类 id，不下载全部库存行。
     */
    @GetMapping("/instant-inventory/search-category-ids")
    @PreAuthorize("hasAuthority('stock:view')")
    public List<UUID> instantInventorySearchCategoryIds(
            @RequestParam String keyword,
            @RequestParam Set<UUID> categoryRootIds) {
        return service.instantInventoryMatchingCategoryIds(keyword, categoryRootIds);
    }
}
