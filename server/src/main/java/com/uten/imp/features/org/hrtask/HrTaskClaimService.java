package com.uten.imp.features.org.hrtask;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * HR 任务软认领服务（ADR-021 §四）。
 *
 * 调研结论（Jira / 钉钉审批 / 飞书工单 / Zendesk）：业界主流**不隐藏**他人处理中的任务，
 * 而是显示「处理人」并阻止他人重复操作；隐藏会导致工作不可见、重复创建、卡住无人发现。
 * 因此：
 * - 任务始终对所有人可见；被认领的行显示「XXX 处理中」，他人快捷操作禁用；
 * - 认领带 {@value #LEASE_HOURS} 小时租约，过期自动失效（读取时惰性判定，无需定时任务）；
 * - 认领人可主动释放；持 employee:edit 者可接管（防认领人请假卡死）；
 * - 认领/释放/接管幂等，冲突返回 409。
 */
@Service
@RequiredArgsConstructor
public class HrTaskClaimService {

    static final long LEASE_HOURS = 24;

    /** 合法任务类型（与 HrTaskService 装配口径一致：confirm/birthday/anniversary/newhire）。 */
    private static final Set<String> ALLOWED_TASK_TYPES =
            Set.of("confirm", "birthday", "anniversary", "newhire");

    private final HrTaskClaimRepository claimRepo;
    private final EmployeeRepository empRepo;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.audit.AuditService audit;

    /** 认领（幂等：自己已认领 = 续租；他人在租约内 = 409）。 */
    @PreAuthorize("hasAuthority('employee:view')")
    @Transactional
    public HrTaskClaimView claim(String taskType, UUID employeeId) {
        HrTaskClaimView view = claimInternal(taskType, employeeId);
        auditExplicit("hr_task_claim", taskType, claimantName(employeeId));
        return view;
    }

    private HrTaskClaimView claimInternal(String taskType, UUID employeeId) {
        requireTaskType(taskType);
        UUID me = currentUser.requireEmployeeId();
        HrTaskClaim existing = claimRepo
                .findFirstByTaskTypeAndEmployeeIdAndReleasedAtIsNull(taskType, employeeId)
                .orElse(null);
        if (existing != null && existing.isActive()) {
            if (existing.getClaimedBy().equals(me)) {
                existing.setLeaseUntil(OffsetDateTime.now().plusHours(LEASE_HOURS)); // 续租
                return toView(claimRepo.save(existing), me);
            }
            throw new ApiException(ErrorCode.CONFLICT,
                    "该事项正由 " + claimantName(existing.getClaimedBy()) + " 处理中");
        }
        if (existing != null) {
            // 租约已过期：视为自动释放，直接复用该记录（保持部分唯一索引成立）
            existing.setReleasedAt(OffsetDateTime.now());
            claimRepo.save(existing);
        }
        HrTaskClaim claim = new HrTaskClaim();
        claim.setTaskType(taskType);
        claim.setEmployeeId(employeeId);
        claim.setClaimedBy(me);
        claim.setClaimedAt(OffsetDateTime.now());
        claim.setLeaseUntil(OffsetDateTime.now().plusHours(LEASE_HOURS));
        return toView(claimRepo.save(claim), me);
    }

    /** 释放（本人或持 employee:edit 的管理者；无有效认领时幂等成功）。 */
    @PreAuthorize("hasAuthority('employee:view')")
    @Transactional
    public void release(String taskType, UUID employeeId) {
        requireTaskType(taskType);
        UUID me = currentUser.requireEmployeeId();
        boolean canManage = currentUser.get()
                .map(u -> u.getPermissions().contains("employee:edit"))
                .orElse(false);
        claimRepo.findFirstByTaskTypeAndEmployeeIdAndReleasedAtIsNull(taskType, employeeId)
                .filter(HrTaskClaim::isActive)
                .ifPresent(claim -> {
                    if (!claim.getClaimedBy().equals(me) && !canManage) {
                        throw new ApiException(ErrorCode.FORBIDDEN,
                                "只能释放自己认领的事项(或由持员工编辑权限者接管)");
                    }
                    claim.setReleasedAt(OffsetDateTime.now());
                    claimRepo.save(claim);
                    auditExplicit("hr_task_release", taskType, claimantName(employeeId));
                });
    }

    /** 接管：原认领强制释放，转由我认领。 */
    @PreAuthorize("hasAuthority('employee:task_takeover')")
    @Transactional
    public HrTaskClaimView takeover(String taskType, UUID employeeId) {
        requireTaskType(taskType);
        UUID me = currentUser.requireEmployeeId();
        claimRepo.findFirstByTaskTypeAndEmployeeIdAndReleasedAtIsNull(taskType, employeeId)
                .filter(c -> !c.getClaimedBy().equals(me))
                .ifPresent(c -> {
                    c.setReleasedAt(OffsetDateTime.now());
                    c.setRemark("被接管");
                    claimRepo.save(c);
                });
        HrTaskClaimView view = claimInternal(taskType, employeeId);
        auditExplicit("hr_task_takeover", taskType, claimantName(employeeId));
        return view;
    }

    /** HR 任务认领用户操作显式审计：targetId = 任务类型 · 员工姓名。 */
    private void auditExplicit(String action, String taskType, String employeeName) {
        currentUser.get().ifPresent(u -> audit.logExplicit(
                u.getId(), u.getLoginAccount(), action, "hr_task_claims",
                taskType + " · " + employeeName, "success"));
    }

    /** summary 装配用：全部有效认领，key = taskType:employeeId。 */
    @Transactional(readOnly = true)
    public Map<String, HrTaskClaim> activeClaimsByTaskKey() {
        return claimRepo.findAllByReleasedAtIsNull().stream()
                .filter(HrTaskClaim::isActive)
                .collect(Collectors.toMap(
                        c -> c.getTaskType() + ":" + c.getEmployeeId(),
                        Function.identity(),
                        (a, b) -> a));
    }

    /** 认领人姓名（懒查，数百人规模下成本可忽略）。 */
    String claimantName(UUID employeeId) {
        return empRepo.findById(employeeId).map(Employee::getFullName).orElse("同事");
    }

    /** 拒绝白名单外的 taskType，避免写入孤儿认领记录（summary 只装配 4 类）。 */
    private static void requireTaskType(String taskType) {
        if (taskType == null || !ALLOWED_TASK_TYPES.contains(taskType)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "未知任务类型: " + taskType + "(可选: " + ALLOWED_TASK_TYPES + ")");
        }
    }

    private HrTaskClaimView toView(HrTaskClaim claim, UUID me) {
        return new HrTaskClaimView(
                claim.getTaskType(), claim.getEmployeeId(),
                claim.getClaimedBy(), claimantName(claim.getClaimedBy()),
                claim.getClaimedBy().equals(me),
                claim.getClaimedAt(), claim.getLeaseUntil());
    }

    public record HrTaskClaimView(
            String taskType, UUID employeeId,
            UUID claimedBy, String claimedByName, boolean claimedByMe,
            OffsetDateTime claimedAt, OffsetDateTime leaseUntil) {}
}
