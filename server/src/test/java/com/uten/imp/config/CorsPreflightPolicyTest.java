package com.uten.imp.config;

import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.security.StepUpInterceptor;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.http.HttpHeaders;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.web.cors.DefaultCorsProcessor;

import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

/** The LAN proxy forwards preflight; Spring's existing origin/header policy remains authoritative. */
class CorsPreflightPolicyTest {
    private static final String ORIGIN = "https://allowed.example.test";

    private MockHttpServletResponse preflight(String path, String method, String origin) throws Exception {
        var properties = new SecurityProperties();
        properties.setCorsAllowedOrigins(ORIGIN);
        var source = new SecurityConfig().corsConfigurationSource(properties);
        var request = new MockHttpServletRequest("OPTIONS", path);
        request.addHeader(HttpHeaders.ORIGIN, origin);
        request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, method);
        request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS,
                "authorization,content-type," + StepUpInterceptor.HEADER.toLowerCase(Locale.ROOT));
        var response = new MockHttpServletResponse();
        new DefaultCorsProcessor().processRequest(source.getCorsConfiguration(request), request, response);
        return response;
    }

    @ParameterizedTest
    @CsvSource({"/api/admin/system-settings,GET", "/api/admin/system-settings,PUT", "/api/auth/step-up,POST"})
    void configuredOriginCanPreflightSensitiveActions(String path, String method) throws Exception {
        var response = preflight(path, method, ORIGIN);
        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN)).isEqualTo(ORIGIN);
        assertThat(response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_CREDENTIALS)).isNull();
        assertThat(response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS).toLowerCase(Locale.ROOT))
                .contains("authorization", "content-type", StepUpInterceptor.HEADER.toLowerCase(Locale.ROOT));
    }

    @ParameterizedTest
    @CsvSource({"/api/admin/system-settings,GET", "/api/admin/system-settings,PUT", "/api/auth/step-up,POST"})
    void unconfiguredOriginCannotAcquireCorsPermission(String path, String method) throws Exception {
        var response = preflight(path, method,
                "https://untrusted.example.test");
        assertThat(response.getStatus()).isEqualTo(403);
        assertThat(response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN)).isNull();
    }

    @Test
    void forwardingOptionsDoesNotGrantAnUnapprovedActualMethod() throws Exception {
        var response = preflight("/api/admin/system-settings", "TRACE", ORIGIN);
        assertThat(response.getStatus()).isEqualTo(403);
        assertThat(response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN)).isNull();
    }
}
