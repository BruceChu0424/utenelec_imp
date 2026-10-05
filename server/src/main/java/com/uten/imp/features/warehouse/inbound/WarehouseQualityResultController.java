package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskDetail;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskSummary;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService.TypeCounts;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 品质部检查结果合并页接口（/api/warehouse/quality-results）：按收货单聚合
 * 等待检查结果 / 全部合格待入库 / 部分合格 / 全部不合格需退回 / 已完结。
 * 只读聚合；确认入库与登记退回仍走各自权威命令接口。
 */
@RestController
@RequestMapping("/api/warehouse/quality-results")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('" + WarehouseQualityResultPermissions.STOCK_IN_VIEW + "')"
        + " or hasAuthority('" + WarehouseQualityResultPermissions.RETURN_VIEW + "')")
public class WarehouseQualityResultController {

    private final WarehouseQualityResultService service;
    private final com.uten.imp.application.port.WarehouseTaskScopePort warehouseScopes;

    @GetMapping
    public PageResponse<TaskSummary> list(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "ALL") String receiptType,
            @RequestParam(defaultValue = "") String status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 2026-09-25 单号列统一：sort/order 表头排序 + 收货单号表头值筛选。
        // ADR-149：服务端按本人仓库数据范围强制过滤(收货单仓或检验目标仓), 越界选仓 403。
        return service.list(keyword, receiptType, status, dateFrom, dateTo,
                page, size, sort, order, billNo, warehouseScopes.current(scopeWarehouseId));
    }

    /** 收货单号 facets（2026-09-25 单号列统一）：{billNo:[各收货单号]}——
     *  同列表过滤口径（不含 billNo 自身值筛选）。 */
    @GetMapping("/facets")
    public Map<String, List<Map<String, Object>>> facets(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "ALL") String receiptType,
            @RequestParam(defaultValue = "") String status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.facets(keyword, receiptType, status, dateFrom, dateTo,
                warehouseScopes.current(scopeWarehouseId));
    }

    /** 顶部状态分段计数（等待检查结果/全部合格/部分合格/需退回/已完结）。 */
    @GetMapping("/status-counts")
    public Map<String, Long> statusCounts(
            @RequestParam(defaultValue = "ALL") String receiptType,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.statusCounts(receiptType, keyword, warehouseScopes.current(scopeWarehouseId));
    }

    /**
     * 父分类(来源类型)分段的红黄两枚计数：红 actionable = 轮到仓库动手(待入库 + 需退回),
     * 黄 inProgress = 等待检查结果。页内三个数字只有这一个服务端来源, 两支不会各算各的。
     */
    @GetMapping("/type-counts")
    public TypeCounts typeCounts(@RequestParam(required = false) UUID scopeWarehouseId) {
        return service.typeCounts(warehouseScopes.current(scopeWarehouseId));
    }

    @GetMapping("/{receiptType}/{receiptId}")
    public TaskDetail detail(
            @PathVariable String receiptType,
            @PathVariable UUID receiptId) {
        return service.detail(receiptType, receiptId);
    }
}
