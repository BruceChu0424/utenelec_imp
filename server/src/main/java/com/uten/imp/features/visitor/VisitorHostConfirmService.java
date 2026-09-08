package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.HostConfirmRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

import static com.uten.imp.common.util.Strings.isBlank;

/** 被访人确认（可选两级环节）：我作为接待人的待确认列表 / 确认或拒绝。 */
@Service
@RequiredArgsConstructor
public class VisitorHostConfirmService {

    private final VisitorApplicationRepository appRepo;
    private final VisitorApplicationService appService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public PageResponse<VisitorListItem> myAsHost(
            String status,
            int page,
            int size) {
        UUID employeeId = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED)).getEmployeeId();
        if (employeeId == null) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        final UUID eid = employeeId;
        final String effectiveStatus = isBlank(status) ? "hostReviewing" : status;
        Specification<VisitorApplication> spec = (root, q, cb) -> cb.and(
                cb.equal(root.get("deleted"), false),
                cb.equal(root.get("hostEmployeeId"), eid),
                cb.equal(root.get("status"), effectiveStatus));
        Pageable pageable = VisitorApplicationService.visitorPageable(page, size);
        Page<VisitorApplication> result = appRepo.findAll(spec, pageable);
        return appService.toPageResponse(result, pageable);
    }

    /** 我作为接待人的待确认数（工作台/导航徽章）：与 myAsHost 同一条件。 */
    @Transactional(readOnly = true)
    public long myAsHostPendingCount() {
        UUID employeeId = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED)).getEmployeeId();
        if (employeeId == null) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        final UUID eid = employeeId;
        Specification<VisitorApplication> spec = (root, q, cb) -> cb.and(
                cb.equal(root.get("deleted"), false),
                cb.equal(root.get("hostEmployeeId"), eid),
                cb.equal(root.get("status"), "hostReviewing"));
        return appRepo.count(spec);
    }

    @Transactional
    public VisitorDetail hostConfirm(UUID id, HostConfirmRequest req) {
        UUID userId = currentUser.id().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        UUID employeeId = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED)).getEmployeeId();
        tx.bind();
        VisitorApplication app = appService.loadForUpdate(id);
        // M1：状态守卫——已批准/已签到/已拒绝/已取消的申请不可再确认
        if ("approved".equals(app.getStatus()) || "checkedIn".equals(app.getStatus())
                || "rejected".equals(app.getStatus()) || "cancelled".equals(app.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT);
        }
        if (app.getHostEmployeeId() == null || !app.getHostEmployeeId().equals(employeeId)) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        if (req.confirmed()) {
            appService.requireActiveAccount(app);
            app.setHostConfirmed(true);
            app.setStatus("pending");   // 回到待 HR 批准（携带 hostConfirmed=true）
            appService.addStep(id, "staff", userId, "hostConfirm", req.comment());
        } else {
            app.setHostConfirmed(false);
            app.setStatus("rejected");
            app.setRejectReason(isBlank(req.comment()) ? "HOST_REJECTED" : req.comment());
            appService.addStep(id, "staff", userId, "hostReject", req.comment());
        }
        appRepo.save(app);
        return appService.toDetail(app, appService.accountOf(app));
    }
}
