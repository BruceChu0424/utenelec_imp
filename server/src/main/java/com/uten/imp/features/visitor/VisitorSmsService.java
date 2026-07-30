package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.visitor.sms.SmsGateway;
import com.uten.imp.features.visitor.sms.SmsSendResult;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.security.SecureRandom;

/**
 * 访客短信验证码：生成 6 位 → 绑定手机号/场景做 HMAC 入库 → 经 SmsGateway 发送。
 * 限流：同号 60s 间隔 + 每日上限。校验比对哈希、消费、限制尝试次数。
 */
@Service
@RequiredArgsConstructor
public class VisitorSmsService {

    private static final SecureRandom RNG = new SecureRandom();
    private final VisitorOtpVerifier otpVerifier;
    private final SmsGateway gateway;
    private final SystemSettingsService settings;
    private final VisitorSmsIssuanceTransaction issuanceTransaction;

    /** 生成并发送验证码；返回明文 code（log 网关时 controller 可回传联调）。 */
    public String send(String phone, String scene) {
        String code = String.format("%06d", RNG.nextInt(1_000_000));
        VisitorSmsIssuanceTransaction.Issuance issuance =
                issuanceTransaction.prepare(phone, scene, code);
        SmsSendResult result = gateway.sendCode(phone, code);
        if (result == SmsSendResult.REJECTED) {
            issuanceTransaction.reject(issuance.id());
            throw new ApiException(ErrorCode.BUSINESS);
        }
        // UNCERTAIN 保留已提交 OTP：供应商可能已收，自动重发/作废会制造不可用验证码。
        return code;
    }

    /** 校验并消费验证码（手机号 + 验证码均匹配最新未消费记录）。 */
    public void verifyAndConsume(String phone, String code) {
        VisitorOtpVerifier.Result result = otpVerifier.verify(phone, code);
        if (result == VisitorOtpVerifier.Result.EXPIRED) {
            throw new ApiException(ErrorCode.SMS_CODE_EXPIRED);
        }
        if (result != VisitorOtpVerifier.Result.VALID) {
            throw new ApiException(ErrorCode.SMS_CODE_INVALID);
        }
    }

    public int codeTtlSeconds() {
        return settings.readInt("sms_code_ttl_minutes", 5) * 60;
    }

    static String otpMacInput(String phone, String scene, String code) {
        return "visitor-otp:v1:" + phone + ":" + scene + ":" + code;
    }
}
