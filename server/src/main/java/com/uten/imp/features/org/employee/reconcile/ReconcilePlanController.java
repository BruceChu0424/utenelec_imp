package com.uten.imp.features.org.employee.reconcile;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.org.employee.reconcile.dto.CreateIdRepairPlanRequest;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcileApplyRequest;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ApplyResult;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.PlanSummary;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.PlanView;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * 员工资料核对接口（/api/org/employee-reconcile，V810/ADR-160）：证件核对页多选生成计划 →
 * 核对更正页逐行确认 → @RequiresStepUp 再认证后批量执行；业务冲突用 409 + fieldErrors.errorCode
 * （RECONCILE_PLAN_CHANGED / BUSY / EXPIRED），非创建人一律 404 不暴露存在性。
 *
 * <p>权限口径：类级统一 {@code employee:view}；需要更紧的方法级注解按仓库惯例重复类级表达式
 * 再 {@code and} 收紧（Spring 只取最具体的 @PreAuthorize，方法级会整体替换类级）。</p>
 */
@RestController
@RequestMapping("/api/org/employee-reconcile")
@PreAuthorize("hasAuthority('employee:view')")
@RequiredArgsConstructor
public class ReconcilePlanController {

    private final ReconcilePlanService planService;
    private final ReconcilePlanQueryService queryService;
    private final ReconcileApplyService applyService;
    private final SecurityContextCurrentUser currentUser;
    private final AuditDetailViewRecorder viewAudit;

    /** 生成证件修复核对计划（解密存量证件号 → IdRepairAdvisor 建议 → 密文落库）。 */
    @PostMapping("/plans/id-repair")
    @PreAuthorize("hasAuthority('employee:view') and hasAuthority('employee:pii:edit')")
    public PlanView createIdRepairPlan(@Valid @RequestBody CreateIdRepairPlanRequest request) {
        return planService.createIdRepairPlan(actor(), request.employeeIds());
    }

    /** 计划详情（非创建人需 employee:edit，否则 404）：成功解出的查看写一条明细查看审计。 */
    @GetMapping("/plans/{id}")
    public PlanView view(@PathVariable UUID id) {
        PlanView view = queryService.view(id, actor());
        viewAudit.record("view_employee_reconcile_plan_detail", "employee_reconcile_plans",
                id, null, null, "员工资料核对");
        return view;
    }

    /** 计划列表（创建时间倒序；size 上限 100，超出截到 100）。 */
    @GetMapping("/plans")
    @PreAuthorize("hasAuthority('employee:view') and hasAuthority('employee:edit')")
    public PageResponse<PlanSummary> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return queryService.list(page, size);
    }

    /** 执行一轮更正：先重新输密码（再认证），逐人走 changeIdentity，逐处结果回写。 */
    @PostMapping("/plans/{id}/apply")
    @RequiresStepUp
    public ApplyResult apply(@PathVariable UUID id, @Valid @RequestBody ReconcileApplyRequest request) {
        return applyService.apply(actor(), id, request);
    }

    /** 创建人放弃计划：立即关闭并清掉未执行值（幂等）。 */
    @PostMapping("/plans/{id}/discard")
    public Map<String, Object> discard(@PathVariable UUID id) {
        planService.discard(actor(), id);
        return Map.of();
    }

    private AuthUser actor() {
        return currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
    }
}
