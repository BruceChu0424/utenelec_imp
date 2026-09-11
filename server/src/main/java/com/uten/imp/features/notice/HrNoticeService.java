package com.uten.imp.features.notice;

import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/**
 * 人事域待办通知（2026-09-09 用户口径：人事模块「该谁干活」的节点也要有
 * 居中行动卡 + 通知，不再只靠页面拉取式徽章；2026-09-10 补齐办结缺口与新事件）。
 *
 * <p>覆盖五条审批流（事件 → 接收池 → 办结点）：
 * <ul>
 * <li>信息变更：提交 → HR（PROFILE_CHANGE_SUBMITTED，聚合 PROFILE_CHANGE=batchId）；
 *     批准/驳回/员工撤销办结。</li>
 * <li>访客：申请 → HR（VISITOR_APPLY_SUBMITTED，聚合 VISITOR_APPLICATION）；HR 转接待人
 *     → 被访人确认（VISITOR_HOST_CONFIRM_REQUIRED，**独立聚合 VISITOR_HOST_CONFIRM**：
 *     接待人确认后申请回到 HR 批准，HR 卡须继续有效）；接待人确认/拒绝撤接待卡，
 *     HR 批准/驳回撤两种卡。</li>
 * <li>报销：提交 → 审批人（EXPENSE_CLAIM_SUBMITTED，claim=EXPENSE_APPROVE 显示「XX 正在
 *     审核」）；审批通过 → 打款人（EXPENSE_CLAIM_PENDING_PAYMENT）；两者都不打扰申请人本人；
 *     终态/撤回办结；结果回执申请人（普通通知）。</li>
 * <li>工资批次：提交 → 审核人（PAYROLL_BATCH_SUBMITTED，不含制单人）；审核通过 → 发布人
 *     （PAYROLL_BATCH_PENDING_PUBLISH，不含审核人）；驳回回执制单人；发布办结并逐员工
 *     「工资条已发布」（普通通知，不弹卡）。</li>
 * <li>建议箱：提交 → 回复人（SUGGESTION_SUBMITTED，聚合 SUGGESTION，不含提交人；匿名建议
 *     不带姓名）；回复推进到 resolved/rejected 办结并回执提交人（仅本人，匿名亦不外露姓名）。</li>
 * </ul>
 *
 * <p>事件在 {@link ReviewNoticeCatalog} 注册后自动获得弹卡资格（登录检查 / 在线到达 /
 * 认领心跳）。读侧资格在 {@link ReviewNoticeAudience} 按「职能权限」判定——**不限定部门
 * 子树**，这是 ADR-063「部门 ∧ 权限」总口径的明示例外（HR/财务/回复职能本就跨部门）。
 *
 * <p>接收人解析与 ChainNoticeService.userIdsWithNoticeAndAnyPermission 同口径：
 * 活跃账号 × 有效权限快照 × notice:read。
 *
 * <p><b>事务语义（2026-09-10 修正）：与业务同事务，失败随业务回滚。</b>本类无 @Transactional，
 * 各方法在调用方（业务 Service）的事务内执行；{@link NoticeService} 的写方法是 REQUIRED 传播，
 * 其中抛出的异常已把外层事务标记 rollback-only——若此处吞掉异常，业务会在提交时报
 * UnexpectedRollbackException 而无迹可循。因此 {@link #sameTransaction} 只记日志后原样抛出，
 * 业务与通知要么一起落库、要么一起回滚；不做 afterCommit + REQUIRES_NEW 的旁路投递。
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class HrNoticeService implements HrNoticePort {

    public static final String EVENT_PROFILE_CHANGE_SUBMITTED = "PROFILE_CHANGE_SUBMITTED";
    public static final String EVENT_VISITOR_APPLY_SUBMITTED = "VISITOR_APPLY_SUBMITTED";
    public static final String EVENT_VISITOR_HOST_CONFIRM_REQUIRED = "VISITOR_HOST_CONFIRM_REQUIRED";
    public static final String EVENT_EXPENSE_CLAIM_SUBMITTED = "EXPENSE_CLAIM_SUBMITTED";
    public static final String EVENT_EXPENSE_CLAIM_PENDING_PAYMENT = "EXPENSE_CLAIM_PENDING_PAYMENT";
    public static final String EVENT_PAYROLL_BATCH_SUBMITTED = "PAYROLL_BATCH_SUBMITTED";
    public static final String EVENT_PAYROLL_BATCH_PENDING_PUBLISH = "PAYROLL_BATCH_PENDING_PUBLISH";
    public static final String EVENT_SUGGESTION_SUBMITTED = "SUGGESTION_SUBMITTED";

    /** 聚合类型（与 {@link ReviewNoticeCatalog} 登记项一致；办结撤回按此定位）。 */
    static final String AGGREGATE_PROFILE_CHANGE = "PROFILE_CHANGE";
    static final String AGGREGATE_VISITOR_APPLICATION = "VISITOR_APPLICATION";
    static final String AGGREGATE_VISITOR_HOST_CONFIRM = "VISITOR_HOST_CONFIRM";
    static final String AGGREGATE_EXPENSE_CLAIM = "EXPENSE_CLAIM";
    static final String AGGREGATE_PAYROLL_BATCH = "PAYROLL_BATCH";
    static final String AGGREGATE_SUGGESTION = "SUGGESTION";

    private static final String NOTICE_READ_AUTHORITY = "notice:read";
    private static final String TYPE_TASK = "task";
    private static final String TYPE_APPROVAL = "approval";
    /** 建议箱落点：列表页默认「建议广场」（全部建议），scope 由页面状态而非 URL 决定。 */
    private static final String ROUTE_SUGGESTION_LIST = "/suggestion";

    private final NoticeService noticeService;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;
    private final NoticePermissionCandidateQuery permissionCandidates;

    // ========================= 信息变更（HR 审核） =========================

    /** 员工提交需审核字段的修改 → 通知全体持 profile:review 的 HR（提交人本人除外）。 */
    public void notifyProfileChangeSubmitted(UUID batchId, String submitterName,
                                             List<String> fieldLabels, UUID submitterEmployeeId) {
        String fields = String.join("、", fieldLabels.stream().limit(5).toList());
        for (UUID target : userIdsWithNoticeAndAnyPermission("profile:review")) {
            if (submitterEmployeeId != null && belongsToEmployee(target, submitterEmployeeId)) {
                continue;    // 「不能审批自己提交的申请」，也不打扰提交人本人
            }
            sameTransaction(() -> noticeService.publishForUser(
                    target, "信息变更待审核",
                    submitterName + " 提交了 " + fieldLabels.size() + " 项个人信息修改（"
                            + fields + "），请审核。",
                    TYPE_TASK, "人事",
                    "/hr/profile-changes", EVENT_PROFILE_CHANGE_SUBMITTED, "important", batchId));
        }
    }

    /** HR 批准/驳回完成、或员工撤销批次 → 办结撤卡（幂等）。 */
    public void resolveProfileChangeBatch(UUID batchId, String reason) {
        sameTransaction(() -> noticeService.resolveReviewNotices(
                AGGREGATE_PROFILE_CHANGE, batchId, reason));
    }

    // ========================= 访客（HR 审批 + 被访人确认） =========================

    /** 访客提交来访申请 → 通知全体持 visitor:approve 的 HR。 */
    public void notifyVisitorApplySubmitted(UUID applicationId, String visitorName,
                                            String hostName, String visitPurpose) {
        for (UUID target : userIdsWithNoticeAndAnyPermission("visitor:approve")) {
            sameTransaction(() -> noticeService.publishForUser(
                    target, "访客申请待审批",
                    visitorName + " 申请来访（接待人：" + hostName + "；事由：" + visitPurpose + "），请审批。",
                    TYPE_TASK, "人事",
                    "/visitor-approval", EVENT_VISITOR_APPLY_SUBMITTED, "important", applicationId));
        }
    }

    /**
     * HR 转接待人确认：定向通知接待人本人（host-confirm 权限由账号持有）。
     * 聚合 VISITOR_HOST_CONFIRM 与 HR 审批卡分离：接待人确认后申请回到 HR 批准，
     * HR 的 VISITOR_APPLICATION 卡不能被接待卡的办结误撤。
     */
    public void notifyVisitorHostReviewRequired(UUID applicationId, String visitorName,
                                                UUID hostEmployeeId, String hostName) {
        if (hostEmployeeId == null) return;
        boolean dispatched = false;
        for (UUID target : userIdsWithNoticeAndAnyPermission("visitor:host-confirm")) {
            if (!belongsToEmployee(target, hostEmployeeId)) continue;
            sameTransaction(() -> noticeService.publishForUser(
                    target, "访客待你确认接待",
                    visitorName + " 的来访申请已由人事转来，等待你确认接待。",
                    TYPE_TASK, "人事",
                    "/my-visitors", EVENT_VISITOR_HOST_CONFIRM_REQUIRED, "important", applicationId));
            dispatched = true;
        }
        if (!dispatched) {
            // 接待人无登录账号/无权限时无人收到——「我的访客」页仍可见，弹卡链兜底为无。
            log.debug("visitor host notice skipped: application={} host={} has no eligible account",
                    applicationId, hostName);
        }
    }

    /** 访客申请终态（HR 批准/驳回、接待人拒绝）→ 办结 HR 审批卡（幂等）。 */
    public void resolveVisitorApplication(UUID applicationId, String reason) {
        sameTransaction(() -> noticeService.resolveReviewNotices(
                AGGREGATE_VISITOR_APPLICATION, applicationId, reason));
    }

    /** 接待人确认/拒绝、或 HR 直接批准/驳回 → 办结「待你确认接待」卡（幂等）。 */
    public void resolveVisitorHostConfirm(UUID applicationId, String reason) {
        sameTransaction(() -> noticeService.resolveReviewNotices(
                AGGREGATE_VISITOR_HOST_CONFIRM, applicationId, reason));
    }

    // ========================= 报销（审批 → 打款） =========================

    /** 员工提交报销单 → 通知全体持 expense:approve 的审批人（申请人本人除外）。 */
    public void notifyExpenseClaimSubmitted(UUID claimId, String applicantName,
                                            String amountLabel, UUID applicantEmployeeId) {
        for (UUID target : userIdsWithNoticeAndAnyPermission("expense:approve")) {
            if (applicantEmployeeId != null && belongsToEmployee(target, applicantEmployeeId)) {
                continue;    // 申请人不能审批自己的报销单，也不给自己弹卡
            }
            sameTransaction(() -> noticeService.publishForUser(
                    target, "报销单待审批",
                    applicantName + " 提交了报销单（合计 " + amountLabel + "），请审批。",
                    TYPE_TASK, "财务",
                    "/expense/approval", EVENT_EXPENSE_CLAIM_SUBMITTED, "important", claimId));
        }
    }

    /** 审批通过 → 打款人接棒（待打款行动卡，申请人本人除外）+ 申请人回执。 */
    public void notifyExpenseClaimApproved(UUID claimId, String applicantName,
                                           String amountLabel, UUID applicantUserId,
                                           UUID applicantEmployeeId) {
        for (UUID target : userIdsWithNoticeAndAnyPermission("expense:pay")) {
            if (applicantEmployeeId != null && belongsToEmployee(target, applicantEmployeeId)) {
                continue;    // 申请人不能给自己打款，也不给自己弹卡
            }
            sameTransaction(() -> noticeService.publishForUser(
                    target, "报销单待打款",
                    applicantName + " 的报销单（合计 " + amountLabel + "）已审批通过，请打款。",
                    TYPE_TASK, "财务",
                    "/expense/approval", EVENT_EXPENSE_CLAIM_PENDING_PAYMENT, "important", claimId));
        }
        if (applicantUserId != null) {
            sameTransaction(() -> noticeService.publishForUser(
                    applicantUserId, "报销单已审批通过",
                    "你的报销单（合计 " + amountLabel + "）已审批通过，等待打款。",
                    TYPE_APPROVAL, "财务", "/expense"));
        }
    }

    /** 驳回 → 申请人回执（含原因）。 */
    public void notifyExpenseClaimRejected(UUID claimId, String applicantName,
                                           String reason, UUID applicantUserId) {
        if (applicantUserId == null) return;
        sameTransaction(() -> noticeService.publishForUser(
                applicantUserId, "报销单被驳回",
                "你的报销单已被驳回。驳回原因：" + reason,
                TYPE_APPROVAL, "财务", "/expense",
                null, "important", null));
    }

    /** 打款完成 → 申请人回执 + 办结全部报销弹卡。 */
    public void notifyExpenseClaimPaid(UUID claimId, String applicantName,
                                       String amountLabel, UUID applicantUserId) {
        if (applicantUserId != null) {
            sameTransaction(() -> noticeService.publishForUser(
                    applicantUserId, "报销款已到账",
                    "你的报销单（合计 " + amountLabel + "）已完成打款。",
                    TYPE_APPROVAL, "财务", "/expense"));
        }
        sameTransaction(() -> noticeService.resolveReviewNotices(
                AGGREGATE_EXPENSE_CLAIM, claimId, "PAID"));
    }

    /** 撤回/删除/审批终态 → 办结撤卡（审批人一侧不再可办）。 */
    public void resolveExpenseClaim(UUID claimId, String reason) {
        sameTransaction(() -> noticeService.resolveReviewNotices(
                AGGREGATE_EXPENSE_CLAIM, claimId, reason));
    }

    // ========================= 工资批次（审核 → 发布） =========================

    /** 制单人提交工资批次 → 通知全体持 payroll:review 的审核人（制单人本人除外）。 */
    public void notifyPayrollBatchSubmitted(UUID batchId, String periodLabel,
                                            String generatorName, UUID generatorEmployeeId) {
        for (UUID target : userIdsWithNoticeAndAnyPermission("payroll:review")) {
            if (generatorEmployeeId != null && belongsToEmployee(target, generatorEmployeeId)) {
                continue;    // 制单人通常也持 review 权限，不打扰自己
            }
            sameTransaction(() -> noticeService.publishForUser(
                    target, "工资批次待审核",
                    generatorName + " 提交了 " + periodLabel + " 工资批次，请审核。",
                    TYPE_TASK, "人事",
                    "/payroll/review", EVENT_PAYROLL_BATCH_SUBMITTED, "important", batchId));
        }
    }

    /**
     * 审核通过 → 发布人接棒（PAYROLL_BATCH_PENDING_PUBLISH 行动卡，审核人本人除外）。
     * 调用方须先 {@link #resolvePayrollBatch} 办结「待审核」卡再调本方法——两卡同聚合
     * (PAYROLL_BATCH, batchId)，先办结后发布才不会把新卡一起撤掉。
     */
    public void notifyPayrollBatchApproved(UUID batchId, String periodLabel,
                                           UUID approverEmployeeId) {
        for (UUID target : userIdsWithNoticeAndAnyPermission("payroll:publish")) {
            if (approverEmployeeId != null && belongsToEmployee(target, approverEmployeeId)) {
                continue;    // 审核人通常也持 publish 权限，不给自己弹卡
            }
            sameTransaction(() -> noticeService.publishForUser(
                    target, "工资批次待发布",
                    periodLabel + " 工资批次已审核通过，请确认后发布。",
                    TYPE_TASK, "人事",
                    "/payroll/review", EVENT_PAYROLL_BATCH_PENDING_PUBLISH, "important", batchId));
        }
    }

    /** 驳回 → 回执制单人；办结审核弹卡。 */
    public void notifyPayrollBatchRejected(UUID batchId, String periodLabel,
                                           String reason, UUID generatorUserId) {
        if (generatorUserId != null) {
            sameTransaction(() -> noticeService.publishForUser(
                    generatorUserId, "工资批次被驳回",
                    periodLabel + " 工资批次被驳回。原因：" + reason,
                    TYPE_APPROVAL, "人事", "/payroll/generate",
                    null, "important", null));
        }
        sameTransaction(() -> noticeService.resolveReviewNotices(
                AGGREGATE_PAYROLL_BATCH, batchId, "REJECTED"));
    }

    /** 审核通过 / 发布 → 按批次办结当前全部工资批次弹卡（待审核卡或待发布卡）。 */
    public void resolvePayrollBatch(UUID batchId, String reason) {
        sameTransaction(() -> noticeService.resolveReviewNotices(
                AGGREGATE_PAYROLL_BATCH, batchId, reason));
    }

    /** 发布 → 持条员工逐人「工资条已发布」通知（普通，不弹卡）。 */
    public void notifyPayrollPublished(UUID batchId, String periodLabel, List<UUID> employeeIdsWithSlip) {
        for (UUID employeeId : employeeIdsWithSlip) {
            for (UUID target : userRepo.findByEmployeeId(employeeId).stream()
                    .filter(u -> !u.isDeleted() && "active".equals(u.getStatus()))
                    .map(UserAccount::getId).toList()) {
                sameTransaction(() -> noticeService.publishForUser(
                        target, periodLabel + " 工资条已发布",
                        "你的 " + periodLabel + " 工资条已发布，可前往工资条页面查看。",
                        TYPE_APPROVAL, "人事", "/payroll/slip"));
            }
        }
    }

    // ========================= 建议箱（提交 → 回复） =========================

    /**
     * 员工提交建议 → 通知全体持 suggestion:reply 的回复人（提交人本人除外）。
     * 匿名建议的行动卡不带提交人姓名（回复人在详情页按权限可见真名，通知正文不外露）。
     */
    public void notifySuggestionSubmitted(UUID suggestionId, UUID submitterUserId,
                                          String submitterName, String title, boolean anonymous) {
        String who = anonymous ? "一位员工（匿名）" : submitterName;
        for (UUID target : userIdsWithNoticeAndAnyPermission("suggestion:reply")) {
            if (target.equals(submitterUserId)) continue;    // 不给提交人自己弹卡
            sameTransaction(() -> noticeService.publishForUser(
                    target, "建议箱有新建议待回复",
                    who + " 提交了建议「" + title + "」，请查看并回复。",
                    TYPE_TASK, "人事",
                    ROUTE_SUGGESTION_LIST, EVENT_SUGGESTION_SUBMITTED, "important", suggestionId));
        }
    }

    /**
     * 官方回复推进到终态（resolved / rejected）→ 办结回复人弹卡 + 提交人回执
     * （普通通知，仅提交人本人；匿名建议同样只发给本人，正文不含姓名）。
     */
    public void notifySuggestionClosed(UUID suggestionId, UUID submitterUserId,
                                       String title, String status) {
        String normalized = status == null ? "" : status.strip().toLowerCase(Locale.ROOT);
        sameTransaction(() -> noticeService.resolveReviewNotices(
                AGGREGATE_SUGGESTION, suggestionId, normalized.toUpperCase(Locale.ROOT)));
        if (submitterUserId == null) return;
        boolean resolved = "resolved".equals(normalized);
        sameTransaction(() -> noticeService.publishForUser(
                submitterUserId,
                resolved ? "你的建议已采纳处理" : "你的建议已答复",
                "你提交的建议「" + title + "」"
                        + (resolved ? "已处理完成" : "已答复，本次未采纳")
                        + "，可前往建议箱查看官方回复。",
                TYPE_APPROVAL, "人事", "/suggestion/" + suggestionId));
    }

    // ========================= 接收人解析（与供应链链同口径） =========================

    /** 活跃账号 × notice:read × 任一职能权限（含超管权限快照展开）。 */
    private Set<UUID> userIdsWithNoticeAndAnyPermission(String... anyPermission) {
        Set<String> alternatives = Set.of(anyPermission);
        List<UserAccount> candidates = permissionCandidates == null
                ? userRepo.findAll()
                : permissionCandidates.possibleUsers(alternatives)
                        .map(userRepo::findAllById)
                        .orElseGet(userRepo::findAll);
        Set<UUID> result = new LinkedHashSet<>();
        Set<String> adminPermissions = null;
        for (UserAccount user : candidates) {
            if (user == null || user.isDeleted() || !"active".equals(user.getStatus())
                    || user.getEmployeeId() == null) {
                continue;    // 人事审批接收人必须是绑定员工档案的内部账号
            }
            Set<String> permissions;
            if (user.isSuperAdmin()) {
                if (adminPermissions == null) adminPermissions = permissionResolver.permsOf(user);
                permissions = adminPermissions;
            } else {
                permissions = permissionResolver.permsOf(user);
            }
            if (!permissions.contains(NOTICE_READ_AUTHORITY)) continue;
            if (alternatives.stream().anyMatch(permissions::contains)) {
                result.add(user.getId());
            }
        }
        return result;
    }

    private boolean belongsToEmployee(UUID userId, UUID employeeId) {
        return userRepo.findById(userId)
                .map(u -> employeeId.equals(u.getEmployeeId()))
                .orElse(false);
    }

    /**
     * 与业务同事务，失败随业务回滚：只留日志线索后原样抛出（见类注释——NoticeService 的
     * REQUIRED 写方法失败已把外层事务标为 rollback-only，吞掉异常只会把失败推迟到提交时爆）。
     */
    @Override
    public UUID recipientUserIdOf(UUID employeeId) {
        if (employeeId == null) return null;
        return userRepo.findByEmployeeId(employeeId)
                .filter(account -> !account.isDeleted() && "active".equals(account.getStatus()))
                .map(UserAccount::getId)
                .orElse(null);
    }

    private void sameTransaction(Runnable action) {
        try {
            action.run();
        } catch (RuntimeException e) {
            log.warn("人事通知写入失败，随业务事务一起回滚: {}", e.getMessage());
            throw e;
        }
    }
}
