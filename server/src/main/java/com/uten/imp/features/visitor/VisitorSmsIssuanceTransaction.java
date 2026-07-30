package com.uten.imp.features.visitor;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.ChinaMobileNumber;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 短信验证码本地签发事务。
 *
 * <p>同号 advisory lock、频率检查和 OTP 哈希持久化在这里原子提交；外部短信调用必须在
 * 此事务返回后发生，避免供应商已接收但本地事务回滚。
 */
@Component
@RequiredArgsConstructor
public class VisitorSmsIssuanceTransaction {

    private final VisitorSmsCodeRepository smsRepo;
    private final SystemSettingsService settings;
    private final TxSessionVars tx;
    private final VisitorSmsSendLock sendLock;

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public Issuance prepare(String phone, String scene, String code) {
        String canonicalPhone = ChinaMobileNumber.normalize(phone)
                .filter(canonical -> canonical.equals(phone))
                .orElseThrow(() -> new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "短信签发必须使用规范化的中国大陆手机号"));
        sendLock.lock(tx.hmac("visitor-sms-send:v1:" + canonicalPhone));

        OffsetDateTime now = OffsetDateTime.now();
        smsRepo.findTopByPhoneOrderByCreatedAtDesc(canonicalPhone).ifPresent(last -> {
            if (last.getCreatedAt().isAfter(now.minusSeconds(
                    settings.readInt("sms_send_interval_seconds", 60)))) {
                throw new ApiException(ErrorCode.SMS_RATE_LIMITED);
            }
        });
        long todayCount = smsRepo.countByPhoneAndCreatedAtAfter(
                canonicalPhone,
                BusinessTime.startOfDay(BusinessTime.today()));
        if (todayCount >= settings.readInt("sms_daily_limit", 10)) {
            throw new ApiException(ErrorCode.SMS_RATE_LIMITED);
        }

        VisitorSmsCode entity = new VisitorSmsCode();
        entity.setPhone(canonicalPhone);
        entity.setCodeHash(tx.hmac(
                VisitorSmsService.otpMacInput(canonicalPhone, scene, code)));
        entity.setScene(scene);
        entity.setAttempts(0);
        entity.setExpiresAt(now.plusMinutes(
                settings.readInt("sms_code_ttl_minutes", 5)));
        smsRepo.save(entity);
        return new Issuance(entity.getId());
    }

    /** 供应商明确拒绝时删除未发送记录，让用户可重试；不处理网络结果不确定的请求。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void reject(UUID issuanceId) {
        smsRepo.deleteById(issuanceId);
    }

    public record Issuance(UUID id) {}
}
