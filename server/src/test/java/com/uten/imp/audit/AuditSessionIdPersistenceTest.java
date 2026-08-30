package com.uten.imp.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class AuditSessionIdPersistenceTest {

    @AfterEach
    void resetRequestContext() {
        RequestContextHolder.resetRequestAttributes();
    }

    @Test
    void verifiedRequestSessionFlowsToEntityListAndDetailDtos() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditService service = new AuditService(
                repository,
                new AuditDeviceContext(new ObjectMapper()));
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setMethod("GET");
        request.setRequestURI("/api/master/goods/1");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        UUID sessionId = UUID.randomUUID();
        AuditRequestContext.bindSessionId(request, sessionId);

        service.logExplicit(
                UUID.randomUUID(), "E1001", "view_goods_detail",
                "goods", UUID.randomUUID().toString(), "success");

        ArgumentCaptor<AuditLog> saved = ArgumentCaptor.forClass(AuditLog.class);
        verify(repository).save(saved.capture());
        AuditLog value = saved.getValue();
        assertEquals(sessionId, value.getSessionId());
        assertEquals(sessionId,
                AuditLogRow.of(value, new AuditEventInterpreter()).getSessionId());
        assertEquals(sessionId,
                AuditLogDetail.of(value, new AuditEventInterpreter()).sessionId());
    }

    @Test
    void explicitAuthenticationSessionOverridesAbsentRequestSession() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditService service = new AuditService(
                repository,
                new AuditDeviceContext(new ObjectMapper()));
        UUID sessionId = UUID.randomUUID();

        service.logExplicit(
                UUID.randomUUID(), null, "logout", "refresh_tokens",
                UUID.randomUUID().toString(), "success", sessionId);

        ArgumentCaptor<AuditLog> saved = ArgumentCaptor.forClass(AuditLog.class);
        verify(repository).save(saved.capture());
        assertEquals(sessionId, saved.getValue().getSessionId());
    }
}
