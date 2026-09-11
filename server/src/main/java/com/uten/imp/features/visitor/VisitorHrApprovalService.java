package com.uten.imp.features.visitor;

import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApproveRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

import static com.uten.imp.common.util.Strings.isBlank;

/** HR 访客审批：待审列表 / 详情 / approve|reject|forward（approve 生成 HMAC 签名二维码）。 */
@Service
@RequiredArgsConstructor
public class VisitorHrApprovalService {

    private final VisitorApplicationRepository appRepo;
    private final VisitorApplicationService appService;
    private final VisitorGateService gateService;
    private final VisitorGuard guard;
    private final TxSessionVars tx;
    private final HrNoticePort hrNotice;

    @Transactional(readOnly = true)
    public PageResponse<VisitorListItem> listForApproval(
            String status,
            int page,
            int size) {
        return listForApproval(status, null, page, size);
    }

    /**
     * HR 待审列表（2026-09-10 表头筛选接后端）：status 空=待办状态集（pending+hostReviewing），
     * hostDepartmentId 非空时按接待人所属部门（申请时快照 host_department_id）筛选。
     */
    @Transactional(readOnly = true)
    public PageResponse<VisitorListItem> listForApproval(
            String status,
            UUID hostDepartmentId,
            int page,
            int size) {
        guard.requireStaff();
        Specification<VisitorApplication> spec = (root, q, cb) -> {
            Predicate p = cb.equal(root.get("deleted"), false);
            if (status == null || status.isBlank()) {
                p = cb.and(p, root.get("status").in("pending", "hostReviewing"));
            } else {
                p = cb.and(p, cb.equal(root.get("status"), status));
            }
            if (hostDepartmentId != null) {
                p = cb.and(p, cb.equal(root.get("hostDepartmentId"), hostDepartmentId));
            }
            return p;
        };
        Pageable pageable = VisitorApplicationService.visitorPageable(page, size);
        Page<VisitorApplication> result = appRepo.findAll(spec, pageable);
        return appService.toPageResponse(result, pageable);
    }

    /** HR 待办数（工作台/导航徽章）：与待审列表默认 tab 同一状态集（pending + hostReviewing）。 */
    @Transactional(readOnly = true)
    public long pendingCount() {
        guard.requireStaff();
        Specification<VisitorApplication> spec = (root, q, cb) -> cb.and(
                cb.equal(root.get("deleted"), false),
                root.get("status").in("pending", "hostReviewing"));
        return appRepo.count(spec);
    }

    @Transactional(readOnly = true)
    public VisitorDetail getDetailForStaff(UUID id) {
        AuthUser user = guard.requireStaffUser();
        VisitorApplication app = appService.load(id);
        boolean canApprove = user.isSuperAdmin()
                || user.getPermissions().contains("visitor:approve");
        if (!canApprove && (user.getEmployeeId() == null
                || !user.getEmployeeId().equals(app.getHostEmployeeId()))) {
            // Hide another host's application instead of confirming that the UUID exists.
            throw new ApiException(ErrorCode.VISITOR_NOT_FOUND);
        }
        return appService.toDetail(app, appService.accountOf(app));
    }

    @Transactional
    public VisitorDetail handleAction(UUID id, VisitorApproveRequest req) {
        UUID approverId = guard.requireStaff();
        tx.bind();
        VisitorApplication app = appService.loadForUpdate(id);
        String action = req.action() == null ? "" : req.action();
        switch (action) {
            case "approve" -> {
                assertStatus(app, "pending", "hostReviewing");
                appService.requireActiveAccount(app);
                app.setStatus("approved");
                app.setApprovedBy(approverId);
                app.setApprovedAt(OffsetDateTime.now());
                app.setQrToken(gateService.genQr(app.getId()));
                app.setPasscode(gateService.genPasscode());
            }
            case "reject" -> {
                assertStatus(app, "pending", "hostReviewing");
                app.setStatus("rejected");
                app.setApprovedBy(approverId);
                app.setApprovedAt(OffsetDateTime.now());
                app.setRejectReason(isBlank(req.rejectReason())
                        ? req.comment() : req.rejectReason());
            }
            case "forward" -> {
                assertStatus(app, "pending");
                app.setStatus("hostReviewing");
            }
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知审批动作：" + action);
        }
        appRepo.save(app);
        appService.addStep(id, "staff", approverId, action, req.comment());
        // 2026-09-09 人事通知接入：转接待人确认（弹卡）；终态（批准/拒绝）办结撤卡。
        // 终态同时撤 HR 审批卡与可能仍悬挂的「待你确认接待」卡（HR 可越过接待人直接批/驳）。
        switch (action) {
            case "forward" -> appService.notifyHostReview(app);
            case "approve" -> {
                hrNotice.resolveVisitorApplication(id, "APPROVED");
                hrNotice.resolveVisitorHostConfirm(id, "APPROVED");
            }
            case "reject" -> {
                hrNotice.resolveVisitorApplication(id, "REJECTED");
                hrNotice.resolveVisitorHostConfirm(id, "REJECTED");
            }
            default -> { }
        }
        return appService.toDetail(app, appService.accountOf(app));
    }

    private void assertStatus(VisitorApplication app, String... allowed) {
        for (String s : allowed) if (s.equals(app.getStatus())) return;
        throw new ApiException(ErrorCode.BUSINESS, "当前状态不可执行此操作");
    }
}
