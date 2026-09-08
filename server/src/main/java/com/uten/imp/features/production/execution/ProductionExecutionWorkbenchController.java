package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** Planning-facing workbench grouped and paginated by the outer analysis root. */
@RestController
@RequestMapping("/api/production/execution-workbench")
@RequiredArgsConstructor
public class ProductionExecutionWorkbenchController {

    private final ProductionExecutionWorkbenchService service;

    @GetMapping
    @PreAuthorize("hasAuthority('production_execution:overview')")
    public PageResponse<ProductionExecutionWorkbenchGroup> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID workshopDepartmentId,
            @RequestParam(defaultValue = "false") boolean mine,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(
                page, size, keyword, workshopDepartmentId, mine, sort, order);
    }

    @GetMapping("/{rootType}/{rootId}")
    @PreAuthorize("hasAuthority('production_execution:overview')")
    public ProductionExecutionWorkbenchGroup detail(
            @PathVariable String rootType,
            @PathVariable UUID rootId) {
        return service.group(rootType, rootId);
    }

    @GetMapping("/{rootType}/{rootId}/work-orders")
    @PreAuthorize("hasAuthority('production_execution:overview')")
    public PageResponse<ProductionExecutionWorkbenchSegment> workOrders(
            @PathVariable String rootType,
            @PathVariable UUID rootId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "30") int size) {
        return service.workOrders(rootType, rootId, page, size);
    }

    @GetMapping("/{rootType}/{rootId}/related-documents")
    // 计划详情页也消费本端点渲染「本批次关联单据」（采购/委外单可点进对应
    // 单据看进度）；行内容仍按各自模块数据范围过滤（canOpen=false 时只读）。
    @PreAuthorize("hasAnyAuthority('production_execution:overview',"
            + " 'production_plan:view')")
    public PageResponse<ProductionExecutionWorkbenchRelatedDocument> relatedDocuments(
            @PathVariable String rootType,
            @PathVariable UUID rootId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "30") int size) {
        return service.relatedDocuments(rootType, rootId, page, size);
    }
}
