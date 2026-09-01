package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskDetail;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskSummary;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

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

    @GetMapping
    public PageResponse<TaskSummary> list(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "ALL") String receiptType,
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size) {
        return service.list(keyword, receiptType, status, page, size);
    }

    /** 顶部状态分段计数（等待检查结果/全部合格/部分合格/需退回/已完结）。 */
    @GetMapping("/status-counts")
    public Map<String, Long> statusCounts(
            @RequestParam(defaultValue = "ALL") String receiptType,
            @RequestParam(defaultValue = "") String keyword) {
        return service.statusCounts(receiptType, keyword);
    }

    /** 合并页角标：未完结任务数（等待检查结果 + 待入库 + 需退回，全来源之和）。 */
    @GetMapping("/count")
    public Map<String, Long> count() {
        return Map.of("count", service.countPending());
    }

    /** 父分类（来源类型）分段计数：各来源未完结任务数（与页内分段徽章同口径）。 */
    @GetMapping("/type-counts")
    public Map<String, Long> typeCounts() {
        return service.pendingTypeCounts();
    }

    @GetMapping("/{receiptType}/{receiptId}")
    public TaskDetail detail(
            @PathVariable String receiptType,
            @PathVariable UUID receiptId) {
        return service.detail(receiptType, receiptId);
    }
}
