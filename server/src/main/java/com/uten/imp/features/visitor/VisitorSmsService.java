package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SmsProperties;
import com.uten.imp.features.visitor.sms.SmsGateway;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.OffsetDateTime;

/**
 * 访客短信验证码：生成 6 位 → sha256 入库 → 经 SmsGateway 发送。
 * 限流：同号 60s 间隔 + 每日上限。校验比对哈希、消费、限制尝试次数。
 */
@Service
@RequiredArgsConstructor
public class VisitorSmsService {

    private static final SecureRandom RNG = new SecureRandom();
    private static final int MAX_ATTEMPTS = 5;

    private final VisitorSmsCodeRepository smsRepo;
    private final SmsGateway gateway;
    private final SmsProperties props;

    /** 生成并发送验证码；返回明文 code（log 网关时 controller 可回传联调）。 */
    @Transactional
    public String send(String phone, String scene) {
        smsRepo.findTopByPhoneOrderByCreatedAtDesc(phone).ifPresent(last -> {
            if (last.getCreatedAt().isAfter(OffsetDateTime.now().minusSeconds(props.getSendIntervalSeconds()))) {
                throw new ApiException(ErrorCode.SMS_RATE_LIMITED);
            }
        });
        long todayCount = smsRepo.countByPhoneAndCreatedAtAfter(phone, OffsetDateTime.now().minusDays(1));
        if (todayCount >= props.getDailyLimit()) {
            throw new ApiException(ErrorCode.SMS_RATE_LIMITED);
        }

        String code = String.format("%06d", RNG.nextInt(1_000_000));
        VisitorSmsCode entity = new VisitorSmsCode();
        entity.setPhone(phone);
        entity.setCodeHash(sha256(code));
        entity.setScene(scene);
        entity.setAttempts(0);
        entity.setExpiresAt(OffsetDateTime.now().plusMinutes(props.getCodeTtlMinutes()));
        smsRepo.save(entity);

        if (!gateway.sendCode(phone, code)) {
            throw new ApiException(ErrorCode.BUSINESS);
        }
        return code;
    }

    /** 校验并消费验证码（手机号 + 验证码均匹配最新未消费记录）。 */
    @Transactional
    public void verifyAndConsume(String phone, String code) {
        VisitorSmsCode latest = smsRepo.findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(phone)
                .orElseThrow(() -> new ApiException(ErrorCode.SMS_CODE_INVALID));
        latest.setAttempts(latest.getAttempts() + 1);
        smsRepo.save(latest);
        if (latest.getAttempts() > MAX_ATTEMPTS) {
            throw new ApiException(ErrorCode.SMS_CODE_INVALID);
        }
        if (!MessageDigest.isEqual(sha256(code).getBytes(StandardCharsets.UTF_8),
                latest.getCodeHash().getBytes(StandardCharsets.UTF_8))) {
            throw new ApiException(ErrorCode.SMS_CODE_INVALID);
        }
        if (latest.getExpiresAt().isBefore(OffsetDateTime.now())) {
            throw new ApiException(ErrorCode.SMS_CODE_EXPIRED);
        }
        latest.setConsumedAt(OffsetDateTime.now());
        smsRepo.save(latest);
    }

    public int codeTtlSeconds() {
        return props.getCodeTtlMinutes() * 60;
    }

    private static String sha256(String raw) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] h = md.digest(raw.getBytes(StandardCharsets.UTF_8));
            return java.util.Base64.getEncoder().encodeToString(h);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
