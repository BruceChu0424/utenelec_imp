package com.uten.imp.config;

import org.junit.jupiter.api.Test;
import org.springframework.boot.security.autoconfigure.actuate.web.servlet.ManagementWebSecurityAutoConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.flyway.autoconfigure.FlywayAutoConfiguration;
import org.springframework.boot.jdbc.autoconfigure.DataSourceAutoConfiguration;
import org.springframework.boot.hibernate.autoconfigure.HibernateJpaAutoConfiguration;
import org.springframework.boot.security.autoconfigure.SecurityAutoConfiguration;
import org.springframework.boot.security.autoconfigure.UserDetailsServiceAutoConfiguration;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertTrue;

/** Exercises the real embedded Tomcat parser, not MockMvc's synthetic request. */
@SpringBootTest(
        classes = RequestHeaderBudgetIntegrationTest.TestApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = "spring.profiles.active=dev")
class RequestHeaderBudgetIntegrationTest {

    @LocalServerPort
    private int port;

    @Test
    void acceptsMeasuredEnvelopeButRejectsUnboundedHeaders() throws Exception {
        String acceptedStatus = sendRawRequest(12 * 1_024);
        String rejectedStatus = sendRawRequest(18 * 1_024);

        assertTrue(acceptedStatus.contains(" 200 "), acceptedStatus);
        assertTrue(
                rejectedStatus.contains(" 400 ") || rejectedStatus.contains(" 431 "),
                rejectedStatus);
    }

    private String sendRawRequest(int fillerBytes) throws Exception {
        try (Socket socket = new Socket("127.0.0.1", port)) {
            socket.setSoTimeout(5_000);
            StringBuilder request = new StringBuilder()
                    .append("GET /header-budget-probe HTTP/1.1\r\n")
                    .append("Host: 127.0.0.1:").append(port).append("\r\n");
            int remaining = fillerBytes;
            int fieldIndex = 0;
            while (remaining > 0) {
                int fieldBytes = Math.min(3_500, remaining);
                request.append("X-Uten-Header-Budget-")
                        .append(fieldIndex++)
                        .append(": ")
                        .append("x".repeat(fieldBytes))
                        .append("\r\n");
                remaining -= fieldBytes;
            }
            request.append("Connection: close\r\n\r\n");
            socket.getOutputStream().write(request.toString().getBytes(StandardCharsets.US_ASCII));
            socket.getOutputStream().flush();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                    socket.getInputStream(), StandardCharsets.US_ASCII))) {
                String statusLine = reader.readLine();
                return statusLine == null ? "connection closed without an HTTP status" : statusLine;
            }
        }
    }

    @Configuration(proxyBeanMethods = false)
    @EnableAutoConfiguration(exclude = {
            DataSourceAutoConfiguration.class,
            HibernateJpaAutoConfiguration.class,
            FlywayAutoConfiguration.class,
            SecurityAutoConfiguration.class,
            // Boot 4 把 Servlet 默认安全链拆成独立的 ServletWebSecurityAutoConfiguration，
            // 不排掉它会对裸请求返回 401，探针拿不到头部预算的真实行为。
            org.springframework.boot.security.autoconfigure.web.servlet.ServletWebSecurityAutoConfiguration.class,
            UserDetailsServiceAutoConfiguration.class,
            ManagementWebSecurityAutoConfiguration.class
    })
    @Import(HeaderBudgetProbeController.class)
    static class TestApplication {
    }
}

@RestController
class HeaderBudgetProbeController {

    @GetMapping("/header-budget-probe")
    String probe() {
        return "ok";
    }
}
