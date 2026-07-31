package com.uten.imp.audit;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AuditQueryServiceTest {

    @Test
    void detailExposesRedactedBeforeAndAfterForSystemManagement() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(repository);
        AuditLog log = new AuditLog();
        log.setId(42L);
        log.setActorId(UUID.randomUUID());
        log.setActorAccount("planner");
        log.setAction("update");
        log.setTargetType("production_execution_segments");
        log.setTargetId(UUID.randomUUID().toString());
        log.setBefore("{\"status\":\"READY\"}");
        log.setAfter("{\"status\":\"DISPATCHED\"}");
        log.setIp("127.0.0.1");
        log.setUserAgent("test");
        log.setResult("success");
        log.setCreatedAt(OffsetDateTime.parse("2026-07-31T06:00:00+08:00"));
        when(repository.findById(42L)).thenReturn(Optional.of(log));

        AuditLogDetail detail = service.detail(42L);

        assertEquals(42L, detail.id());
        assertEquals("planner", detail.actorAccount());
        assertEquals(
                "production_execution_segments", detail.targetType());
        assertEquals("{\"status\":\"READY\"}", detail.before());
        assertEquals("{\"status\":\"DISPATCHED\"}", detail.after());
        assertEquals("test", detail.userAgent());
    }

    @Test
    void detailFailsClosedWhenRowWasNeverPresentOrHasBeenArchived() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(repository);
        when(repository.findById(99L)).thenReturn(Optional.empty());

        ApiException error = assertThrows(
                ApiException.class, () -> service.detail(99L));

        assertEquals("审计日志不存在或已归档", error.getMessage());
    }
}
