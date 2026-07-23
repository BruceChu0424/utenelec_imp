package com.uten.imp.features.visitor;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.HostConfirmRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApproveRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.features.visitor.dto.VisitorScanDto.VisitorVerifyResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.List;
import java.util.UUID;

/**
 * 访客审批 / 被访人确认 / 保安扫码核验（staff 主体）。
 * <ul>
 *   <li>HR：listForApproval / handleAction(approve|reject|forward) — approve 生成 HMAC 签名二维码</li>
 *   <li>被访人：myAsHost / hostConfirm（可选两级）</li>
 *   <li>保安：verify（验签判绿/红） / checkIn</li>
 * </ul>
 */
@Service
@RequiredArgsConstructor
public class VisitorApprovalService {

    private static final java.security.SecureRandom RNG = new java.security.SecureRandom();

    private final VisitorApplicationRepository appRepo;
    private final VisitorAccountRepository accountRepo;
    private final EmployeeRepository employeeRepo;
    private final VisitorApplicationService appService;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper objectMapper;

    // ===== HR 审批 =====

    @Transactional(readOnly = true)
    public List<VisitorListItem> listForApproval(String status) {
        requireStaff();
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
                .map(this::toListItemStaff)
                .toList();
    }

    @Transactional(readOnly = true)
    public VisitorDetail getDetailForStaff(UUID id) {
        requireStaff();
        VisitorApplication app = load(id);
        return appService.toDetail(app, accountOf(app));
    }

    @Transactional
    public VisitorDetail handleAction(UUID id, VisitorApproveRequest req) {
        UUID approverId = requireStaff();
        tx.bind();
        VisitorApplication app = load(id);
        String action = req.action() == null ? "" : req.action();
        switch (action) {
            case "approve" -> {
                assertStatus(app, "pending", "hostReviewing");
                app.setStatus("approved");
                app.setApprovedBy(approverId);
                app.setApprovedAt(OffsetDateTime.now());
                app.setQrToken(genQr(app.getId()));
                app.setPasscode(genPasscode());
            }
            case "reject" -> {
                assertStatus(app, "pending", "hostReviewing");
                app.setStatus("rejected");
                app.setApprovedBy(approverId);
                app.setApprovedAt(OffsetDateTime.now());
                app.setRejectReason(VisitorApplicationService.isBlank(req.rejectReason())
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
        return appService.toDetail(app, accountOf(app));
    }

    // ===== 被访人确认（可选两级环节）=====

    @Transactional(readOnly = true)
    public List<VisitorListItem> myAsHost() {
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
        return appRepo.findAll(spec, Sort.by(Sort.Direction.DESC, "appliedAt")).stream()
                .map(this::toListItemStaff)
                .toList();
    }

    @Transactional
    public VisitorDetail hostConfirm(UUID id, HostConfirmRequest req) {
        UUID userId = currentUser.id().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        UUID employeeId = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED)).getEmployeeId();
        tx.bind();
        VisitorApplication app = load(id);
        // M1：状态守卫——已批准/已签到/已拒绝/已取消的申请不可再确认
        if ("approved".equals(app.getStatus()) || "checkedIn".equals(app.getStatus())
                || "rejected".equals(app.getStatus()) || "cancelled".equals(app.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT);
        }
        if (app.getHostEmployeeId() == null || !app.getHostEmployeeId().equals(employeeId)) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        if (req.confirmed()) {
            app.setHostConfirmed(true);
            app.setStatus("pending");   // 回到待 HR 批准（携带 hostConfirmed=true）
            appService.addStep(id, "staff", userId, "hostConfirm", req.comment());
        } else {
            app.setHostConfirmed(false);
            app.setStatus("rejected");
            app.setRejectReason(VisitorApplicationService.isBlank(req.comment()) ? "HOST_REJECTED" : req.comment());
            appService.addStep(id, "staff", userId, "hostReject", req.comment());
        }
        appRepo.save(app);
        return appService.toDetail(app, accountOf(app));
    }

    // ===== 保安扫码核验 =====

    @Transactional
    public VisitorVerifyResponse verify(String qrToken, String passcode) {
        requireStaff();
        VisitorApplication app = null;
        if (qrToken != null && !qrToken.isBlank()) {
            // 二维码：验 HMAC 签名（常数时间比较）
            String[] parts = qrToken.split("\\.", 2);
            if (parts.length != 2 || !MessageDigest.isEqual(
                    tx.hmac(parts[0]).getBytes(StandardCharsets.UTF_8),
                    parts[1].getBytes(StandardCharsets.UTF_8))) {
                return red("invalid", null);
            }
            try {
                String json = new String(Base64.getUrlDecoder().decode(parts[0]), StandardCharsets.UTF_8);
                QrPayload p = objectMapper.readValue(json, QrPayload.class);
                if (OffsetDateTime.now().toEpochSecond() > p.exp()) {
                    return red("expired", null);
                }
                app = appRepo.findById(p.aid()).orElse(null);
            } catch (Exception e) {
                return red("invalid", null);
            }
        } else if (passcode != null && !passcode.isBlank()) {
            // 6位短码：二维码扫不了时手动输入
            app = appRepo.findByPasscode(passcode.trim()).orElse(null);
        } else {
            return red("invalid", null);
        }
        if (app == null) {
            return red("invalid", null);
        }
        return switch (app.getStatus()) {
            case "approved" -> green(app);
            case "checkedIn" -> red("used", app);
            case "rejected" -> red("rejected", app);
            default -> red("invalid", app);
        };
    }

    @Transactional
    public VisitorVerifyResponse checkIn(UUID appId) {
        tx.bind();
        // M2：悲观锁防并发重复签到
        VisitorApplication app = appRepo.findAndLockById(appId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND));
        if (!"approved".equals(app.getStatus())) {
            return red("checkedIn".equals(app.getStatus()) ? "used" : "invalid", app);
        }
        app.setStatus("checkedIn");
        app.setCheckInAt(OffsetDateTime.now());
        appRepo.save(app);
        UUID actorId = currentUser.id().orElse(null);
        appService.addStep(appId, "staff", actorId, "checkIn", null);
        return green(app);
    }

