package com.uten.imp.config;

import com.uten.imp.config.props.SecurityProperties;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.DefaultCorsProcessor;

import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 公共 AI 识别上传(ADR-133)的 CORS 预检: 浏览器跨源提交(Flutter Web 开发端口 53764、办公网页访问云端接口)
 * 必须放行 {@code X-Uten-File-Name} / {@code X-Uten-File-Type}, 否则预检失败、文件传不上来。
 */
class AiJobUploadCorsPreflightTest {

    private static final String ORIGIN = "http://localhost:53764";

    private static MockHttpServletResponse preflight(String requestedHeaders) throws Exception {
        SecurityProperties properties = new SecurityProperties();
        properties.setCorsAllowedOrigins(ORIGIN + ",http://localhost:8080");
        CorsConfigurationSource source = new SecurityConfig().corsConfigurationSource(properties);
        MockHttpServletRequest request = new MockHttpServletRequest("OPTIONS", "/api/ai/jobs");
        request.addHeader(HttpHeaders.ORIGIN, ORIGIN);
        request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "POST");
        request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, requestedHeaders);
        MockHttpServletResponse response = new MockHttpServletResponse();
        new DefaultCorsProcessor().processRequest(source.getCorsConfiguration(request), request, response);
        return response;
    }

    @Test
    void theAiJobUploadHeadersPassThePreflight() throws Exception {
        MockHttpServletResponse response =
                preflight("authorization,content-type,x-uten-file-name,x-uten-file-type");

        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN)).isEqualTo(ORIGIN);
        String allowed = String.valueOf(response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS))
                .toLowerCase(Locale.ROOT);
        assertThat(allowed).contains("authorization", "content-type", "x-uten-file-name", "x-uten-file-type");
    }

    @Test
    void headersOutsideTheAllowListAreNotEchoedBackSoTheBrowserBlocksThem() throws Exception {
        // 预检本身返回 200, 但只回显允许的头; 浏览器发现请求的头没被放行就拦下真正的上传。
        MockHttpServletResponse response = preflight("authorization,x-uten-something-else");

        String allowed = String.valueOf(response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS))
                .toLowerCase(Locale.ROOT);
        assertThat(allowed).contains("authorization").doesNotContain("x-uten-something-else");
    }
}
