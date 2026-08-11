package com.uten.imp.security;

import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class JwtVisitorPiiMinimizationTest {

    @Test
    void visitorAccessTokenUsesVisitorNumberInsteadOfRawPhone() {
        JwtProperties properties = new JwtProperties();
        properties.setSecret("0123456789abcdef0123456789abcdef");
        properties.setIssuer("uten-test");
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readLong("jwt_access_ttl_minutes", 15)).thenReturn(15L);
        JwtService service = new JwtService(properties, settings);

        String token = service.issueVisitorAccess(
                UUID.randomUUID(), "V800012", "8000", Set.of("visitor:view"));
        Claims claims = service.parse(token);

        assertEquals("V800012", claims.get("acc", String.class));
        assertEquals("V800012", claims.get("vno", String.class));
        assertEquals("8000", claims.get("avs", String.class));
        assertNull(claims.get("phone"));
    }

    @Test
    void rejectsTokenSignedWithTheSameKeyForAnotherIssuer() {
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readLong("jwt_access_ttl_minutes", 15)).thenReturn(15L);

        JwtProperties issuerA = properties("uten-environment-a");
        JwtProperties issuerB = properties("uten-environment-b");
        JwtService issuingService = new JwtService(issuerA, settings);
        JwtService validatingService = new JwtService(issuerB, settings);

        String token = issuingService.issueVisitorAccess(
                UUID.randomUUID(), "V800013", "8001", Set.of("visitor:view"));

        assertThrows(JwtException.class, () -> validatingService.parse(token));
    }

    private JwtProperties properties(String issuer) {
        JwtProperties properties = new JwtProperties();
        properties.setSecret("0123456789abcdef0123456789abcdef");
        properties.setIssuer(issuer);
        return properties;
    }
}
