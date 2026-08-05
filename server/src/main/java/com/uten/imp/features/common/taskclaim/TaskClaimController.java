package com.uten.imp.features.common.taskclaim;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 统一任务认领 REST（ADR-023）。可见性策略 = show-as-locked：前端在列表/详情展示「XXX 处理中」
 * 徽标并禁用他人动作按钮；具体权限（认领/管理）由 {@link TaskClaimPolicy} 按类型在服务层校验。
 */
@RestController
@RequestMapping("/api/task-claims")
@RequiredArgsConstructor
public class TaskClaimController {

    private final TaskClaimService claimService;

    /** 认领（自己已认领=续租；他人在租约内=409）。 */
    @PostMapping("/{targetType}/{targetKey}/claim")
    @PreAuthorize("isAuthenticated()")
    public TaskClaimService.TaskClaimView claim(
            @PathVariable String targetType, @PathVariable String targetKey) {
        return claimService.claim(targetType, targetKey);
    }

    /** 释放（本人或持目标 manage 权限者）。 */
    @DeleteMapping("/{targetType}/{targetKey}")
    @PreAuthorize("isAuthenticated()")
    public void release(
            @PathVariable String targetType, @PathVariable String targetKey) {
        claimService.release(targetType, targetKey);
    }

    /** 接管（持目标 manage 权限者）：原认领强制释放并转由我认领。 */
    @PostMapping("/{targetType}/{targetKey}/takeover")
    @PreAuthorize("isAuthenticated()")
    public TaskClaimService.TaskClaimView takeover(
            @PathVariable String targetType, @PathVariable String targetKey) {
        return claimService.takeover(targetType, targetKey);
    }

    /** 强制释放（持目标 manage 权限者）：只解锁不接管。 */
    @PostMapping("/{targetType}/{targetKey}/force-release")
    @PreAuthorize("isAuthenticated()")
    public void forceRelease(
            @PathVariable String targetType, @PathVariable String targetKey) {
        claimService.forceRelease(targetType, targetKey);
    }

    /** 心跳续租（仅认领人；前端弹窗打开期间定期调用）。 */
    @PostMapping("/{targetType}/{targetKey}/heartbeat")
    @PreAuthorize("isAuthenticated()")
    public TaskClaimService.TaskClaimView heartbeat(
            @PathVariable String targetType, @PathVariable String targetKey) {
        return claimService.heartbeat(targetType, targetKey);
    }
}
