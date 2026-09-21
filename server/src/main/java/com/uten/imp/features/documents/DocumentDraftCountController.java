package com.uten.imp.features.documents;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * 跨模块草稿计数接口（{@code /api/documents}）。
 *
 * <p>只读、只返回聚合数字，不泄露任何单据内容；每个类型的可见性由
 * {@link DocumentDraftCountQueryService} 按 {@code *:view} 权限 + 对象级归属范围二次把关，
 * 因此接口本身只要求「已登录」。前端 {@code draftCountsProvider} 60s 轮询本端点。
 */
@RestController
@RequestMapping("/api/documents")
@RequiredArgsConstructor
public class DocumentDraftCountController {

    private final DocumentDraftCountQueryService queryService;
    private final DocumentStatusCountQueryService statusCounts;

    @GetMapping("/drafts/count")
    @PreAuthorize("isAuthenticated()")
    public DraftCountsResponse draftCounts() {
        return queryService.counts();
    }

    /**
     * 单据列表页分段计数(2026-09-21「父有红徽章, 子分段也要有数」): 按单据类型返回
     * DRAFT / PENDING_FINANCE / FINANCE_REJECTED / APPROVED / SHIPPED / REVERSED 各桶张数,
     * 与列表同一对象级读范围; 无该类型 *:view 权限各桶为 0. kind 取前端 DraftDocKind 枚举名.
     */
    @GetMapping("/status-counts")
    @PreAuthorize("isAuthenticated()")
    public Map<String, Long> statusCounts(
            @RequestParam String kind,
            @RequestParam(required = false) String shipmentKind,
            @RequestParam(required = false) String docType) {
        return statusCounts.counts(kind, shipmentKind, docType);
    }

    /** 销售出货 / 采购订货 / 委外订货各自的「财务已退回」张数(hub 单据卡徽章 = 草稿 + 财务已退回). */
    @GetMapping("/finance-rejected/count")
    @PreAuthorize("isAuthenticated()")
    public Map<String, Long> financeRejectedCounts() {
        return statusCounts.financeRejectedCounts();
    }
}
