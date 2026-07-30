package com.uten.imp.features.visitor.sms;

import com.aliyun.dysmsapi20170525.Client;
import com.aliyun.dysmsapi20170525.models.SendSmsRequest;
import com.aliyun.dysmsapi20170525.models.SendSmsResponse;
import com.aliyun.dysmsapi20170525.models.SendSmsResponseBody;
import com.aliyun.teautil.models.RuntimeOptions;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.SmsProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AliyunSmsGatewayTest {

    @Mock
    private Client client;

    @Test
    void sendsJsonTemplateWithoutAutomaticRetry() throws Exception {
        SmsProperties properties = configuredProperties();
        SendSmsResponse response = new SendSmsResponse().setBody(
                new SendSmsResponseBody()
                        .setCode("OK")
                        .setRequestId("request-1")
                        .setBizId("biz-1"));
        when(client.sendSmsWithOptions(any(), any())).thenReturn(response);
        AliyunSmsGateway gateway = new AliyunSmsGateway(properties, new ObjectMapper(), client);

        assertThat(gateway.sendCode("13800138000", "123456"))
                .isEqualTo(SmsSendResult.ACCEPTED);

        ArgumentCaptor<SendSmsRequest> request = ArgumentCaptor.forClass(SendSmsRequest.class);
        ArgumentCaptor<RuntimeOptions> runtime = ArgumentCaptor.forClass(RuntimeOptions.class);
        org.mockito.Mockito.verify(client).sendSmsWithOptions(request.capture(), runtime.capture());
        assertThat(request.getValue().getPhoneNumbers()).isEqualTo("13800138000");
        assertThat(request.getValue().getSignName()).isEqualTo("优藤");
        assertThat(request.getValue().getTemplateCode()).isEqualTo("SMS_123");
        assertThat(request.getValue().getTemplateParam()).isEqualTo("{\"code\":\"123456\"}");
        assertThat(runtime.getValue().getAutoretry()).isFalse();
        assertThat(runtime.getValue().getMaxAttempts()).isEqualTo(1);
    }

    @Test
    void rejectsProviderErrorWithoutRetrying() throws Exception {
        when(client.sendSmsWithOptions(any(), any())).thenReturn(
                new SendSmsResponse().setBody(
                        new SendSmsResponseBody()
                                .setCode("isv.BUSINESS_LIMIT_CONTROL")
                                .setRequestId("request-2")));
        AliyunSmsGateway gateway =
                new AliyunSmsGateway(configuredProperties(), new ObjectMapper(), client);

        assertThat(gateway.sendCode("13800138000", "123456"))
                .isEqualTo(SmsSendResult.REJECTED);
        org.mockito.Mockito.verify(client).sendSmsWithOptions(any(), any());
    }

    @Test
    void marksTransportFailureUncertainWithoutAutomaticRetry() throws Exception {
        when(client.sendSmsWithOptions(any(), any()))
                .thenThrow(new RuntimeException("connection reset"));
        AliyunSmsGateway gateway =
                new AliyunSmsGateway(configuredProperties(), new ObjectMapper(), client);

        assertThat(gateway.sendCode("13800138000", "123456"))
                .isEqualTo(SmsSendResult.UNCERTAIN);
        org.mockito.Mockito.verify(client).sendSmsWithOptions(any(), any());
    }

    @Test
    void failsFastWhenAliyunCredentialsAreMissing() {
        assertThatThrownBy(() -> new AliyunSmsGateway(new SmsProperties(), new ObjectMapper()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("UTEN_SMS_ACCESS_KEY_ID");
    }

    private static SmsProperties configuredProperties() {
        SmsProperties properties = new SmsProperties();
        properties.setAccessKeyId("test-id");
        properties.setAccessKeySecret("test-secret");
        properties.setSignName("优藤");
        properties.setTemplateCode("SMS_123");
        properties.setEndpoint("dysmsapi.aliyuncs.com");
        return properties;
    }
}
