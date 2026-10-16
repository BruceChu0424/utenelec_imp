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

    @Test void oneGatewayKeepsTheWholeConfigurationSnapshotDuringConcurrentSettingsChanges() throws Exception {
        SmsProperties properties = configuredProperties();
        when(client.sendSmsWithOptions(any(), any())).thenReturn(new SendSmsResponse().setBody(new SendSmsResponseBody().setCode("OK")));
        AliyunSmsGateway gateway = new AliyunSmsGateway(properties, new ObjectMapper(), client);
        properties.setSignName("changed-sign");
        properties.setTemplateCode("SMS_CHANGED");
        gateway.sendCode("13800138000", "123456");
        ArgumentCaptor<SendSmsRequest> sent = ArgumentCaptor.forClass(SendSmsRequest.class);
        org.mockito.Mockito.verify(client).sendSmsWithOptions(sent.capture(), any());
        assertThat(sent.getValue().getSignName()).isEqualTo("优藤");
        assertThat(sent.getValue().getTemplateCode()).isEqualTo("SMS_123");
    }
    @Test void missingProviderAcknowledgementIsUncertainRatherThanInvalidatingPossiblyDeliveredOtp() throws Exception {
        for(SendSmsResponse response:new SendSmsResponse[]{null,new SendSmsResponse(),new SendSmsResponse().setBody(new SendSmsResponseBody())}) {
            when(client.sendSmsWithOptions(any(),any())).thenReturn(response);
            assertThat(new AliyunSmsGateway(configuredProperties(),new ObjectMapper(),client).sendCode("13800138000","123456"))
                    .isEqualTo(SmsSendResult.UNCERTAIN);
        }
        org.mockito.Mockito.verify(client,org.mockito.Mockito.times(3)).sendSmsWithOptions(any(),any());
    }
    @Test void sdkExceptionCannotLeakCredentialsOtpOrFullPhoneIntoLogs() throws Exception {
        var logger=(ch.qos.logback.classic.Logger)org.slf4j.LoggerFactory.getLogger(AliyunSmsGateway.class);
        var appender=new ch.qos.logback.core.read.ListAppender<ch.qos.logback.classic.spi.ILoggingEvent>();
        var previous=logger.getLevel();appender.start();logger.addAppender(appender);logger.setLevel(ch.qos.logback.classic.Level.INFO);
        try {
            when(client.sendSmsWithOptions(any(),any())).thenThrow(new RuntimeException("fixture-secret 123456 13800138000"));
            assertThat(new AliyunSmsGateway(configuredProperties(),new ObjectMapper(),client).sendCode("13800138000","123456"))
                    .isEqualTo(SmsSendResult.UNCERTAIN);
            assertThat(appender.list).isNotEmpty();
            appender.list.forEach(event->assertThat(event.getFormattedMessage()).doesNotContain("fixture-secret","123456","13800138000"));
        } finally { logger.detachAppender(appender);logger.setLevel(previous);appender.stop(); }
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
