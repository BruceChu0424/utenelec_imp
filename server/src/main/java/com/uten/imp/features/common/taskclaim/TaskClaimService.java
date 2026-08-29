package com.uten.imp.features.common.taskclaim;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.Map;
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
 * <p>认领只是 UX/防碰撞层。动作端点（审批/分解）仍须保留既有 PESSIMISTIC_WRITE + 状态守卫，
 * 并可调用 {@link #requireNoActiveClaimByOther} 做服务端兜底（防重复操作）。
 */
@Service
@RequiredArgsConstructor
public class TaskClaimService {

    private final TaskClaimRepository claimRepo;
    private final EmployeeNameResolver nameResolver;
    private final SecurityContextCurrentUser currentUser;

    /** 认领（幂等：自己已认领=续租；他人在租约内=409；过期=惰性释放后重建）。 */
    @Transactional
    public TaskClaimView claim(String targetType, String targetKey) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        UUID me = requireEmployeeWithPermission(policy.claimPermission());
        TaskClaim existing = claimRepo
                .findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, targetKey)
                .orElse(null);
        if (existing != null && existing.isActive()) {
            if (existing.getClaimedBy().equals(me)) {
                existing.setLeaseUntil(nowPlusLease(policy));
                existing.setLastHeartbeat(OffsetDateTime.now());
                return toView(claimRepo.save(existing), me);
            }
            throw new ApiException(ErrorCode.CONFLICT,
                    "该事项正由 " + claimantName(existing.getClaimedBy()) + " 处理中");
        }
        if (existing != null) {
            // 租约已过期：惰性释放，复用部分唯一索引
            existing.setReleasedAt(OffsetDateTime.now());
            existing.setReleaseReason("expired");
            claimRepo.save(existing);
        }
        TaskClaim c = new TaskClaim();
        c.setTargetType(targetType);
        c.setTargetKey(targetKey);
        c.setClaimedBy(me);
        c.setClaimedAt(OffsetDateTime.now());
        c.setLeaseUntil(nowPlusLease(policy));
        c.setLastHeartbeat(OffsetDateTime.now());
        return toView(claimRepo.save(c), me);
    }

    /** 释放（本人或持 manage 权限者；无有效认领时幂等成功）。 */
    @Transactional
    public void release(String targetType, String targetKey) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        UUID me = currentUser.requireEmployeeId();
        boolean canManage = hasPermission(policy.managePermission());
        claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, targetKey)
                .filter(TaskClaim::isActive)
                .ifPresent(c -> {
                    boolean byManager = !c.getClaimedBy().equals(me) && canManage;
                    if (!c.getClaimedBy().equals(me) && !canManage) {
                        throw new ApiException(ErrorCode.FORBIDDEN, "只能释放自己认领的事项(或由管理者释放)");
                    }
                    c.setReleasedAt(OffsetDateTime.now());
                    c.setReleasedBy(me);
                    c.setReleaseReason(byManager ? "admin_force_release" : "manual");
                    claimRepo.save(c);
                });
    }

    /** 接管（manage 权限）：原认领强制释放，转由我认领。 */
    @Transactional
    public TaskClaimView takeover(String targetType, String targetKey) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        UUID me = requireEmployeeWithPermission(policy.managePermission());
        claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, targetKey)
                .filter(c -> !c.getClaimedBy().equals(me))
                .ifPresent(c -> {
                    c.setReleasedAt(OffsetDateTime.now());
                    c.setReleasedBy(me);
                    c.setReleaseReason("takeover");
                    c.setRemark("被接管");
                    claimRepo.save(c);
                });
        return claim(targetType, targetKey);
    }

    /** 强制释放（manage 权限）：管理者只想解锁、不接管。 */
    @Transactional
    public void forceRelease(String targetType, String targetKey) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        UUID me = requireEmployeeWithPermission(policy.managePermission());
        claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, targetKey)
                .filter(TaskClaim::isActive)
                .ifPresent(c -> {
                    c.setReleasedAt(OffsetDateTime.now());
                    c.setReleasedBy(me);
                    c.setReleaseReason("admin_force_release");
                    claimRepo.save(c);
                });
    }

    /** 心跳续租（仅认领人；过期/被接管则 409）。 */
    @Transactional
    public TaskClaimView heartbeat(String targetType, String targetKey) {
        TaskClaimPolicy policy = TaskClaimPolicy.of(targetType);
        UUID me = currentUser.requireEmployeeId();
        TaskClaim c = claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, targetKey)
                .filter(TaskClaim::isActive)
                .orElseThrow(() -> new ApiException(ErrorCode.CONFLICT, "认领已过期或不存在，请重新认领"));
        if (!c.getClaimedBy().equals(me)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该事项正由 " + claimantName(c.getClaimedBy()) + " 处理中");
        }
        c.setLeaseUntil(nowPlusLease(policy));
        c.setLastHeartbeat(OffsetDateTime.now());
        return toView(claimRepo.save(c), me);
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

    /** 列表/看板装配：某类型的全部有效认领，key = targetKey。 */
    @Transactional(readOnly = true)
    public Map<String, TaskClaim> activeClaimsByTargetKey(String targetType) {
        return claimRepo.findAllByTargetTypeAndReleasedAtIsNull(targetType).stream()
                .filter(TaskClaim::isActive)
                .collect(Collectors.toMap(TaskClaim::getTargetKey, Function.identity(), (a, b) -> a));
    }

    /** 列表/详情装配：某类型全部有效认领的视图（key=targetKey），供 DTO 回填 claimView 给前端显示「XX 处理中」。 */
    @Transactional(readOnly = true)
    public Map<String, TaskClaimView> activeClaimViewsByTargetKey(String targetType) {
        UUID me = currentUser.employeeId().orElse(null);
        return claimRepo.findAllByTargetTypeAndReleasedAtIsNull(targetType).stream()
                .filter(TaskClaim::isActive)
                .collect(Collectors.toMap(TaskClaim::getTargetKey, c -> toView(c, me), (a, b) -> a));
    }

    /** 单个目标的当前认领视图（详情页用）；无有效认领返回 empty。 */
    @Transactional(readOnly = true)
    public java.util.Optional<TaskClaimView> activeClaimView(String targetType, String targetKey) {
        UUID me = currentUser.employeeId().orElse(null);
        return claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, targetKey)
                .filter(TaskClaim::isActive)
                .map(c -> toView(c, me));
    }

    String claimantName(UUID employeeId) {
        String name = nameResolver.nameOf(employeeId);
        return name == null || name.isBlank() ? "同事" : name;
    }

    private OffsetDateTime nowPlusLease(TaskClaimPolicy policy) {
        return OffsetDateTime.now().plusMinutes(policy.leaseMinutes());
    }

    private UUID requireEmployeeWithPermission(String permission) {
        AuthUser user = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "无权认领/处理该任务"));
        if (!user.isSuperAdmin() && !user.getPermissions().contains(permission)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权认领/处理该任务");
        }
        UUID emp = user.getEmployeeId();
        if (emp == null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号未绑定员工档案，无法认领任务");
        }
        return emp;
    }

    private boolean hasPermission(String permission) {
        return currentUser.get()
                .map(u -> u.isSuperAdmin() || u.getPermissions().contains(permission))
                .orElse(false);
    }

    private TaskClaimView toView(TaskClaim c, UUID me) {
        return new TaskClaimView(c.getTargetType(), c.getTargetKey(),
                c.getClaimedBy(), claimantName(c.getClaimedBy()),
                c.getClaimedBy().equals(me), c.getClaimedAt(), c.getLeaseUntil());
    }

    public record TaskClaimView(
            String targetType, String targetKey,
            UUID claimedBy, String claimedByName, boolean claimedByMe,
            OffsetDateTime claimedAt, OffsetDateTime leaseUntil) {}
}
