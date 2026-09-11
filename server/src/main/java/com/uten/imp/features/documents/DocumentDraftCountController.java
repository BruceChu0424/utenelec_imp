package com.uten.imp.features.documents;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

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

    @GetMapping("/drafts/count")
    @PreAuthorize("isAuthenticated()")
    public DraftCountsResponse draftCounts() {
        return queryService.counts();
    }
}
