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
                java.util.List.of("Authorization", "Content-Type", "Accept"),
                configuration.getAllowedHeaders());
        assertFalse(Boolean.TRUE.equals(configuration.getAllowCredentials()));
    }

    @Test
    void smsDefaultsToFailClosedAndNeverExposesOtp() {
        SmsProperties properties = new SmsProperties();

        assertEquals("disabled", properties.getProvider());
        assertFalse(properties.isExposeCode());
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
