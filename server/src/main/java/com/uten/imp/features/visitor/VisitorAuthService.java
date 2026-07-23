package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SmsProperties;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.visitor.dto.VisitorAuthDto;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.Set;

/**
 * 访客鉴权：发送验证码 / 登录（含员工检测）/ 刷新 / 登出。
 * 访客 JWT 的 perms 固定为 {visitor:apply, visitor:view}（不查 role_permissions）。
 */
@Service
@RequiredArgsConstructor
public class VisitorAuthService {

    private static final SecureRandom RNG = new SecureRandom();
    private static final Set<String> VISITOR_PERMS = Set.of("visitor:apply", "visitor:view");

    private final VisitorAccountRepository accountRepo;
    private final VisitorSmsService smsService;
    private final VisitorRefreshTokenService refreshService;
    private final VisitorRefreshTokenRepository refreshRepo;
    private final EmployeeSensitiveRepository employeeSensitiveRepo;
    private final JwtService jwtService;
    private final TxSessionVars tx;
    private final SmsProperties smsProps;
    private final AuditService audit;
    private final com.uten.imp.security.LoginRateLimiter rateLimiter;

    @Transactional
    public VisitorAuthDto.SendCodeResponse sendCode(String phoneRaw, String ip) {
        rateLimiter.check(ip);
        String phone = normalize(phoneRaw);
        validatePhone(phone);
        String code = smsService.send(phone, "login");
        String devCode = "log".equalsIgnoreCase(smsProps.getProvider()) ? code : null;
        return new VisitorAuthDto.SendCodeResponse("login", smsService.codeTtlSeconds(), devCode);
    }

    @Transactional
    public VisitorAuthDto.VisitorTokenResponse login(String phoneRaw, String code, String deviceInfo, String ip) {
        rateLimiter.check(ip);
        String phone = normalize(phoneRaw);
        validatePhone(phone);
        smsService.verifyAndConsume(phone, code);

        String phoneHash = tx.hmac(phone);

        // 员工检测：手机号命中员工 → 拦截，提示走员工通道
        if (employeeSensitiveRepo.findByPhoneHash(phoneHash).isPresent()) {
            audit.logExplicit(null, maskPhone(phone), "visitor_login_blocked_employee",
                    "visitor_account", phoneHash, "is_employee");
            throw new ApiException(ErrorCode.IS_EMPLOYEE);
        }

        // 已拉黑访客禁止登录
        accountRepo.findByPhoneHash(phoneHash).ifPresent(a -> {
            if ("blocked".equals(a.getStatus())) {
                throw new ApiException(ErrorCode.VISITOR_BLOCKED);
            }
        });

        VisitorAccount acc;
        try {
            acc = accountRepo.findByPhoneHash(phoneHash).orElseGet(() -> createAccount(phone, phoneHash));
        } catch (org.springframework.dao.DataIntegrityViolationException e) {
            // M5：并发同手机号注册竞态 → 唯一约束冲突，重读已创建的账号
            acc = accountRepo.findByPhoneHash(phoneHash)
                    .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL));
        }
        acc.setLastLoginAt(OffsetDateTime.now());
        accountRepo.save(acc);

        String access = jwtService.issueVisitorAccess(acc.getId(), phone, acc.getVisitorNo(), VISITOR_PERMS);
        String refresh = refreshService.issue(acc.getId(), deviceInfo);

        audit.logExplicit(acc.getId(), maskPhone(phone), "visitor_login",
                "visitor_account", acc.getId().toString(), "success");
        return new VisitorAuthDto.VisitorTokenResponse(
                access, refresh, acc.getId(), acc.getVisitorNo(), acc.getName(), acc.getAvatarSeed());
    }

    @Transactional
    public VisitorAuthDto.VisitorTokenResponse refresh(String rawRefresh, String deviceInfo) {
        String hash = VisitorRefreshTokenService.sha256(rawRefresh);
        VisitorRefreshToken token = refreshRepo.findAndLockByTokenHash(hash)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));

        if (token.getRevokedAt() != null) {
            // 已撤销令牌再次出现 = 泄露 → 撤销该访客全部令牌
            refreshService.revokeAllByVisitor(token.getVisitorAccountId());
            audit.logExplicit(token.getVisitorAccountId(), null, "visitor_refresh_reuse",
                    "visitor_refresh_token", token.getId().toString(), "reuse_detected");
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        if (!token.isValid()) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        VisitorAccount acc = accountRepo.findById(token.getVisitorAccountId())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if ("blocked".equals(acc.getStatus())) {
            throw new ApiException(ErrorCode.VISITOR_BLOCKED);
        }

        String access = jwtService.issueVisitorAccess(acc.getId(), decryptPhone(acc), acc.getVisitorNo(), VISITOR_PERMS);
        String newRaw = refreshService.issue(acc.getId(), deviceInfo);
        refreshService.revoke(token, null);
        return new VisitorAuthDto.VisitorTokenResponse(
                access, newRaw, acc.getId(), acc.getVisitorNo(), acc.getName(), acc.getAvatarSeed());
    }

    @Transactional
    public void logout(String rawRefresh) {
        if (rawRefresh == null || rawRefresh.isBlank()) {
            return;
        }
        String hash = VisitorRefreshTokenService.sha256(rawRefresh);
        refreshRepo.findAndLockByTokenHash(hash).ifPresent(t -> refreshService.revoke(t, null));
    }

    private VisitorAccount createAccount(String phone, String phoneHash) {
        VisitorAccount a = new VisitorAccount();
        a.setPhoneEnc(tx.encrypt(phone));
        a.setPhoneHash(phoneHash);
        String tail = phone.length() >= 4 ? phone.substring(phone.length() - 4) : "0000";
        String vno = genVisitorNo(tail);
        a.setVisitorNo(vno);
        a.setName(vno);
        a.setAvatarSeed(tail);
        a.setStatus("active");
        return accountRepo.save(a);
    }

    private String decryptPhone(VisitorAccount acc) {
        try {
            return tx.decrypt(acc.getPhoneEnc());
        } catch (Exception e) {
            return null;
        }
    }

    private String genVisitorNo(String tail) {
        for (int i = 0; i < 10; i++) {
            String no = "V" + tail + String.format("%02d", RNG.nextInt(100));
            if (!accountRepo.existsByVisitorNo(no)) {
                return no;
            }
        }
        return "V" + tail + (System.nanoTime() % 100);
    }

    private static String normalize(String phone) {
        String p = phone == null ? "" : phone.replaceAll("[^\\d]", "");
        if (p.startsWith("86")) {
            p = p.substring(2);
        }
        return p;
    }

    private static void validatePhone(String phone) {
        if (!phone.matches("^1[3-9]\\d{9}$")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        }
    }

    private static String maskPhone(String phone) {
        if (phone == null || phone.length() < 7) {
            return "***";
        }
        return phone.substring(0, 3) + "****" + phone.substring(phone.length() - 4);
    }
}
