package com.uten.imp.features.visitor;

import com.uten.imp.security.TxSessionVars;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.OffsetDateTime;

/**
 * Atomically verifies and consumes the latest visitor OTP.
 *
 * <p>The method returns a result instead of throwing. That lets its independent
 * transaction commit the attempt count before the caller maps a failure to an API exception.
 */
@Service
public class VisitorOtpVerifier {

    static final int MAX_ATTEMPTS = 5;

    private final VisitorSmsCodeRepository smsRepo;
    private final TxSessionVars tx;

    public VisitorOtpVerifier(VisitorSmsCodeRepository smsRepo, TxSessionVars tx) {
        this.smsRepo = smsRepo;
        this.tx = tx;
    }

    public enum Result {
        VALID,
        INVALID,
        EXPIRED
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public Result verify(String phone, String code) {
        VisitorSmsCode latest = smsRepo
                .findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(phone)
                .orElse(null);
        if (latest == null || latest.getAttempts() >= MAX_ATTEMPTS) {
            return Result.INVALID;
        }

        latest.setAttempts(latest.getAttempts() + 1);
        OffsetDateTime now = OffsetDateTime.now();
        boolean matches = code != null && MessageDigest.isEqual(
                tx.hmac(VisitorSmsService.otpMacInput(
                                phone, latest.getScene(), code))
                        .getBytes(StandardCharsets.UTF_8),
                latest.getCodeHash().getBytes(StandardCharsets.UTF_8));

        if (latest.getExpiresAt().isBefore(now)) {
            latest.setConsumedAt(now);
            smsRepo.save(latest);
            return Result.EXPIRED;
        }

        if (!matches) {
            if (latest.getAttempts() >= MAX_ATTEMPTS) {
                latest.setConsumedAt(now);
            }
            smsRepo.save(latest);
            return Result.INVALID;
        }

        latest.setConsumedAt(now);
        smsRepo.save(latest);
        return Result.VALID;
    }
}
