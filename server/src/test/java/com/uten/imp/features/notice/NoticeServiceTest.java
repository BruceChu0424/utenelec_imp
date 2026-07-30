package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.Pageable;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class NoticeServiceTest {

    private NoticeRepository noticeRepository;
    private NoticeUserStateRepository stateRepository;
    private SecurityContextCurrentUser currentUser;
    private NoticeService service;
    private UUID userId;

    @BeforeEach
    void setUp() {
        noticeRepository = mock(NoticeRepository.class);
        stateRepository = mock(NoticeUserStateRepository.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser authUser = mock(AuthUser.class);
        userId = UUID.randomUUID();

        when(currentUser.get()).thenReturn(Optional.of(authUser));
        when(authUser.isVisitor()).thenReturn(false);
        when(authUser.getId()).thenReturn(userId);

        service = new NoticeService(
                noticeRepository,
                stateRepository,
                mock(EmployeeRepository.class),
                currentUser,
                new ObjectMapper());
    }

    @Test
    void listUsesBoundedDatabaseQueryInsteadOfLoadingEveryNotice() {
        Notice notice = new Notice();
        notice.setTitle("title");
        notice.setContent("content");
        notice.setType("system");
        notice.setPublisher("system");
        notice.setPublishedAt(Instant.parse("2026-07-30T00:00:00Z"));
        when(noticeRepository.findVisible(eq(userId), eq(false), any(Pageable.class)))
                .thenReturn(List.of(notice));
        when(stateRepository.findByIdUserIdAndIdNoticeIdIn(eq(userId), any()))
                .thenReturn(List.of());

        assertEquals(1, service.list(false).size());

        verify(noticeRepository, never()).findAll();
    }

    @Test
    void unreadCountIsCalculatedByTheDatabase() {
        when(noticeRepository.countVisibleUnread(userId)).thenReturn(123L);

        assertEquals(123L, service.unreadCount());
    }

    @Test
    void oversizedBatchDeleteIsRejectedBeforeDatabaseAccess() {
        List<UUID> ids = java.util.stream.IntStream.range(0, 501)
                .mapToObj(ignored -> UUID.randomUUID())
                .toList();

        assertThrows(ApiException.class, () -> service.deleteForCurrentUser(ids));
        verify(noticeRepository, never()).findAllById(any());
    }
}
