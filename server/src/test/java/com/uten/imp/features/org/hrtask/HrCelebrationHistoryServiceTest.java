package com.uten.imp.features.org.hrtask;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class HrCelebrationHistoryServiceTest {
    @Test @SuppressWarnings({"unchecked", "rawtypes"})
    void historyHeadersUseSnapshotsAndTheSameNoticeAudienceBeforeCountAndPagination() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        UUID actor = UUID.randomUUID();
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor, UUID.randomUUID(), "reader",
                Set.of("employee:view", "notice:read", "employee:pii:view"), false, true, false)));
        when(jdbc.queryForObject(org.mockito.ArgumentMatchers.anyString(), org.mockito.ArgumentMatchers.eq(Long.class),
                org.mockito.ArgumentMatchers.any(Object[].class))).thenReturn(45L);
        when(jdbc.query(org.mockito.ArgumentMatchers.anyString(), org.mockito.ArgumentMatchers.any(org.springframework.jdbc.core.RowMapper.class),
                org.mockito.ArgumentMatchers.any(Object[].class))).thenReturn(java.util.List.of());
        var service = new HrCelebrationHistoryService(jdbc, current);
        var result = service.list("birthday", 2, 20, Map.of("search.employeeName", "王_%", "search.publishedAt", "2026-10", "sort", "publishedAt", "order", "asc"));
        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        var args = org.mockito.ArgumentCaptor.forClass(Object[].class);
        verify(jdbc).queryForObject(sql.capture(), org.mockito.ArgumentMatchers.eq(Long.class), args.capture());
        assertTrue(sql.getValue().contains("notice.audience_user_id = ?"));
        assertTrue(sql.getValue().contains("state.deleted_at IS NULL"));
        assertTrue(sql.getValue().contains("COALESCE(subject.employee_name, notice.subject_name"));
        assertTrue(sql.getValue().contains("notice.published_at >= ? AND notice.published_at < ?"));
        assertFalse(sql.getValue().contains("王_%"));
        assertEquals(actor, args.getValue()[0]);
        assertEquals("birthday", args.getValue()[1]);
        assertEquals(actor, args.getValue()[2]);
        assertEquals(45, result.getTotal());
        assertEquals(2, result.getPage());
    }
    @Test void birthdayHistoryNeverQueriesWithoutHrNoticeAndPiiAuthority() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        var service = new HrCelebrationHistoryService(jdbc, current);
        for (Set<String> permissions : java.util.List.of(Set.<String>of(), Set.of("employee:view"),
                Set.of("employee:view", "notice:read"), Set.of("employee:pii:view", "notice:read"))) {
            when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                    "reader", permissions, false, true, false)));
            assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class,
                    () -> service.list("birthday", 1, 20)).getCode());
        }
        when(current.get()).thenReturn(Optional.of(AuthUser.visitor(UUID.randomUUID(), "visitor", "V1",
                Set.of("employee:view", "notice:read", "employee:pii:view"))));
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class,
                () -> service.list("birthday", 1, 20)).getCode());
        verifyNoInteractions(jdbc);
    }
}
