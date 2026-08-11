package com.uten.imp.features.visitor;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.visitor.dto.VisitorScanDto.VisitorVerifyResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.UUID;

/** 保安门岗：扫码/短码核验（验签判绿/红）、签到、拉黑，及 QR/短码签发。 */
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
                if (OffsetDateTime.now().toEpochSecond() > p.exp()) {
                    return red("expired", null);
                }
                app = appRepo.findById(p.aid()).orElse(null);
            } catch (Exception e) {
                return red("invalid", null);
            }
        } else {
            // 6位短码：二维码扫不了时手动输入
            app = appRepo.findByPasscode(passcode.trim()).orElse(null);
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

    /** H4：拉黑访客（blocked → JwtAuthFilter 即时拒绝）。 */
    @Transactional
    public void blacklist(UUID visitorId) {
        tx.bind();
        guard.requireStaff();
        VisitorAccount acc = accountRepo.findById(visitorId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND));
        acc.setStatus("blocked");
        accountRepo.save(acc);
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
                app.getId(), app.getVisitorName(), app.getVisitPurpose(),
                host[0], tx.decrypt(app.getPlateNoEnc()), app.getPlannedVisitAt(), app.getCheckInAt());
    }

    private VisitorVerifyResponse red(String reason, VisitorApplication app) {
        if (app == null) {
            return new VisitorVerifyResponse(false, "red", reason, null, null, null, null, null, null, null);
        }
        String[] host = mapper.hostInfo(app);
        return new VisitorVerifyResponse(false, "red", reason,
                app.getId(), app.getVisitorName(), app.getVisitPurpose(),
                host[0], tx.decrypt(app.getPlateNoEnc()), app.getPlannedVisitAt(), app.getCheckInAt());
    }

    record QrPayload(UUID aid, long exp) {}
}
