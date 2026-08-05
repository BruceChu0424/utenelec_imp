package com.uten.imp.features.org.hrtask;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * HR 任务中心（行政与人力资源部工作台「任务中心」卡片 + 页面）。
 * 只读动态计算，权限与员工档案查看一致（employee:view）。
 */
@RestController
@RequestMapping("/api/org/hr-tasks")
@RequiredArgsConstructor
public class HrTaskController {

    private final HrTaskService service;
    private final HrTaskClaimService claimService;

    @GetMapping("/summary")
    @PreAuthorize("hasAuthority('employee:view')")
    public HrTaskSummary summary() {
        return service.summary();
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('employee:view')")
    public Map<String, Long> count() {
        return Map.of("count", service.badgeCount());
    }

    // ===== 任务软认领（ADR-021 §四） =====

    @PostMapping("/claims")
    @PreAuthorize("hasAuthority('employee:view')")
    public HrTaskClaimService.HrTaskClaimView claim(
            @jakarta.validation.Valid @RequestBody ClaimRequest req) {
        return claimService.claim(req.taskType(), req.employeeId());
    }

    @DeleteMapping("/claims/{taskType}/{employeeId}")
    @PreAuthorize("hasAuthority('employee:view')")
    public void release(@PathVariable String taskType, @PathVariable UUID employeeId) {
        claimService.release(taskType, employeeId);
    }

    @PostMapping("/claims/{taskType}/{employeeId}/takeover")
    @PreAuthorize("hasAuthority('employee:edit')")
    public HrTaskClaimService.HrTaskClaimView takeover(
            @PathVariable String taskType, @PathVariable UUID employeeId) {
        return claimService.takeover(taskType, employeeId);
    }

    /** 认领请求：taskType = confirm/birthday/anniversary/newhire。 */
    public record ClaimRequest(
            @jakarta.validation.constraints.NotBlank String taskType,
            @jakarta.validation.constraints.NotNull UUID employeeId) {}
}
