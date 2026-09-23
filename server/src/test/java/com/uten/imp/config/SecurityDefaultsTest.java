package com.uten.imp.config;

import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.config.props.SmsProperties;
import jakarta.servlet.http.HttpServletRequest;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SecurityDefaultsTest {

    @Test
    void corsIsBearerOnlyAndDoesNotEnableCredentialedCrossOriginRequests() {
        SecurityProperties properties = new SecurityProperties();
        properties.setCorsAllowedOrigins(
                " https://app.example.test ,https://admin.example.test ");
        CorsConfigurationSource source =
                new SecurityConfig().corsConfigurationSource(properties);
        HttpServletRequest request = new MockHttpServletRequest("GET", "/api/me");
        CorsConfiguration configuration = source.getCorsConfiguration(request);

        assertEquals(
                java.util.List.of(
                        "https://app.example.test",
                        "https://admin.example.test"),
                configuration.getAllowedOrigins());
        assertEquals(
                java.util.List.of(
                        "Authorization",
                        "Content-Type",
                        "Accept",
                        "X-Uten-Attachment-Upload-Token",
                        // ADR-110: 敏感操作的一次性再认证凭证随请求头发送。
                        "X-Uten-Step-Up",
                        // ADR-110: 用户已有一段时间没操作时发出的请求 (轮询/定时刷新) 不续期会话。
                        "X-Uten-Automatic",
                        "X-Uten-Operation-Id",
                        "X-Uten-Audit-Context"),
                configuration.getAllowedHeaders());
        assertEquals(
                java.util.List.of(
                        "Content-Disposition",
                        // 密码哈希闸门满时 503 带 Retry-After, 前端据此稍后重试。
                        "Retry-After",
                        "X-Uten-Audit-Request-Id",
                        "X-Uten-Operation-Id"),
                configuration.getExposedHeaders());
        assertFalse(Boolean.TRUE.equals(configuration.getAllowCredentials()));
    }

    @Test
    void smsDefaultsToFailClosedAndNeverExposesOtp() {
        SmsProperties properties = new SmsProperties();

        assertEquals("disabled", properties.getProvider());
        assertFalse(properties.isExposeCode());
    }

    @Test
    void swaggerDefaultsToFailClosed() {
        assertFalse(new SecurityProperties().isSwaggerEnabled());
    }

    @Test
    void corsRejectsWildcardEmptyAndPathOrigins() {
        SecurityConfig config = new SecurityConfig();
        for (String invalid : java.util.List.of(
                "*", " ", "https://app.example.test/api", "file:///tmp/app")) {
            SecurityProperties properties = new SecurityProperties();
            properties.setCorsAllowedOrigins(invalid);
            assertThrows(
                    IllegalStateException.class,
                    () -> config.corsConfigurationSource(properties),
                    invalid);
        }
    }
}
