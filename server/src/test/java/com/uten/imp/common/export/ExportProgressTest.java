package com.uten.imp.common.export;

import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ExportProgressTest {
    @Test void reportsOutsideAScopeAreNoOps() {
        ExportProgress.announceTotal(35_763);
        ExportProgress.rows(100);
        ExportProgress.phase(ExportProgress.Phase.PACKAGING);
        assertNull(ExportProgress.currentTotal());
    }

    @Test void theFirstAuthoritativeTotalWinsAndRowsNeverGoBackwards() {
        UUID user = UUID.randomUUID(), operation = UUID.randomUUID();
        try (var ignored = ExportProgress.openRegistered(user, operation)) {
            ExportProgress.announceTotal(-1);
            assertNull(ExportProgress.currentTotal(), "未知总数不记录");
            ExportProgress.announceTotal(35_763);
            ExportProgress.announceTotal(100);
            ExportProgress.rows(3_200);
            ExportProgress.rows(1_000);
            var snapshot = ExportProgress.snapshot(user, operation).orElseThrow();
            assertEquals(35_763L, snapshot.total());
            assertEquals(3_200L, snapshot.rows(), "已读行数单调不减");
            assertEquals("READING", snapshot.phase());
            ExportProgress.phase(ExportProgress.Phase.PACKAGING);
            assertEquals("PACKAGING", ExportProgress.snapshot(user, operation).orElseThrow().phase());
        }
        assertTrue(ExportProgress.snapshot(user, operation).isEmpty(), "请求结束即注销, 不泄漏");
        assertNull(ExportProgress.currentTotal());
    }

    @Test void onlyTheOwnerCanReadAnOperation() {
        UUID owner = UUID.randomUUID(), operation = UUID.randomUUID();
        try (var ignored = ExportProgress.openRegistered(owner, operation)) {
            ExportProgress.rows(10);
            assertTrue(ExportProgress.snapshot(UUID.randomUUID(), operation).isEmpty());
            assertTrue(ExportProgress.snapshot(owner, operation).isPresent());
        }
    }

    @Test void aDuplicateOperationDoesNotHijackTheOriginalProgress() {
        UUID user = UUID.randomUUID(), operation = UUID.randomUUID();
        try (var first = ExportProgress.openRegistered(user, operation)) {
            ExportProgress.rows(50);
            try (var duplicate = ExportProgress.openRegistered(user, operation)) {
                ExportProgress.rows(999);
            }
            assertEquals(50L, ExportProgress.snapshot(user, operation).orElseThrow().rows());
        }
    }

    @Test void unregisteredWorkerScopesKeepTheTotalForHeartbeats() {
        try (var outer = ExportProgress.open()) {
            ExportProgress.announceTotal(10);
            try (var inner = ExportProgress.open()) {
                ExportProgress.announceTotal(3);
                assertEquals(3L, ExportProgress.currentTotal());
            }
            assertEquals(10L, ExportProgress.currentTotal());
        }
        assertNull(ExportProgress.currentTotal());
    }
}
