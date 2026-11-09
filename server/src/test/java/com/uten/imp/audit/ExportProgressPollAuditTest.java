package com.uten.imp.audit;

import com.uten.imp.common.export.ExportProgress;
import com.uten.imp.common.export.ExportProgressController;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 同步导出进行中客户端每 0.5 秒读一次进度。轮询不论读到与否都不能写审计:
 * 未开始/已结束用 204 而不是 404, 因为审计会把每个 4xx 记成一条失败操作。
 */
class ExportProgressPollAuditTest {
    private final UUID user = UUID.randomUUID();
    private final ExportProgressController controller = controllerFor(user);

    private static ExportProgressController controllerFor(UUID user) {
        SecurityContextCurrentUser users = mock(SecurityContextCurrentUser.class);
        when(users.id()).thenReturn(Optional.of(user));
        return new ExportProgressController(users);
    }

    private static MockHttpServletRequest poll(UUID operation) {
        return new MockHttpServletRequest("GET", "/api/exports/progress/" + operation);
    }

    @Test void aRunningExportIsReadByItsOwnerWithoutAnAuditRow() {
        UUID operation = UUID.randomUUID();
        try (var ignored = ExportProgress.openRegistered(user, operation)) {
            ExportProgress.announceTotal(35_763);
            ExportProgress.rows(12_000);
            var response = controller.progress(operation);
            assertEquals(200, response.getStatusCode().value());
            assertEquals(12_000L, response.getBody().rows());
            assertEquals(35_763L, response.getBody().total());
            assertFalse(AuditRequestContext.shouldRecordOperation(
                    poll(operation), response.getStatusCode().value(), false, false));
        }
    }

    @Test void notStartedFinishedOrForeignOperationsAreNoContentNotFailures() {
        UUID operation = UUID.randomUUID();
        var notStarted = controller.progress(operation);
        assertEquals(204, notStarted.getStatusCode().value());
        assertNull(notStarted.getBody());

        try (var ignored = ExportProgress.openRegistered(UUID.randomUUID(), operation)) {
            assertEquals(204, controller.progress(operation).getStatusCode().value(), "别人的进度不可读");
        }
        try (var ignored = ExportProgress.openRegistered(user, operation)) {
            ExportProgress.rows(1);
        }
        var finished = controller.progress(operation);
        assertEquals(204, finished.getStatusCode().value());
        assertFalse(AuditRequestContext.shouldRecordOperation(
                poll(operation), finished.getStatusCode().value(), false, false));
        // 对照: 若返回 404, 每次导出首尾都会多出几条「失败」审计。
        assertTrue(AuditRequestContext.shouldRecordOperation(poll(operation), 404, false, false));
    }
}
