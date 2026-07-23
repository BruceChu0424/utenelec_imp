package com.uten.imp.features.visitor.sms;

import com.uten.imp.config.props.SmsProperties;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * 阿里云短信网关（stub）。
 * TODO 生产：调用阿里云 dysmsapi SendSms（HMAC-SHA1 签名 + 模板 ${code}），需引入 aliyun-java-sdk-core/dysmsapi。
 */
@Slf4j
@Component
@RequiredArgsConstructor
@ConditionalOnProperty(prefix = "uten.sms", name = "provider", havingValue = "aliyun")
public class AliyunSmsGateway implements SmsGateway {

    private final SmsProperties props;

    @Override
    public boolean sendCode(String phone, String code) {
        log.warn("[SMS-ALIYUN] 未实现真实发送（stub）：phone={} sign={} template={}",
                phone, props.getSignName(), props.getTemplateCode());
        return false;
    }
}
