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
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public ExecutionSegmentView assign(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentAssignmentRequest request) {
        return service.assign(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/dispatch")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public ExecutionSegmentView dispatch(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.dispatch(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/start")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public ExecutionSegmentView start(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.start(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/cancel")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public ExecutionSegmentView cancel(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.cancel(planId, segmentId, request);
    }

    @PostMapping("/{segmentId}/reverse")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public ExecutionSegmentView reverse(
            @PathVariable UUID planId,
            @PathVariable UUID segmentId,
            @Valid @RequestBody SegmentTransitionRequest request) {
        return service.reverse(planId, segmentId, request);
    }
}
