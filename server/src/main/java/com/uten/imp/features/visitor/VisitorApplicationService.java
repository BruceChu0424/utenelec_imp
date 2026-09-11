package com.uten.imp.features.visitor;

import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApprovalStepDto;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApplyRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.common.util.Strings.isBlank;
import static com.uten.imp.common.util.Strings.last4;
import com.uten.imp.features.org.employee.EmploymentStatusPolicy;

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
    private final EmployeeRepository employeeRepo;
    private final VisitorApplicationMapper mapper;
    private final TxSessionVars tx;
    private final HrNoticePort hrNotice;
    private final SecurityContextCurrentUser currentUser;

    /** 访客来访登记：校验必填项与时间合法性，接待人必须在岗状态(active/probation/onLeave)且与接待部门一致；手机号取自短信登录账号、绝不采信请求体（防顶替），18 位身份证 normalize+校验。 */
    @Transactional
    public VisitorDetail submit(VisitorApplyRequest req) {
        UUID visitorId = currentVisitorId();
        if (req == null || isBlank(req.visitorName()) || isBlank(req.visitPurpose())
                || req.hostEmployeeId() == null || req.plannedVisitAt() == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "姓名、来访事由、接待人、计划到访时间为必填");
        }
        if (req.plannedLeaveAt() != null
                && !req.plannedLeaveAt().isAfter(req.plannedVisitAt())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "计划离开时间必须晚于计划到访时间");
        }
        String plateNo = trimToNull(req.plateNo());
        if (req.hasVehicle() && plateNo == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "驾车来访时必须填写车牌号");
        }
        VisitorAccount acc = accountRepo.findAndLockById(visitorId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        requireActiveAccount(acc);
        Employee host = employeeRepo.findById(req.hostEmployeeId())
                .filter(employee -> !employee.isDeleted())
                .filter(employee -> EmploymentStatusPolicy.isCurrentEmployee(employee.getStatus()))
                .orElseThrow(() -> new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "接待人不存在或当前不可接待"));
        UUID actualDepartmentId = host.getDepartment() == null
                ? null
                : host.getDepartment().getId();
        if (req.hostDepartmentId() != null
                && !Objects.equals(req.hostDepartmentId(), actualDepartmentId)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "接待人与接待部门不匹配，请重新选择");
        }

        tx.bind();   // 审计 actor = 当前访客

        String idCardNo = trimToNull(req.idCardNo());
        if (idCardNo != null && idCardNo.length() == 18) {
            idCardNo = IdCardUtil.normalize(idCardNo);
            if (!IdCardUtil.isValid(idCardNo)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "身份证号码校验未通过");
            }
        }
        VisitorApplication app = new VisitorApplication();
        app.setVisitorAccountId(visitorId);
        app.setVisitorName(req.visitorName().trim());
        // Phone identity is established by SMS login; never let the request replace it.
        app.setPhoneEnc(acc.getPhoneEnc());
        app.setIdCardEnc(idCardNo == null ? null : tx.encrypt(idCardNo));
        app.setIdCardLast4(last4(idCardNo));
        app.setCompany(isBlank(req.company()) ? "优腾电器" : req.company().trim());
        app.setVisitPurpose(req.visitPurpose().trim());
        app.setHasVehicle(req.hasVehicle());
        app.setPlateNoEnc(req.hasVehicle() ? tx.encrypt(plateNo) : null);
        app.setHostEmployeeId(host.getId());
        app.setHostDepartmentId(actualDepartmentId);
        app.setPlannedVisitAt(req.plannedVisitAt());
        app.setPlannedLeaveAt(req.plannedLeaveAt());
        app.setStatus("pending");
        app.setAppliedAt(OffsetDateTime.now());
        app = appRepo.save(app);

        addStep(app.getId(), "visitor", visitorId, "submit", null);
        // 提交 → 通知 HR 审批（弹卡 + 通知；2026-09-09 人事通知接入）
        hrNotice.notifyVisitorApplySubmitted(
                app.getId(), app.getVisitorName(), host.getFullName(),
                app.getVisitPurpose());
        return toDetail(app, acc);
    }

    /** HR 批准转接待人确认 → 定向通知接待人（弹卡；2026-09-09 人事通知接入）。 */
    public void notifyHostReview(VisitorApplication app) {
        String hostName = app.getHostEmployeeId() == null ? ""
                : employeeRepo.findById(app.getHostEmployeeId())
                        .map(Employee::getFullName).orElse("");
        hrNotice.notifyVisitorHostReviewRequired(
                app.getId(), app.getVisitorName(), app.getHostEmployeeId(), hostName);
    }

    @Transactional(readOnly = true)
    public PageResponse<VisitorListItem> listMine(String status, int page, int size) {
        UUID visitorId = currentVisitorId();
        Specification<VisitorApplication> spec = (root, q, cb) -> {
            Predicate p = cb.and(cb.equal(root.get("visitorAccountId"), visitorId),
                    cb.equal(root.get("deleted"), false));
            if (!isBlank(status)) {
                p = cb.and(p, cb.equal(root.get("status"), status));
            }
            return p;
        };
        Pageable pageable = visitorPageable(page, size);
        Page<VisitorApplication> result = appRepo.findAll(spec, pageable);
        return toPageResponse(result, pageable);
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
        // Corrupt/missing key material must not silently turn persisted identity data into
        // a plausible-looking null response. Surface the operational failure for alerting.
        String phone = a.getPhoneEnc() == null ? null : tx.decrypt(a.getPhoneEnc());
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

    /** All visitor mutations lock account before application, including admission. */
    VisitorApplication loadForUpdate(UUID id) {
        UUID accountId = appRepo.findIdentityById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.VISITOR_NOT_FOUND))
                .getVisitorAccountId();
        if (accountId != null) {
            accountRepo.findAndLockById(accountId)
                    .orElseThrow(() -> new ApiException(ErrorCode.VISITOR_NOT_FOUND));
        }
        VisitorApplication application = appRepo.findAndLockById(id)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.VISITOR_NOT_FOUND));
        if (!Objects.equals(accountId, application.getVisitorAccountId())) {
            throw new ApiException(ErrorCode.CONFLICT, "访客申请账号已变化，请刷新后重试");
        }
        return application;
    }

    void requireActiveAccount(VisitorApplication app) {
        requireActiveAccount(accountOf(app));
    }

    private static void requireActiveAccount(VisitorAccount account) {
        if (account == null || !"active".equals(account.getStatus())) {
            throw new ApiException(ErrorCode.VISITOR_BLOCKED);
        }
    }

    /** 申请对应的访客账号（可空）。 */
    VisitorAccount accountOf(VisitorApplication a) {
        return a.getVisitorAccountId() == null ? null
                : accountRepo.findById(a.getVisitorAccountId()).orElse(null);
    }

    PageResponse<VisitorListItem> toPageResponse(
            Page<VisitorApplication> result,
            Pageable pageable) {
        return new PageResponse<>(
                mapper.toListItems(result.getContent()),
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                result.getTotalElements(),
                result.getTotalPages());
    }

    static Pageable visitorPageable(int page, int size) {
        return Pageables.of(page, size, Sort.by(
                new Sort.Order(Sort.Direction.DESC, "createdAt"),
                new Sort.Order(Sort.Direction.DESC, "id")));
    }

    private static String trimToNull(String value) {
        if (value == null) return null;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
