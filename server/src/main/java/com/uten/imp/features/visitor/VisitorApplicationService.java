package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApprovalStepDto;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApplyRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import static com.uten.imp.common.util.Strings.last4;

/**
 * 访客来访申请：提交 / 查我的 / 详情（访客主体）。
 * 提交时手机号/身份证走 pgcrypto 加密；审批见 {@link VisitorHrApprovalService}，核验见 {@link VisitorGateService}。
 */
@Service
@RequiredArgsConstructor
public class VisitorApplicationService {

    private final VisitorApplicationRepository appRepo;
    private final VisitorApprovalStepRepository stepRepo;
    private final VisitorAccountRepository accountRepo;
    private final VisitorApplicationMapper mapper;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;

    @Transactional
    public VisitorDetail submit(VisitorApplyRequest req) {
        UUID visitorId = currentVisitorId();
        if (isBlank(req.visitorName()) || isBlank(req.visitPurpose()) || req.plannedVisitAt() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "姓名、来访事由、计划到访时间为必填");
        }
        VisitorAccount acc = accountRepo.findById(visitorId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));

        tx.bind();   // 审计 actor = 当前访客

        VisitorApplication app = new VisitorApplication();
        app.setVisitorAccountId(visitorId);
        app.setVisitorName(req.visitorName());
        app.setPhoneEnc(isBlank(req.phone()) ? acc.getPhoneEnc() : tx.encrypt(req.phone()));
        app.setIdCardEnc(isBlank(req.idCardNo()) ? null : tx.encrypt(req.idCardNo()));
        app.setIdCardLast4(last4(req.idCardNo()));
        app.setCompany(isBlank(req.company()) ? "优腾电器" : req.company());
        app.setVisitPurpose(req.visitPurpose());
        app.setHasVehicle(req.hasVehicle());
        app.setPlateNoEnc(req.hasVehicle() && req.plateNo() != null ? tx.encrypt(req.plateNo()) : null);
        app.setHostEmployeeId(req.hostEmployeeId());
        app.setHostDepartmentId(req.hostDepartmentId());
        app.setPlannedVisitAt(req.plannedVisitAt());
        app.setPlannedLeaveAt(req.plannedLeaveAt());
        app.setStatus("pending");
        app.setAppliedAt(OffsetDateTime.now());
        app = appRepo.save(app);

        addStep(app.getId(), "visitor", visitorId, "submit", null);
        return toDetail(app, acc);
    }

    @Transactional(readOnly = true)
    public List<VisitorListItem> listMine(String status) {
        UUID visitorId = currentVisitorId();
        Specification<VisitorApplication> spec = (root, q, cb) -> {
            Predicate p = cb.and(cb.equal(root.get("visitorAccountId"), visitorId),
                    cb.equal(root.get("deleted"), false));
            if (!isBlank(status)) {
                p = cb.and(p, cb.equal(root.get("status"), status));
            }
            return p;
        };
        return appRepo.findAll(spec, Sort.by(Sort.Direction.DESC, "appliedAt")).stream()
                .map(mapper::toListItem)
                .toList();
    }

    @Transactional(readOnly = true)
    public VisitorDetail getDetail(UUID id) {
        VisitorApplication app = appRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.VISITOR_NOT_FOUND));
        UUID visitorId = currentVisitorId();
        if (!visitorId.equals(app.getVisitorAccountId())) {
            throw new ApiException(ErrorCode.FORBIDDEN);   // 访客只能看自己的
        }
        VisitorAccount acc = app.getVisitorAccountId() == null ? null
                : accountRepo.findById(app.getVisitorAccountId()).orElse(null);
        return toDetail(app, acc);
    }

    /** 写审批轨迹。 */
    void addStep(UUID appId, String actorType, UUID actorId, String action, String comment) {
        VisitorApprovalStep s = new VisitorApprovalStep();
        s.setApplicationId(appId);
        s.setActorType(actorType);
        s.setActorId(actorId);
        s.setAction(action);
        s.setComment(comment);
        s.setActedAt(OffsetDateTime.now());
        stepRepo.save(s);
    }

    VisitorDetail toDetail(VisitorApplication a, VisitorAccount acc) {
        List<VisitorApprovalStepDto> steps = stepRepo.findByApplicationIdOrderByActedAtAsc(a.getId()).stream()
                .map(s -> new VisitorApprovalStepDto(
                        s.getAction(), s.getActorType(),
                        "visitor".equals(s.getActorType())
                                ? (acc == null ? "访客" : acc.getName())
                                : "工作人员",
                        s.getActedAt(), s.getComment()))
                .toList();
        String qrToken = "approved".equals(a.getStatus()) ? a.getQrToken() : null;
        String passcode = "approved".equals(a.getStatus()) ? a.getPasscode() : null;
        String phone = null;
        try {
            if (a.getPhoneEnc() != null) {
                phone = tx.decrypt(a.getPhoneEnc());
            }
        } catch (Exception ignored) { }
        String[] host = mapper.hostInfo(a);
        return new VisitorDetail(
                a.getId(), a.getVisitorName(), phone, a.getIdCardLast4(),
                a.getCompany(), a.getVisitPurpose(), a.isHasVehicle(), tx.decrypt(a.getPlateNoEnc()),
                host[0], host[1],
                a.getPlannedVisitAt(), a.getPlannedLeaveAt(),
                a.getStatus(), a.getAppliedAt(), a.getApprovedAt(),
                a.getRejectReason(), a.getHostConfirmed(), a.getCheckInAt(),
                qrToken, passcode, steps);
    }

    UUID currentVisitorId() {
        return currentUser.id().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
    }

    /** 按 id 载入申请（staff 侧各 Service 共用）。 */
    VisitorApplication load(UUID id) {
        return appRepo.findById(id).orElseThrow(() -> new ApiException(ErrorCode.VISITOR_NOT_FOUND));
    }

    /** 申请对应的访客账号（可空）。 */
    VisitorAccount accountOf(VisitorApplication a) {
        return a.getVisitorAccountId() == null ? null
                : accountRepo.findById(a.getVisitorAccountId()).orElse(null);
    }
}
