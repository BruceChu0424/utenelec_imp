package com.uten.imp.features.visitor.sms;

import com.aliyun.dysmsapi20170525.Client;
import com.aliyun.dysmsapi20170525.models.SendSmsRequest;
import com.aliyun.dysmsapi20170525.models.SendSmsResponse;
import com.aliyun.dysmsapi20170525.models.SendSmsResponseBody;
import com.aliyun.teaopenapi.models.Config;
import com.aliyun.teautil.models.RuntimeOptions;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.ChinaMobileNumber;
import com.uten.imp.config.props.SmsProperties;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

import java.util.Map;

/**
 * 阿里云国内短信网关（Dysmsapi 2017-05-25 V2 SDK）。
 *
 * <p>SDK Client 是线程安全对象，应用生命周期内只创建一次。SendSms 不提供幂等能力，因此显式关闭
 * SDK 自动重试；调用结果不确定时由短信回执/运营平台核查，不能盲目重发验证码。
 */
@Slf4j
@Component
@ConditionalOnProperty(prefix = "uten.sms", name = "provider", havingValue = "aliyun")
public class AliyunSmsGateway implements SmsGateway {

    private static final RuntimeOptions RUNTIME_OPTIONS = new RuntimeOptions()
            .setAutoretry(false)
            .setMaxAttempts(1)
            .setConnectTimeout(3_000)
            .setReadTimeout(5_000)
            .setKeepAlive(true);

    private final SmsProperties properties;
    private final ObjectMapper objectMapper;
    private final Client client;

    public AliyunSmsGateway(SmsProperties properties, ObjectMapper objectMapper) {
        this(properties, objectMapper, createClient(properties));
    }

    AliyunSmsGateway(SmsProperties properties, ObjectMapper objectMapper, Client client) {
        this.properties = properties;
        this.objectMapper = objectMapper;
        this.client = client;
    }

    @Override
    public SmsSendResult sendCode(String phone, String code) {
        try {
            SendSmsRequest request = new SendSmsRequest()
                    .setPhoneNumbers(phone)
                    .setSignName(properties.getSignName())
                    .setTemplateCode(properties.getTemplateCode())
                    .setTemplateParam(objectMapper.writeValueAsString(Map.of("code", code)));
            SendSmsResponse response = client.sendSmsWithOptions(request, RUNTIME_OPTIONS);
            SendSmsResponseBody body = response == null ? null : response.getBody();
            if (body != null && "OK".equals(body.getCode())) {
                log.info(
                        "Aliyun SMS accepted: phoneSuffix={}, requestId={}, bizId={}",
                        ChinaMobileNumber.maskedSuffix(phone),
                        body.getRequestId(),
                        body.getBizId());
                return SmsSendResult.ACCEPTED;
            }
            log.warn(
                    "Aliyun SMS rejected: phoneSuffix={}, resultCode={}, requestId={}",
                    ChinaMobileNumber.maskedSuffix(phone),
                    body == null ? "EMPTY_RESPONSE" : body.getCode(),
                    body == null ? null : body.getRequestId());
        } catch (JsonProcessingException e) {
            // code 是纯数字，正常不会到这里；仍按 fail-closed 处理且不记录模板参数。
            log.error("Aliyun SMS template serialization failed: type={}", e.getClass().getSimpleName());
            return SmsSendResult.REJECTED;
        } catch (Exception e) {
            // SDK 异常消息可能带请求参数，不直接写日志。
            log.error(
                    "Aliyun SMS request result uncertain: phoneSuffix={}, type={}",
                    ChinaMobileNumber.maskedSuffix(phone),
                    e.getClass().getSimpleName());
            return SmsSendResult.UNCERTAIN;
        }
        return SmsSendResult.REJECTED;
    }

    private static Client createClient(SmsProperties properties) {
        requireConfigured("UTEN_SMS_ACCESS_KEY_ID", properties.getAccessKeyId());
        requireConfigured("UTEN_SMS_ACCESS_KEY_SECRET", properties.getAccessKeySecret());
        requireConfigured("UTEN_SMS_SIGN_NAME", properties.getSignName());
        requireConfigured("UTEN_SMS_TEMPLATE_CODE", properties.getTemplateCode());
        requireConfigured("UTEN_SMS_ENDPOINT", properties.getEndpoint());
        try {
            Config config = new Config()
                    .setAccessKeyId(properties.getAccessKeyId())
                    .setAccessKeySecret(properties.getAccessKeySecret())
                    .setEndpoint(properties.getEndpoint());
            return new Client(config);
        } catch (Exception e) {
            throw new IllegalStateException("无法初始化阿里云短信客户端", e);
        }
    }

    private static void requireConfigured(String name, String value) {
        if (!StringUtils.hasText(value)) {
            throw new IllegalStateException(name + " must be configured when UTEN_SMS_PROVIDER=aliyun");
        }
    }

}
