package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.util.ChinaMobileNumber;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SmsProperties;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.visitor.dto.VisitorAuthDto;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.Set;

import static com.uten.imp.common.util.Strings.maskPhone;

/**
 * Visitor authentication: SMS code, login, refresh rotation and logout.
 */
@Service
@RequiredArgsConstructor
public class VisitorAuthService {

    private static final SecureRandom RNG = new SecureRandom();
    private static final Set<String> VISITOR_PERMS =
            Set.of("visitor:apply", "visitor:view");

    private final VisitorAccountRepository accountRepo;
    private final VisitorSmsService smsService;
    private final VisitorRefreshTokenService refreshService;
    private final VisitorRefreshTokenRepository refreshRepo;
    private final VisitorRefreshTransaction refreshTransaction;
    private final VisitorRefreshCompromiseService compromiseService;
    private final EmployeeSensitiveRepository employeeSensitiveRepo;
    private final JwtService jwtService;
    private final TxSessionVars tx;
    private final SmsProperties smsProps;
    private final AuditService audit;
    private final LoginRateLimiter rateLimiter;

    public VisitorAuthDto.SendCodeResponse sendCode(String phoneRaw, String ip) {
        String phone;
        try {
            phone = normalizePhone(phoneRaw);
        } catch (ApiException exception) {
            audit.logExplicit(null, null, "visitor_send_code_failed",
                    "visitor_auth", null, "invalid_phone");
            throw exception;
        }
        String code;
        try {
            rateLimiter.check(LoginRateLimiter.Scope.VISITOR_SEND_CODE, ip, phone);
            code = smsService.send(phone, "login");
        } catch (ApiException exception) {
            audit.logExplicit(null, maskPhone(phone), "visitor_send_code_failed",
                    "visitor_auth", null,
                    exception.getCode().name().toLowerCase(java.util.Locale.ROOT));
            throw exception;
        }
        String devCode = smsProps.isExposeCode()
                && "log".equalsIgnoreCase(smsProps.getProvider())
                ? code
                : null;
        audit.logExplicit(null, maskPhone(phone), "visitor_send_code",
                "visitor_auth", null, "success");
        return new VisitorAuthDto.SendCodeResponse(
                "login", smsService.codeTtlSeconds(), devCode);
    }