    // ===== helpers =====

    private String genQr(UUID appId) {
        try {
            long exp = OffsetDateTime.now().plusDays(7).toEpochSecond();
            String json = objectMapper.writeValueAsString(new QrPayload(appId, exp));
            String payload = Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(json.getBytes(StandardCharsets.UTF_8));
            return payload + "." + tx.hmac(payload);
        } catch (Exception e) {
            throw new IllegalStateException("二维码生成失败", e);
        }
    }

    /** 6位数字短码（二维码无法扫描时手动核验），尽量全局唯一。 */
    private String genPasscode() {
        for (int i = 0; i < 10; i++) {
            String code = String.format("%06d", RNG.nextInt(1_000_000));
            if (appRepo.findByPasscode(code).isEmpty()) {
                return code;
            }
        }
        return String.format("%06d", RNG.nextInt(1_000_000));
    }

    private VisitorVerifyResponse green(VisitorApplication app) {
        String[] host = hostInfo(app);
        return new VisitorVerifyResponse(true, "green", "ok",
                app.getId(), app.getVisitorName(), app.getVisitPurpose(),
                host[0], app.getPlateNo(), app.getPlannedVisitAt(), app.getCheckInAt());
    }

    private VisitorVerifyResponse red(String reason, VisitorApplication app) {
        if (app == null) {
            return new VisitorVerifyResponse(false, "red", reason, null, null, null, null, null, null, null);
        }
        String[] host = hostInfo(app);
        return new VisitorVerifyResponse(false, "red", reason,
                app.getId(), app.getVisitorName(), app.getVisitPurpose(),
                host[0], app.getPlateNo(), app.getPlannedVisitAt(), app.getCheckInAt());
    }

    private VisitorListItem toListItemStaff(VisitorApplication a) {
        String[] host = hostInfo(a);
        return new VisitorListItem(
                a.getId(), a.getVisitorName(), a.getCompany(), a.getVisitPurpose(),
                host[0], host[1],
                a.getPlannedVisitAt(), a.getPlannedLeaveAt(),
                a.getStatus(), a.getAppliedAt(), a.getApprovedAt(),
                a.isHasVehicle(), a.getPlateNo());
    }

    private String[] hostInfo(VisitorApplication a) {
        if (a.getHostEmployeeId() == null) return new String[]{null, null};
        return employeeRepo.findById(a.getHostEmployeeId())
                .map(e -> new String[]{e.getFullName(),
                        e.getDepartment() == null ? null : e.getDepartment().getName()})
                .orElse(new String[]{null, null});
    }

    private VisitorApplication load(UUID id) {
        return appRepo.findById(id).orElseThrow(() -> new ApiException(ErrorCode.VISITOR_NOT_FOUND));
    }

    private VisitorAccount accountOf(VisitorApplication a) {
        return a.getVisitorAccountId() == null ? null
                : accountRepo.findById(a.getVisitorAccountId()).orElse(null);
    }

    private void assertStatus(VisitorApplication app, String... allowed) {
        for (String s : allowed) if (s.equals(app.getStatus())) return;
        throw new ApiException(ErrorCode.BUSINESS, "当前状态不可执行此操作");
    }

    /** H4：拉黑访客（blocked → JwtAuthFilter 即时拒绝）。 */
    @Transactional
    public void blacklist(UUID visitorId) {
        tx.bind();
        requireStaff();
        VisitorAccount acc = accountRepo.findById(visitorId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND));
        acc.setStatus("blocked");
        accountRepo.save(acc);
    }

    private UUID requireStaff() {
        var user = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅员工可访问");
        }
        return user.getId();
    }

    record QrPayload(UUID aid, long exp) {}
}
