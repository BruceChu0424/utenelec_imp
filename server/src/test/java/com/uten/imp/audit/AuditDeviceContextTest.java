package com.uten.imp.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.FilterChain;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AuditDeviceContextTest {

    private final ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();
    private final AuditDeviceContext context = new AuditDeviceContext(
            objectMapper,
            Clock.fixed(Instant.parse("2026-07-31T02:00:00Z"), ZoneOffset.UTC));

    @Test
    void parsesOnlySanitizedVersionedDeviceFields() throws Exception {
        UUID clientEventId = UUID.randomUUID();
        UUID installationId = UUID.randomUUID();
        MockHttpServletRequest request = new MockHttpServletRequest(
                "POST", "/api/admin/system-settings");
        request.addHeader(
                AuditDeviceContext.HEADER_CLIENT_EVENT_ID,
                clientEventId.toString());
        request.addHeader(
                AuditDeviceContext.HEADER_DEVICE_CONTEXT,
                encoded("""
                        {
                          "version": 1,
                          "installationId": "%s",
                          "deviceName": "财务\\n电脑",
                          "manufacturer": "Uten",
                          "model": "QA-1",
                          "platform": "windows",
                          "osVersion": "Windows 11",
                          "appVersion": "2.1.0",
                          "appBuild": "abc123",
                          "formFactor": "desktop",
                          "browserName": "edge",
                          "locale": "zh_CN",
                          "timeZone": "China Standard Time",
                          "timeZoneOffsetMinutes": 480,
                          "isPhysicalDevice": true,
                          "clientEventAt": "2026-07-31T10:00:00+08:00",
                          "serialNumber": "must-not-be-captured"
                        }
                        """.formatted(installationId)));

        AuditDeviceEvidence evidence = context.ensure(request);

        assertEquals(clientEventId, evidence.clientEventId());
        assertEquals(installationId, evidence.installationId());
        assertEquals("财务 电脑", evidence.deviceName());
        assertEquals("present", evidence.captureStatus());
        assertEquals(64, evidence.profileHash().length());
        assertTrue(evidence.clientDeclared());
        String sessionJson = context.sessionJson(request);
        assertTrue(sessionJson.contains(clientEventId.toString()));
        assertTrue(sessionJson.contains(installationId.toString()));
        assertTrue(sessionJson.contains("2026-07-31T02:00Z"));
        assertTrue(sessionJson.contains(evidence.profileHash()));
        assertFalse(sessionJson.contains("serialNumber"));
        assertFalse(sessionJson.contains("must-not-be-captured"));
    }

    @Test
    void malformedContextIsNonThrowingAndMarkedInvalid() {
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/admin/audit-logs");
        request.addHeader(AuditDeviceContext.HEADER_DEVICE_CONTEXT, "%%%bad%%%");

        AuditDeviceEvidence evidence = context.ensure(request);

        assertEquals("invalid", evidence.captureStatus());
        assertNull(evidence.installationId());
        assertNull(evidence.profileHash());
    }

    @Test
    void outOfRangeClientTimeIsDiscardedWithoutBreakingTheRequest() {
        UUID clientEventId = UUID.randomUUID();
        UUID installationId = UUID.randomUUID();
        MockHttpServletRequest request = new MockHttpServletRequest(
                "POST", "/api/orders");
        request.addHeader(
                AuditDeviceContext.HEADER_CLIENT_EVENT_ID,
                clientEventId.toString());
        request.addHeader(
                AuditDeviceContext.HEADER_DEVICE_CONTEXT,
                encoded("""
                        {
                          "version": 1,
                          "installationId": "%s",
                          "platform": "windows",
                          "appVersion": "2.1.0",
                          "clientEventAt": "+999999999-12-31T23:59:59Z"
                        }
                        """.formatted(installationId)));

        AuditDeviceEvidence evidence = context.ensure(request);

        assertEquals("invalid", evidence.captureStatus());
        assertNull(evidence.clientEventAt());
        assertFalse(context.sessionJson(request).contains("999999999"));
    }

    @Test
    void earlyFilterEchoesServerAndClientCorrelationIds() throws Exception {
        UUID clientEventId = UUID.randomUUID();
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/admin/audit-logs");
        request.addHeader(
                AuditDeviceContext.HEADER_CLIENT_EVENT_ID,
                clientEventId.toString());
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = (req, resp) -> {
            // No-op: headers must already be available before authentication.
        };

        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());
        new AuditRequestContextFilter(context, currentUser, mock(AuditService.class))
                .doFilter(request, response, chain);

        assertNotNull(response.getHeader(
                AuditRequestContext.RESPONSE_REQUEST_ID_HEADER));
        assertEquals(
                clientEventId.toString(),
                response.getHeader(AuditDeviceContext.HEADER_CLIENT_EVENT_ID));
    }

    private String encoded(String json) {
        return Base64.getUrlEncoder().encodeToString(
                json.getBytes(StandardCharsets.UTF_8));
    }
}
