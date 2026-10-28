package com.uten.imp.features.visitor;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorScanDto.BlacklistListItem;
import com.uten.imp.features.visitor.dto.VisitorScanDto.VisitorVerifyResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** 保安门岗：扫码/短码核验（验签判绿/红）、签到、拉黑/解除/黑名单列表，及 QR/短码签发。 */
@Service
@RequiredArgsConstructor
public class VisitorGateService {

    private static final SecureRandom RNG = new SecureRandom();

    private final VisitorApplicationRepository appRepo;
    private final VisitorAccountRepository accountRepo;
    private final VisitorApplicationService appService;
    private final VisitorApplicationMapper mapper;
    private final VisitorGuard guard;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper objectMapper;
    private final AuditService audit;
    private final UserAccountRepository userRepo;
    private final EmployeeRepository employeeRepo;

    @Transactional
    public VisitorVerifyResponse verify(String qrToken, String passcode) {
        guard.requireStaff();
        VisitorApplication app = null;
        boolean hasQrToken = qrToken != null && !qrToken.isBlank();
        boolean hasPasscode = passcode != null && !passcode.isBlank();
        if (hasQrToken == hasPasscode) {
            return red("invalid", null);
        }
        if (hasQrToken) {
            // 二维码：验 HMAC 签名（常数时间比较）
            String[] parts = qrToken.split("\\.", 2);
            if (parts.length != 2
                    || parts[0].isBlank()
                    || !parts[1].matches("^[0-9a-f]{64}$")
                    || !MessageDigest.isEqual(
                    tx.hmac(parts[0]).getBytes(StandardCharsets.UTF_8),
                    parts[1].getBytes(StandardCharsets.UTF_8))) {
                return red("invalid", null);
            }
            try {
                String json = new String(Base64.getUrlDecoder().decode(parts[0]), StandardCharsets.UTF_8);
                QrPayload p = objectMapper.readValue(json, QrPayload.class);
                if (OffsetDateTime.now().toEpochSecond() >= p.exp()) {
                    return red("expired", null);
                }
                app = appRepo.findById(p.aid()).orElse(null);
                if (app != null && !qrToken.equals(app.getQrToken())) {
                    return red("invalid", null);
                }
            } catch (Exception e) {
                return red("invalid", null);
            }
        } else {
            // 6位短码：二维码扫不了时手动输入
            if (passcode == null || passcode.isBlank()) return red("invalid", null);
            app = appRepo.findByPasscode(passcode.trim()).orElse(null);
        }
        if (app == null) {
            return red("invalid", null);
        }
        String rejection = admissionRejection(app);
        return rejection == null ? green(app) : red(rejection, app);
    }

    @Transactional
    public VisitorVerifyResponse checkIn(UUID appId) {
        tx.bind();
        guard.requireStaff();
        VisitorApplication app = appService.loadForUpdate(appId);
        String rejection = admissionRejection(app);
        if (rejection != null) return red(rejection, app);
        app.setStatus("checkedIn");
        app.setCheckInAt(OffsetDateTime.now());
        appRepo.save(app);
        UUID actorId = currentUser.id().orElse(null);
        appService.addStep(appId, "staff", actorId, "checkIn", null);
        return green(app);
    }

