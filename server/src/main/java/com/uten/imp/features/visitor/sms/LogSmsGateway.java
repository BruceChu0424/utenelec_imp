package com.uten.imp.features.visitor.sms;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * 开发期短信网关：打印日志（不真实发送）。
 * 验证码会出现在后端日志中，便于本地联调。
 */
@Slf4j
@Component
@ConditionalOnProperty(prefix = "uten.sms", name = "provider", havingValue = "log", matchIfMissing = true)
public class LogSmsGateway implements SmsGateway {

    @Override
    public boolean sendCode(String phone, String code) {
        log.info("[SMS-LOG] 访客验证码 -> 手机号={} 验证码={}（开发期未真实发送）", phone, code);
        return true;
    }
}
