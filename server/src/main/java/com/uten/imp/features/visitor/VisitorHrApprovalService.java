package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApproveRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.common.util.Strings.isBlank;

/** HR 访客审批：待审列表 / 详情 / approve|reject|forward（approve 生成 HMAC 签名二维码）。 */
@Service
@RequiredArgsConstructor
public class VisitorHrApprovalService {

    private final VisitorApplicationRepository appRepo;
    private final VisitorApplicationService appService;
    private final VisitorApplicationMapper mapper;
    private final VisitorGateService gateService;
    private final VisitorGuard guard;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public List<VisitorListItem> listForApproval(String status) {
        guard.requireStaff();
        Specification<VisitorApplication> spec = (root, q, cb) -> {
            Predicate p = cb.equal(root.get("deleted"), false);
            if (status == null || status.isBlank()) {
                p = cb.and(p, root.get("status").in("pending", "hostReviewing"));
            } else {
                p = cb.and(p, cb.equal(root.get("status"), status));
            }
            return p;
        };
        return appRepo.findAll(spec, Sort.by(Sort.Direction.DESC, "appliedAt")).stream()
                .map(mapper::toListItem)
                .toList();
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
        guard.requireStaff();
        VisitorApplication app = appService.load(id);
        return appService.toDetail(app, appService.accountOf(app));
    }

    @Transactional
    public VisitorDetail handleAction(UUID id, VisitorApproveRequest req) {
        UUID approverId = guard.requireStaff();
        tx.bind();
        VisitorApplication app = appService.load(id);
        String action = req.action() == null ? "" : req.action();
        switch (action) {
            case "approve" -> {
                assertStatus(app, "pending", "hostReviewing");
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
        return appService.toDetail(app, appService.accountOf(app));
    }

    private void assertStatus(VisitorApplication app, String... allowed) {
        for (String s : allowed) if (s.equals(app.getStatus())) return;
        throw new ApiException(ErrorCode.BUSINESS, "当前状态不可执行此操作");
    }
}