    /** H4/V603：拉黑访客（blocked → JwtAuthFilter 即时拒绝；原因/时间/操作人落库 + 审计）。 */
    @Transactional
    public void blacklist(UUID visitorId, String reason) {
        UUID actorId = guard.requireStaff();
        tx.bind();
        VisitorAccount acc = accountRepo.findAndLockById(visitorId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND));
        if ("blocked".equals(acc.getStatus())) {
            throw new ApiException(ErrorCode.BUSINESS, "该访客已在黑名单中");
        }
        acc.setStatus("blocked");
        acc.setBlockedReason(reason == null ? null : reason.trim());
        acc.setBlockedAt(OffsetDateTime.now());
        acc.setBlockedBy(actorId);
        accountRepo.save(acc);
        audit.logCommitted(visitorId, acc.getVisitorNo(), "visitor_blacklist",
                "visitor_account", visitorId.toString(),
                acc.getBlockedReason(), null);
    }

    /** 解除拉黑：账号回 active、清运营字段；行级历史由 fn_audit 触发器留痕。 */
    @Transactional
    public void unblacklist(UUID visitorId) {
        guard.requireStaff();
        tx.bind();
        VisitorAccount acc = accountRepo.findAndLockById(visitorId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND));
        if (!"blocked".equals(acc.getStatus())) {
            throw new ApiException(ErrorCode.BUSINESS, "该访客不在黑名单中");
        }
        acc.setStatus("active");
        acc.setBlockedReason(null);
        acc.setBlockedAt(null);
        acc.setBlockedBy(null);
        accountRepo.save(acc);
        audit.logCommitted(visitorId, acc.getVisitorNo(), "visitor_unblacklist",
                "visitor_account", visitorId.toString(), "success", null);
    }

    /** 黑名单管理页列表（blocked 账号分页，批量装配操作人姓名，避免逐行查询）。 */
    @Transactional(readOnly = true)
    public PageResponse<BlacklistListItem> blacklistPage(int page, int size) {
        return blacklistPage(page, size, Map.of(), null, null);
    }

    private static final Map<String, com.uten.imp.common.util.JpaColumnSearch.Field> BLACKLIST_COLUMNS = Map.of(
            "visitorNo", com.uten.imp.common.util.JpaColumnSearch.Field.text("visitorNo"),
            "name", com.uten.imp.common.util.JpaColumnSearch.Field.text("name"),
            "blockedReason", com.uten.imp.common.util.JpaColumnSearch.Field.text("blockedReason"),
            "blockedAt", com.uten.imp.common.util.JpaColumnSearch.Field.instant("blockedAt"),
            "blockedByName", com.uten.imp.common.util.JpaColumnSearch.Field.text((root, query, cb) -> {
                var operator = query.subquery(String.class);
                var user = operator.from(com.uten.imp.features.auth.model.UserAccount.class);
                operator.select(user.get("employee").get("fullName"))
                        .where(cb.equal(user.get("id"), root.get("blockedBy")));
                return operator;
            }));

    @Transactional(readOnly = true)
    public PageResponse<BlacklistListItem> blacklistPage(int page, int size,
            Map<String, String> columns, String sort, String order) {
        guard.requireStaff();
        var remaining = new java.util.LinkedHashMap<String, String>(columns == null ? Map.of() : columns);
        String phone = remaining.remove("phone");
        final String phoneHash = phone == null || phone.isBlank() ? null
                : tx.hmac(com.uten.imp.common.util.ChinaMobileNumber.normalize(phone)
                        .orElseThrow(() -> new com.uten.imp.common.web.ApiException(
                                com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                                "手机号按完整中国大陆手机号码精确检索")));
        var searches = com.uten.imp.common.util.JpaColumnSearch.validate(remaining, BLACKLIST_COLUMNS);
        Pageable pageable = com.uten.imp.common.web.Pageables.of(page, size,
                com.uten.imp.common.web.TableSort.resolve(sort, order,
                        org.springframework.data.domain.Sort.by(
                                org.springframework.data.domain.Sort.Order.desc("blockedAt").nullsLast(),
                                org.springframework.data.domain.Sort.Order.desc("updatedAt")),
                        Map.of("blockedAt", "blockedAt", "visitorNo", "visitorNo")));
        Page<VisitorAccount> result = searches.isEmpty() && phoneHash == null && (sort == null || sort.isBlank())
                ? accountRepo.findBlacklisted(pageable)
                : accountRepo.findAll((root, query, cb) -> cb.and(
                        cb.equal(root.get("status"), "blocked"),
                        phoneHash == null ? cb.conjunction() : cb.equal(root.get("phoneHash"), phoneHash),
                        com.uten.imp.common.util.JpaColumnSearch.predicate(
                                root, query, cb, searches, BLACKLIST_COLUMNS)), pageable);
        Map<UUID, String> operatorNames = operatorNames(result.getContent());
        return new PageResponse<>(
                result.getContent().stream()
                        .map(acc -> new BlacklistListItem(
                                acc.getId(),
                                acc.getVisitorNo(),
                                acc.getName(),
                                acc.getPhoneEnc() == null ? null : tx.decrypt(acc.getPhoneEnc()),
                                acc.getBlockedReason(),
                                acc.getBlockedAt(),
                                acc.getBlockedBy() == null ? null
                                        : operatorNames.get(acc.getBlockedBy())))
                        .toList(),
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                result.getTotalElements(),
                result.getTotalPages());
    }

    /** blockedBy(users.id) → 员工姓名，两次批量查询（users → employees）。 */
    private Map<UUID, String> operatorNames(List<VisitorAccount> accounts) {
        Set<UUID> userIds = accounts.stream()
                .map(VisitorAccount::getBlockedBy)
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());
        if (userIds.isEmpty()) {
            return Map.of();
        }
        var users = userRepo.findAllById(userIds);
        Set<UUID> employeeIds = users.stream()
                .map(user -> user.getEmployeeId())
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());
        if (employeeIds.isEmpty()) {
            return Map.of();
        }
        Map<UUID, String> byEmployee = employeeRepo.findAllById(employeeIds).stream()
                .collect(Collectors.toMap(Employee::getId, Employee::getFullName, (a, b) -> a));
        return users.stream()
                .filter(user -> user.getEmployeeId() != null
                        && byEmployee.containsKey(user.getEmployeeId()))
                .collect(Collectors.toMap(
                        user -> user.getId(),
                        user -> byEmployee.get(user.getEmployeeId()),
                        (a, b) -> a));
    }

    /** QR, short code and final admission share current database authority. */
    private String admissionRejection(VisitorApplication app) {
        if (app.isDeleted()) return "invalid";
        if ("checkedIn".equals(app.getStatus())) return "used";
        if ("rejected".equals(app.getStatus())) return "rejected";
        if (!"approved".equals(app.getStatus())) return "invalid";
        VisitorAccount account = appService.accountOf(app);
        if (account == null || !"active".equals(account.getStatus())) return "blocked";
        Long expiresAt = credentialExpiry(app);
        return expiresAt == null || OffsetDateTime.now().toEpochSecond() >= expiresAt
                ? "expired" : null;
    }

    /** Existing signed QR expiry is retained for legacy approvals lacking approved_at. */
    private Long credentialExpiry(VisitorApplication app) {
        Long expiry = app.getApprovedAt() == null ? null
                : app.getApprovedAt().plusDays(7).toEpochSecond();
        String token = app.getQrToken();
        if (token != null) {
            try {
                String[] parts = token.split("\\.", 2);
                if (parts.length == 2 && parts[1].matches("^[0-9a-f]{64}$")
                        && MessageDigest.isEqual(tx.hmac(parts[0]).getBytes(StandardCharsets.UTF_8),
                            parts[1].getBytes(StandardCharsets.UTF_8))) {
                    QrPayload payload = objectMapper.readValue(
                            Base64.getUrlDecoder().decode(parts[0]), QrPayload.class);
                    if (app.getId().equals(payload.aid())) {
                        expiry = expiry == null ? payload.exp() : Math.min(expiry, payload.exp());
                    }
                }
            } catch (Exception ignored) {
                // Invalid legacy tokens never extend the persisted approval deadline.
            }
        }
        if (expiry != null && app.getPlannedLeaveAt() != null) {
            expiry = Math.min(expiry, app.getPlannedLeaveAt().toEpochSecond());
        }
        return expiry;
    }

    // ===== 签发与装配 =====

    /** 签发 HMAC 签名二维码 token（HR approve 时调用）。 */
    public String genQr(UUID appId) {
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
    public String genPasscode() {
        for (int i = 0; i < 10; i++) {
            String code = String.format("%06d", RNG.nextInt(1_000_000));
            if (appRepo.findByPasscode(code).isEmpty()) {
                return code;
            }
        }
        return String.format("%06d", RNG.nextInt(1_000_000));
    }

    private VisitorVerifyResponse green(VisitorApplication app) {
        String[] host = mapper.hostInfo(app);
        return new VisitorVerifyResponse(true, "green", "ok",
                app.getId(), app.getVisitorAccountId(), app.getVisitorName(),
                app.getVisitPurpose(), host[0], tx.decrypt(app.getPlateNoEnc()),
                app.getPlannedVisitAt(), app.getCheckInAt());
    }

    private VisitorVerifyResponse red(String reason, VisitorApplication app) {
        if (app == null) {
            return new VisitorVerifyResponse(false, "red", reason,
                    null, null, null, null, null, null, null, null);
        }
        String[] host = mapper.hostInfo(app);
        return new VisitorVerifyResponse(false, "red", reason,
                app.getId(), app.getVisitorAccountId(), app.getVisitorName(),
                app.getVisitPurpose(), host[0], tx.decrypt(app.getPlateNoEnc()),
                app.getPlannedVisitAt(), app.getCheckInAt());
    }

    record QrPayload(UUID aid, long exp) {}
}
