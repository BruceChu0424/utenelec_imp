package com.uten.imp.security;

import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import io.jsonwebtoken.Claims;
import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class JwtStaffClaimMinimizationTest {

    @Test
    void staffAccessTokenContainsOnlyIdentityAndAuthorizationStamps() {
        JwtProperties properties = new JwtProperties();
        properties.setSecret("0123456789abcdef0123456789abcdef");
        properties.setIssuer("uten-test");
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readLong(SystemSettingKey.JWT_ACCESS_TTL_MINUTES)).thenReturn(15L);
        JwtService jwtService = new JwtService(properties, settings);
        UUID userId = UUID.randomUUID();

        UUID sessionId = UUID.randomUUID();
        String token = jwtService.issueAccess(userId, 7, 11, sessionId);
        Claims claims = jwtService.parse(token);

        assertEquals(userId.toString(), claims.getSubject());
        assertEquals("staff", claims.get("typ", String.class));
        assertEquals(7L, ((Number) claims.get("av")).longValue());
        assertEquals(11L, ((Number) claims.get("ae")).longValue());
        assertNull(claims.get("emp"));
        assertNull(claims.get("acc"));
        assertNull(claims.get("roles"));
        assertNull(claims.get("perms"));
        assertNull(claims.get("mcp"));
        // sid 是必带的会话号 (ADR-110): 过滤器按它查服务端会话的吊销/空闲/绝对期限。
        assertEquals(Set.of("iss", "sub", "av", "ae", "typ", "sid", "iat", "exp"), claims.keySet());
        assertFalse(token.contains("employee:view"));
        assertTrue(("Bearer " + token).length() < 512,
                "staff Authorization header must retain ample room in the 16 KiB envelope");
    }

    @Test
    void staffAndImpersonationAccessTokensCarryOnlyTheStableSessionUuid() {
        JwtProperties properties = new JwtProperties();
        properties.setSecret("0123456789abcdef0123456789abcdef");
        properties.setIssuer("uten-test");
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readLong(SystemSettingKey.JWT_ACCESS_TTL_MINUTES)).thenReturn(15L);
        JwtService jwtService = new JwtService(properties, settings);
        UUID userId = UUID.randomUUID();
        UUID adminId = UUID.randomUUID();
        UUID sessionId = UUID.randomUUID();

        Claims staff = jwtService.parse(
                jwtService.issueAccess(userId, 7, 11, sessionId));
        Claims impersonation = jwtService.parse(jwtService.issueImpersonationAccess(
                userId,
                7,
                11,
                adminId,
                java.time.Instant.now().plusSeconds(60),
                sessionId));

        assertEquals(sessionId.toString(), staff.get("sid", String.class));
        assertEquals(sessionId.toString(), impersonation.get("sid", String.class));
        assertEquals(adminId.toString(), impersonation.get("imp", String.class));
        assertNull(staff.get("jti"));
        assertNull(impersonation.get("jti"));
    }
}
