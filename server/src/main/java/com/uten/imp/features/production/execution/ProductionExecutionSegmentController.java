package com.uten.imp.features.production.execution;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** 生产计划执行段接口（按 planId scope）：列表/分配 + 段状态转换（放行/派工/开工/取消/冲销）。 */
@RestController
@RequestMapping("/api/production/plans/{planId}/execution-segments")
@RequiredArgsConstructor
public class ProductionExecutionSegmentController {

    private final ProductionExecutionSegmentService service;

    @GetMapping
    @PreAuthorize("hasAuthority('production_plan:view')")
    public List<ExecutionSegmentView> list(@PathVariable UUID planId) {
        return service.list(planId);
    }

    @PatchMapping("/{segmentId}/assignment")
    @PreAuthorize("hasAuthority('production_execution:assign')")
    public ExecutionSegmentView assign(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentAssignmentRequest request) {
        return service.assign(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/release-defer")
    @PreAuthorize("hasAuthority('production_execution:release_defer')")
    public ExecutionSegmentView releaseDefer(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.releaseDefer(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/dispatch")
    @PreAuthorize("hasAuthority('production_execution:dispatch')")
    public ExecutionSegmentView dispatch(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.dispatch(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/start")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
    public ExecutionSegmentView start(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.start(planId, segmentId, request);
    }

    /** 「确认生产路线」(V599 / ADR-091)：开工前显式选定齐套生产 / 分批生产 / 持续生产。
     * 与领料/分批同门槛 view+start（ADR-091 §2.1「权限零新增」表）。 */
    @PostMapping("/{segmentId}/confirm-route")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
    public ExecutionSegmentView confirmRoute(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentRouteConfirmRequest request) {
        return service.confirmRoute(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/recheck-material")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
    public ExecutionSegmentView recheckMaterial(
            @PathVariable UUID planId, @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.recheckMaterial(planId, segmentId, request);
    }

    @PostMapping("/batch-start")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
    public List<ExecutionSegmentView> batchStart(
            @PathVariable UUID planId,
            @Valid @RequestBody BatchStartRequest request) {
        return service.batchStart(planId, request);
    }

    @PostMapping("/{segmentId}/cancel")
    @PreAuthorize("hasAuthority('production_execution:cancel')")
    public ExecutionSegmentView cancel(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.cancel(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/reverse")
    @PreAuthorize("hasAuthority('production_execution:reverse')")
    public ExecutionSegmentView reverse(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.reverse(planId, segmentId, request);
    }
}
