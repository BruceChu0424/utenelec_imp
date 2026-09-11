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

    /**
     * 货架目视化清单（仓库管理 → 货架目视化清单页：货架图 + 统一表格 / 打印张贴 / 导出）：
     * 货品主档已维护库位号的货品，库位号按「库行-层-位」三段解析并附即时库存参考量。
     *
     * GET /api/stock/shelf-labels?rack=&keyword=&warehouseId=&includeDisabled=
     *     → 行（库行/层/位/parsed/库位号/物料编码/系列/名称/颜色/单位/即时库存/disabled）
     * GET /api/stock/shelf-labels/racks?warehouseId=&includeDisabled=
     *     → 已分层库行（筛选下拉数据源；残值不含）
     * GET /api/stock/shelf-labels/layout?warehouseId=&includeDisabled=
     *     → [{rack, maxLevel, maxSlot, count}]（货架图布局；末尾 rack='' 为未分层桶，仅残值 > 0 时出现）
     *
     * warehouseId 非空：库位号本仓树偏好优先、库存按该仓及子仓汇总；空：只读主档、库存按全部核算仓汇总。
     * includeDisabled 默认 false（禁用货品不列）。
     */
    @GetMapping("/shelf-labels")
    @PreAuthorize("hasAuthority('stock:view')")
    public List<com.uten.imp.features.stock.dto.ShelfLabelRow> shelfLabels(
            @RequestParam(required = false) String rack,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(defaultValue = "false") boolean includeDisabled) {
        return service.shelfLabelRows(rack, keyword, warehouseId, includeDisabled);
    }

    @GetMapping("/shelf-labels/racks")
    @PreAuthorize("hasAuthority('stock:view')")
    public List<String> shelfLabelRacks(
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(defaultValue = "false") boolean includeDisabled) {
        return service.shelfLabelRacks(warehouseId, includeDisabled);
    }

    @GetMapping("/shelf-labels/layout")
    @PreAuthorize("hasAuthority('stock:view')")
    public List<com.uten.imp.features.stock.dto.ShelfLayoutRack> shelfLabelLayout(
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(defaultValue = "false") boolean includeDisabled) {
        return service.shelfLabelLayout(warehouseId, includeDisabled);
    }
}
