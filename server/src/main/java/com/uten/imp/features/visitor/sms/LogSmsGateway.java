package com.uten.imp.features.visitor.sms;

import com.uten.imp.common.util.ChinaMobileNumber;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

/**
 * 开发期短信网关（不真实发送）。
 * 明文验证码仅可由显式启用的开发响应字段返回，不写入可长期留存的日志。
 */
@Slf4j
@Component
@Profile("dev")
@ConditionalOnProperty(prefix = "uten.sms", name = "provider", havingValue = "log")
public class LogSmsGateway implements SmsGateway {

    @Override
    public SmsSendResult sendCode(String phone, String code) {
        log.info("[SMS-LOG] 已模拟发送访客验证码到 phoneSuffix={}（验证码不写日志）",
                ChinaMobileNumber.maskedSuffix(phone));
        return SmsSendResult.ACCEPTED;
    }
}
