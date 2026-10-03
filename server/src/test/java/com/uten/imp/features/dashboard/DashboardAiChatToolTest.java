package com.uten.imp.features.dashboard;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class DashboardAiChatToolTest {
    private final DashboardOverviewService overview = mock(DashboardOverviewService.class);
    private final SecurityContextCurrentUser users = mock(SecurityContextCurrentUser.class);
    private final DashboardAiChatTool tool = new DashboardAiChatTool(overview, users);

    private void employee(Set<String> permissions) {
        when(users.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "employee", permissions, false, true, false)));
    }

    @Test void deniedBeforeReadingWhenPermissionWasRevoked() {
        employee(Set.of());
        assertFalse(tool.available());
        assertThrows(ApiException.class, () -> tool.execute(Map.of()));
        verifyNoInteractions(overview);
    }

    @Test void userCannotWidenScopeThroughModelArguments() {
        employee(Set.of("ai:use"));
        assertThrows(ApiException.class, () -> tool.execute(Map.of("department", "FINANCE")));
        verifyNoInteractions(overview);
    }

    @Test void onlyOperationalCountsAreReturnedWithSourceAndTime() {
        employee(Set.of("ai:use"));
        when(overview.overview()).thenReturn(new DashboardOverviewDto("DEPT_PROD", "生产", Instant.EPOCH,
                List.of(new DashboardOverviewDto.MetricCard("production-pending", "待排产产品", "3", "", "", "", false),
                        new DashboardOverviewDto.MetricCard("notice-unread", "私密通知", "5", "SECRET", "", "", false)),
                List.of(new DashboardOverviewDto.TodoCard("notice-1", "SECRET_NOTICE", "SECRET_BODY", 1, 0, "", "", "NOTICE", "1", null, true),
                        new DashboardOverviewDto.TodoCard("expense-approval", "SECRET_EXPENSE", "", 9, 0, "", "", "FINANCE", null, null, false))));
        Map<String, Object> result = tool.execute(Map.of());
        assertTrue(result.get("reply").toString().contains("待排产产品: 3"));
        assertFalse(result.get("reply").toString().contains("SECRET"));
        assertEquals("dashboard/overview", result.get("source"));
        assertEquals(Instant.EPOCH.toString(), result.get("generatedAt"));
        verify(overview).overview();
    }

    @Test void historicalCountsCannotOutliveTheirAuthorizedProjection() {
        employee(Set.of("ai:use"));
        when(overview.overview()).thenReturn(new DashboardOverviewDto("DEPT_PROD", "生产", Instant.EPOCH,
                List.of(new DashboardOverviewDto.MetricCard("production-pending", "待排产产品", "3", "", "", "", false)), List.of()));
        var result = tool.execute(Map.of());
        @SuppressWarnings("unchecked") var evidence = (Map<String, Object>) result.get("_toolEvidence");
        assertDoesNotThrow(() -> tool.authorizeResultRead(evidence));
        when(overview.overview()).thenReturn(new DashboardOverviewDto("DEPT_PROD", "生产", Instant.EPOCH,
                List.of(new DashboardOverviewDto.MetricCard("production-pending", "待排产产品", "1", "", "", "", false)), List.of()));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(Map.of()));
    }
}
