package com.uten.imp.features.common.taskclaim;

import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.SalesOrderFinanceReviewerEligibilityPort;
import com.uten.imp.application.port.ReviewTaskTargetLockPort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.Map;
import java.util.List;
import java.util.Comparator;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * 统一任务软认领服务（ADR-023，泛化 ADR-021 §四 的 hr_task_claims）。
 *
 * <p>用户选定的可见性策略 = <b>show-as-locked</b>：任务始终可见，被认领目标显示「XXX 处理中」，
 * 他人快捷动作禁用；不隐藏。认领带按类型短租约，过期惰性失效；认领人可续租/释放；持目标
 * manage 权限者可强制释放/接管。
 *
 * <p>财务新决策必须持有本人有效租约，并在业务header/case/claim锁内复核同代proof。
 * 其他通用软认领可用 {@link #requireNoActiveClaimByOther} 防碰撞；所有动作仍保留业务状态与悲观锁守卫。
 */
@Service
@RequiredArgsConstructor
public class TaskClaimService implements TaskClaimMutationGuardPort {

    private final TaskClaimRepository claimRepo;
    private final EmployeeNameResolver nameResolver;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.audit.AuditService audit;
    private final List<ReviewTaskTargetLockPort> reviewTargetLocks;
    private final FinanceReviewerEligibilityPort procurementReviewers;
    private final SalesOrderFinanceReviewerEligibilityPort salesReviewers;

    /** 认领（幂等：自己已认领=续租；他人在租约内=409；过期=惰性释放后重建）。 */
    @Transactional
    public TaskClaimView claim(String targetType, String targetKey) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        UUID me = requireClaimant(targetType, targetKey, policy);
        ClaimOutcome outcome = claimInternal(targetType, targetKey, policy, me);
        auditExplicit(outcome.action(), targetType, targetKey);
        return outcome.view();
    }

    private ClaimOutcome claimInternal(String targetType, String targetKey, TaskClaimPolicy policy, UUID me) {
        TaskClaim existing = claimRepo
                .findUnreleasedForUpdate(targetType, targetKey)
                .orElse(null);
        if (existing != null && existing.isActive()) {
            if (existing.getClaimedBy().equals(me)) {
                existing.setLeaseUntil(nowPlusLease(policy));
                existing.setLastHeartbeat(OffsetDateTime.now());
                return new ClaimOutcome(
                        toView(claimRepo.save(existing), me),
                        "task_renew");
            }
            throw new ApiException(ErrorCode.CONFLICT,
                    "该事项正由 " + claimantName(existing.getClaimedBy()) + " 处理中");
        }
        if (existing != null) {
            // 租约已过期：惰性释放，复用部分唯一索引
            existing.setReleasedAt(OffsetDateTime.now());
            existing.setReleaseReason("expired");
            claimRepo.save(existing);
            // Free the partial unique key before Hibernate queues the replacement INSERT.
            claimRepo.flush();
        }
        TaskClaim c = new TaskClaim();
        c.setTargetType(targetType);
        c.setTargetKey(targetKey);
        c.setClaimedBy(me);
        c.setClaimedAt(OffsetDateTime.now().truncatedTo(java.time.temporal.ChronoUnit.MICROS));
        c.setLeaseUntil(nowPlusLease(policy));
        c.setLastHeartbeat(OffsetDateTime.now());
        return new ClaimOutcome(
                toView(claimRepo.save(c), me),
                "task_claim");
    }

    /** 释放（本人或持 manage 权限者；无有效认领时幂等成功）。 */
    @Transactional
    public void release(String targetType, String targetKey) {
        release(targetType,targetKey,null);
    }

    @Transactional
    public void release(String targetType,String targetKey,UUID expectedClaimId) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        UUID me = currentUser.requireEmployeeId();
        boolean canManage = hasAnyPermission(policy.managePermissions());
        lockReviewTargets(targetType,List.of(targetKey),false);
        claimRepo.findUnreleasedForUpdate(targetType, targetKey)
                .ifPresent(c -> {
                    if (expectedClaimId!=null && !expectedClaimId.equals(c.getId())) return;
                    boolean byManager = !c.getClaimedBy().equals(me) && canManage;
                    if (!c.getClaimedBy().equals(me) && !canManage) {
                        throw new ApiException(ErrorCode.FORBIDDEN, "只能释放自己认领的事项(或由管理者释放)");
                    }
                    if (byManager) requireReviewView(policy);
                    c.setReleasedAt(OffsetDateTime.now());
                    c.setReleasedBy(me);
                    c.setReleaseReason(byManager ? "admin_force_release" : "manual");
                    claimRepo.save(c);
                    auditExplicit(
                            byManager ? "task_force_release" : "task_release",
                            targetType, targetKey);
                });
    }

    /** 接管（manage 权限）：原认领强制释放，转由我认领。 */
    @Transactional
    public TaskClaimView takeover(String targetType, String targetKey) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        requireEmployeeWithAnyPermission(policy.managePermissions());
        UUID me = requireClaimant(targetType, targetKey, policy);
        TaskClaim previous = claimRepo
                .findUnreleasedForUpdate(targetType, targetKey)
                .orElse(null);
        boolean replacedOther = previous != null
                && previous.isActive()
                && !previous.getClaimedBy().equals(me);
        boolean renewedSelf = previous != null
                && previous.isActive()
                && previous.getClaimedBy().equals(me);
        if (replacedOther) {
            previous.setReleasedAt(OffsetDateTime.now());
            previous.setReleasedBy(me);
            previous.setReleaseReason("takeover");
            previous.setRemark("被接管");
            claimRepo.save(previous);
            claimRepo.flush();
        }
        ClaimOutcome claimed = claimInternal(targetType, targetKey, policy, me);
        auditExplicit(
                replacedOther ? "task_takeover"
                        : renewedSelf ? "task_renew" : claimed.action(),
                targetType,
                targetKey);
        return claimed.view();
    }

    /** 强制释放（manage 权限）：管理者只想解锁、不接管。 */
    @Transactional
    public void forceRelease(String targetType, String targetKey) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        requireReviewView(policy);
        UUID me = requireEmployeeWithAnyPermission(policy.managePermissions());
        lockReviewTargets(targetType,List.of(targetKey),false);
        claimRepo.findUnreleasedForUpdate(targetType, targetKey)
                .ifPresent(c -> {
                    c.setReleasedAt(OffsetDateTime.now());
                    c.setReleasedBy(me);
                    c.setReleaseReason("admin_force_release");
                    claimRepo.save(c);
                    auditExplicit("task_force_release", targetType, targetKey);
                });
    }

    /** 心跳续租先复核与新认领相同的权限和目标资格；仅本人可续，过期或被接管返回 409。 */
    @Transactional
    public TaskClaimView heartbeat(String targetType, String targetKey) {
        return heartbeat(targetType,targetKey,null);
    }

    @Transactional
    public TaskClaimView heartbeat(String targetType,String targetKey,UUID expectedClaimId) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        UUID me = requireClaimant(targetType, targetKey, policy);
        TaskClaim c = claimRepo.findUnreleasedForUpdate(targetType, targetKey)
                .filter(TaskClaim::isActive)
                .orElseThrow(() -> new ApiException(ErrorCode.CONFLICT, "认领已过期或不存在，请重新认领"));
        if (!c.getClaimedBy().equals(me)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该事项正由 " + claimantName(c.getClaimedBy()) + " 处理中");
        }
        requireGeneration(c,expectedClaimId);
        OffsetDateTime now = OffsetDateTime.now();
        long renewWhenRemainingSeconds = Math.max(
                60L, policy.leaseMinutes() * 30L);
        long remainingSeconds = Duration.between(now, c.getLeaseUntil()).getSeconds();
        if (remainingSeconds <= renewWhenRemainingSeconds) {
            c.setLeaseUntil(now.plusMinutes(policy.leaseMinutes()));
            c.setLastHeartbeat(now);
            return toView(claimRepo.save(c), me);
        }
        // The client pings every 30s. Returning the current lease without
        // touching the entity avoids a database UPDATE and trigger audit row.
        return toView(c, me);
    }

    private UUID requireClaimant(String targetType, String targetKey, TaskClaimPolicy policy) {
        requireReviewView(policy);
        UUID employee = requireEmployeeWithAnyPermission(policy.claimPermissions());
        requireCurrentReviewerEligibility(targetType);
        lockReviewTargets(targetType,List.of(targetKey),true);
        requireCurrentReviewerEligibility(targetType);
        return employee;
    }

    private void requireCurrentReviewerEligibility(String targetType) {
        boolean eligible = switch (targetType) {
            case "SALES_ORDER_FINANCE_CONFIRM" -> salesReviewers.isEligible(currentUser.requireId());
            case "PROCUREMENT_FINANCE_APPROVE" -> procurementReviewers.findEligible(currentUser.requireId()).isPresent();
            default -> true;
        };
        if (!eligible) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前人员不具备对应财务审核资格，无法认领或续租");
        }
    }

    /** The caller's business transaction must own a live lease before changing financial facts. */
    @Transactional(propagation=org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void requireActiveClaimByMe(String targetType,String targetKey,UUID expectedClaimId) {
        requireActiveClaimsByMe(targetType,List.of(new ClaimExpectation(targetKey,expectedClaimId)));
    }

    @Transactional(propagation=org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void requireActiveClaimByMe(String targetType,String targetKey) {
        requireActiveClaimByMe(targetType,targetKey,null);
    }

    /** Lock every header, then every case, then claims in stable order; one failure aborts the caller's whole batch. */
    @Transactional(propagation=org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void requireActiveClaimsByMe(String targetType,List<ClaimExpectation> expectations) {
        if (expectations==null || expectations.isEmpty()) return;
        TaskClaimPolicy policy=TaskClaimPolicy.of(targetType);
        requireReviewView(policy);
        UUID me=requireEmployeeWithAnyPermission(policy.claimPermissions());
        requireCurrentReviewerEligibility(targetType);
        List<ClaimExpectation> ordered=expectations.stream().sorted(Comparator.comparing(ClaimExpectation::targetKey)).toList();
        lockReviewTargets(targetType,ordered.stream().map(ClaimExpectation::targetKey).toList(),true);
        requireCurrentReviewerEligibility(targetType);
        for (ClaimExpectation expected:ordered) {
            TaskClaim claim=claimRepo.findUnreleasedForUpdate(targetType,expected.targetKey())
                    .filter(TaskClaim::isActive).orElseThrow(() -> new ApiException(ErrorCode.CONFLICT,"请先认领并保持审核会话，当前认领不存在或已过期"));
            if (!me.equals(claim.getClaimedBy())) throw new ApiException(ErrorCode.CONFLICT,"该事项已由其他人员认领，请重新进入审核");
            requireGeneration(claim,expected.expectedClaimId());
        }
    }

    private static void requireGeneration(TaskClaim claim,UUID expectedClaimId) {
        if (expectedClaimId!=null && !expectedClaimId.equals(claim.getId())) {
            throw new ApiException(ErrorCode.CONFLICT,"审核认领已更新，请重新进入审核");
        }
    }

    private void requireReviewView(TaskClaimPolicy policy) {
        if (policy.requiredViewPermission()!=null && !hasAnyPermission(java.util.Set.of(policy.requiredViewPermission()))) {
            throw new ApiException(ErrorCode.FORBIDDEN,"无权查看对应财务审核任务");
        }
    }

    /**
     * 动作端点守卫：若存在他人活跃认领则抛 409。供审批/分解端点在最前调用，作为
     * show-as-locked 的服务端兜底（防两人同时操作同一待办）。
     */
    @Transactional(readOnly = true)
    public void requireNoActiveClaimByOther(String targetType, String targetKey) {
        UUID me = currentUser.employeeId().orElse(null);
        claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, targetKey)
                .filter(TaskClaim::isActive)
                .ifPresent(c -> {
                    if (me == null || !c.getClaimedBy().equals(me)) {
                        throw new ApiException(ErrorCode.CONFLICT,
                                "该事项正由 " + claimantName(c.getClaimedBy()) + " 处理中，请勿重复操作");
                    }
                });
    }

    /** Commercial writes are blocked even when the salesperson also owns the review claim. */
    @Transactional(propagation=org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void requireNoActiveClaim(String targetType, String targetKey) {
        claimRepo.findUnreleasedForUpdate(targetType, targetKey)
                .filter(TaskClaim::isActive)
                .ifPresent(claim -> {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "该订单正由 " + claimantName(claim.getClaimedBy())
                                    + " 进行财务审核，请等待审核完成或退出审核后再修改");
                });
    }

    private void lockReviewTargets(String targetType,List<String> keys,boolean requireReviewable) {
        TaskClaimPolicy policy=TaskClaimPolicy.of(targetType);
        if (policy.requiredViewPermission()==null) return;
        ReviewTaskTargetLockPort port=reviewTargetLocks.stream().filter(value -> value.targetType().equals(targetType))
                .findFirst().orElseThrow(() -> new IllegalStateException("Financial review target lock adapter missing: "+targetType));
        List<ReviewTaskTargetLockPort.Target> targets=port.resolve(keys,requireReviewable).stream()
                .sorted(Comparator.comparing(ReviewTaskTargetLockPort.Target::aggregateType)
                        .thenComparing(value -> value.aggregateId().toString())
                        .thenComparing(value -> value.targetId().toString())).toList();
        if (requireReviewable && targets.size()!=keys.stream().distinct().count()) {
            throw new ApiException(ErrorCode.CONFLICT,"审核目标已变化，请刷新后重试");
        }
        java.util.Set<String> headers=new java.util.HashSet<>();
        for (var target:targets) if (headers.add(target.aggregateType()+"/"+target.aggregateId())) {
            port.lockHeader(target,requireReviewable);
        }
        for (var target:targets) port.lockTarget(target,requireReviewable);
    }

    /** 列表/看板装配：某类型的全部有效认领，key = targetKey。 */
    @Transactional(readOnly = true)
    public Map<String, TaskClaim> activeClaimsByTargetKey(String targetType) {
        requireReviewView(TaskClaimPolicy.of(targetType));
        return claimRepo.findAllByTargetTypeAndReleasedAtIsNull(targetType).stream()
                .filter(TaskClaim::isActive)
                .collect(Collectors.toMap(TaskClaim::getTargetKey, Function.identity(), (a, b) -> a));
    }

    /** 列表/详情装配：某类型全部有效认领的视图（key=targetKey），供 DTO 回填 claimView 给前端显示「XX 处理中」。 */
    @Transactional(readOnly = true)
    public Map<String, TaskClaimView> activeClaimViewsByTargetKey(String targetType) {
        requireReviewView(TaskClaimPolicy.of(targetType));
        UUID me = currentUser.employeeId().orElse(null);
        return claimRepo.findAllByTargetTypeAndReleasedAtIsNull(targetType).stream()
                .filter(TaskClaim::isActive)
                .collect(Collectors.toMap(TaskClaim::getTargetKey, c -> toView(c, me), (a, b) -> a));
    }

    /** 单个目标的当前认领视图（详情页用）；无有效认领返回 empty。 */
    @Transactional(readOnly = true)
    public java.util.Optional<TaskClaimView> activeClaimView(String targetType, String targetKey) {
        requireReviewView(TaskClaimPolicy.of(targetType));
        UUID me = currentUser.employeeId().orElse(null);
        return claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, targetKey)
                .filter(TaskClaim::isActive)
                .map(c -> toView(c, me));
    }

    /** 通用任务认领用户操作显式审计：targetId = targetType/targetKey。 */
    private void auditExplicit(String action, String targetType, String targetKey) {
        currentUser.get().ifPresent(u -> audit.logCommitted(
                u.getId(), u.getLoginAccount(), action, "task_claims",
                targetType + "/" + targetKey, "success"));
    }

    String claimantName(UUID employeeId) {
        String name = nameResolver.nameOf(employeeId);
        return name == null || name.isBlank() ? "同事" : name;
    }

    private OffsetDateTime nowPlusLease(TaskClaimPolicy policy) {
        return OffsetDateTime.now().plusMinutes(policy.leaseMinutes());
    }

    private UUID requireEmployeeWithAnyPermission(java.util.Set<String> permissions) {
        AuthUser user = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "无权认领/处理该任务"));
        if (!user.isSuperAdmin() && permissions.stream().noneMatch(user.getPermissions()::contains)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权认领/处理该任务");
        }
        UUID emp = user.getEmployeeId();
        if (emp == null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号未绑定员工档案，无法认领任务");
        }
        return emp;
    }

    private boolean hasAnyPermission(java.util.Set<String> permissions) {
        return currentUser.get()
                .map(u -> u.isSuperAdmin() || permissions.stream().anyMatch(u.getPermissions()::contains))
                .orElse(false);
    }

    private TaskClaimView toView(TaskClaim c, UUID me) {
        return new TaskClaimView(c.getTargetType(), c.getTargetKey(),
                c.getClaimedBy(), claimantName(c.getClaimedBy()),
                c.getClaimedBy().equals(me), c.getClaimedAt(), c.getLeaseUntil(),c.getId());
    }

    public record TaskClaimView(
            String targetType, String targetKey,
            UUID claimedBy, String claimedByName, boolean claimedByMe,
            OffsetDateTime claimedAt, OffsetDateTime leaseUntil,UUID claimId) {
        public TaskClaimView(String targetType,String targetKey,UUID claimedBy,String claimedByName,boolean claimedByMe,
                OffsetDateTime claimedAt,OffsetDateTime leaseUntil) {
            this(targetType,targetKey,claimedBy,claimedByName,claimedByMe,claimedAt,leaseUntil,null);
        }
    }

    private record ClaimOutcome(TaskClaimView view, String action) {}
}