    @Transactional
    public VisitorAuthDto.VisitorTokenResponse login(String phoneRaw,
                                                     String code,
                                                     String deviceInfo,
                                                     String ip) {
        String phone;
        try {
            phone = normalizePhone(phoneRaw);
        } catch (ApiException exception) {
            audit.logExplicit(null, null, "visitor_login_failed",
                    "visitor_account", null, "invalid_phone");
            throw exception;
        }
        try {
            rateLimiter.check(LoginRateLimiter.Scope.VISITOR_LOGIN, ip, phone);
            smsService.verifyAndConsume(phone, code);
        } catch (ApiException exception) {
            audit.logExplicit(null, maskPhone(phone), "visitor_login_failed",
                    "visitor_account", null,
                    exception.getCode().name().toLowerCase(java.util.Locale.ROOT));
            throw exception;
        }

        String phoneHash = tx.hmac(phone);
        if (employeeSensitiveRepo.findByPhoneHash(phoneHash).isPresent()) {
            audit.logExplicit(null, maskPhone(phone), "visitor_login_failed",
                    "visitor_account", phoneHash, "is_employee");
            throw new ApiException(ErrorCode.IS_EMPLOYEE);
        }

        VisitorAccount account = accountRepo.findByPhoneHash(phoneHash).orElse(null);
        if (account != null) {
            tx.bindActor(account.getId(), account.getVisitorNo());
            if ("blocked".equals(account.getStatus())) {
                audit.logExplicit(account.getId(), account.getVisitorNo(),
                        "visitor_login_failed", "visitor_account",
                        account.getId().toString(), "visitor_blocked");
                throw new ApiException(ErrorCode.VISITOR_BLOCKED);
            }
        } else {
            account = newAccount(phone, phoneHash);
            tx.bindActor(account.getId(), account.getVisitorNo());
            try {
                account = accountRepo.save(account);
            } catch (org.springframework.dao.DataIntegrityViolationException exception) {
                // Concurrent first login: rely on the unique phone hash and reload the winner.
                account = accountRepo.findByPhoneHash(phoneHash)
                        .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL));
                tx.bindActor(account.getId(), account.getVisitorNo());
            }
        }

        account.setLastLoginAt(OffsetDateTime.now());
        accountRepo.save(account);

        String access = jwtService.issueVisitorAccess(
                account.getId(), account.getVisitorNo(), account.getAvatarSeed(), VISITOR_PERMS);
        String refresh = refreshService.issue(account.getId(), deviceInfo);
        audit.logExplicit(account.getId(), maskPhone(phone), "visitor_login",
                "visitor_account", account.getId().toString(), "success");

        return new VisitorAuthDto.VisitorTokenResponse(
                access,
                refresh,
                account.getId(),
                account.getVisitorNo(),
                account.getName(),
                account.getAvatarSeed());
    }

    /**
     * Reuse revocation commits before this method reports UNAUTHORIZED.
     */
    public VisitorAuthDto.VisitorTokenResponse refresh(String rawRefresh,
                                                       String deviceInfo) {
        VisitorRefreshTransaction.Outcome outcome;
        try {
            outcome = refreshTransaction.rotate(rawRefresh, deviceInfo);
        } catch (ApiException ex) {
            audit.logExplicit(null, null, "visitor_refresh_failed",
                    "visitor_refresh_tokens", null,
                    ex.getCode().name().toLowerCase(java.util.Locale.ROOT));
            throw ex;
        }
        if (outcome.reuseDetected()) {
            compromiseService.revoke(outcome.subjectId(), outcome.tokenId());
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        VisitorAccount account = outcome.account();
        String access = jwtService.issueVisitorAccess(
                account.getId(),
                account.getVisitorNo(),
                account.getAvatarSeed(),
                VISITOR_PERMS);
        audit.logExplicit(account.getId(), account.getVisitorNo(),
                "visitor_refresh_token", "visitor_refresh_tokens",
                outcome.tokenId().toString(), "success");
        return new VisitorAuthDto.VisitorTokenResponse(
                access,
                outcome.newRefreshToken(),
                account.getId(),
                account.getVisitorNo(),
                account.getName(),
                account.getAvatarSeed());
    }

    @Transactional
    public void logout(String rawRefresh) {
        if (rawRefresh == null || rawRefresh.isBlank()) {
            audit.logExplicit(null, null, "visitor_logout_failed",
                    "visitor_refresh_tokens", null, "missing_token");
            return;
        }
        var token = refreshRepo.findAndLockByTokenHash(HashUtil.sha256(rawRefresh));
        if (token.isEmpty()) {
            audit.logExplicit(null, null, "visitor_logout_failed",
                    "visitor_refresh_tokens", null, "token_not_found");
            return;
        }
        refreshService.revoke(token.get(), null);
        audit.logExplicit(token.get().getVisitorAccountId(), null,
                "visitor_logout", "visitor_refresh_tokens",
                token.get().getId().toString(), "success");
    }

    private VisitorAccount newAccount(String phone, String phoneHash) {
        VisitorAccount account = new VisitorAccount();
        account.setPhoneEnc(tx.encrypt(phone));
        account.setPhoneHash(phoneHash);
        String tail = phone.length() >= 4
                ? phone.substring(phone.length() - 4)
                : "0000";
        String visitorNo = generateVisitorNo(tail);
        account.setVisitorNo(visitorNo);
        account.setName(visitorNo);
        account.setAvatarSeed(tail);
        account.setStatus("active");
        return account;
    }

    private String generateVisitorNo(String tail) {
        for (int attempt = 0; attempt < 10; attempt++) {
            String visitorNo = "V" + tail
                    + String.format("%02d", RNG.nextInt(100));
            if (!accountRepo.existsByVisitorNo(visitorNo)) {
                return visitorNo;
            }
        }
        return "V" + tail + (System.nanoTime() % 100);
    }

    private static String normalizePhone(String phone) {
        return ChinaMobileNumber.normalize(phone)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "中国大陆手机号格式不正确"));
    }
}
