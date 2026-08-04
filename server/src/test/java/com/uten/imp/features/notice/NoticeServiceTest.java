package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.features.notice.dto.NoticePublishRequest;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.Pageable;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class NoticeServiceTest {

    private NoticeRepository noticeRepository;
    private NoticeUserStateRepository stateRepository;
    private SecurityContextCurrentUser currentUser;
    private NoticeAudienceService audienceService;
    private NoticeService service;
    private UUID userId;

    @BeforeEach
    void setUp() {
        noticeRepository = mock(NoticeRepository.class);
        stateRepository = mock(NoticeUserStateRepository.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        audienceService = mock(NoticeAudienceService.class);
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
                new ObjectMapper(),
                audienceService,
                mock(TxSessionVars.class));
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

    @Test
    void selectedAudienceIsResolvedOnceAndPersistedAsRecipientSnapshot() {
        UUID departmentId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UUID secondUserId = UUID.randomUUID();
        when(audienceService.resolveSelected(
                List.of(departmentId),
                List.of(employeeId)))
                .thenReturn(new NoticeAudienceService.ResolvedAudience(
                        Set.of(userId, secondUserId),
                        Set.of(departmentId),
                        Set.of(employeeId),
                        "生产部、张三"));

        NoticeDto published = service.publish(new NoticePublishRequest(
                "停电通知",
                "今晚 20:00 停电检修",
                "announcement",
                false,
                "normal",
                List.of(),
                "selected",
                List.of(departmentId),
                List.of(employeeId)));

        assertEquals("selected", published.audienceScope());
        assertEquals("生产部、张三", published.audienceSummary());
        assertEquals(2, published.audienceCount());
        verify(audienceService).resolveSelected(
                List.of(departmentId),
                List.of(employeeId));
        verify(stateRepository).saveAll(any());
    }

    @Test
    void allAudienceRejectsSelectedTargets() {
        NoticePublishRequest request = new NoticePublishRequest(
                "标题", "正文", "announcement", false, "normal", List.of(),
                "all", List.of(UUID.randomUUID()), List.of());

        assertThrows(ApiException.class, () -> service.publish(request));
        verify(audienceService, never()).resolveSelected(any(), any());
    }

    @Test
    void completingTodoIsIdempotentAndAlsoMarksItRead() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setKind("TODO");
        notice.setAudienceScope("all");
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));
        when(stateRepository.findById(new NoticeUserStateId(noticeId, userId)))
                .thenReturn(Optional.empty());

        Instant before = Instant.now().minus(1, ChronoUnit.SECONDS);
        service.completeTodo(noticeId);

        verify(stateRepository).save(argThat(state ->
                state.getId().getNoticeId().equals(noticeId)
                        && state.getId().getUserId().equals(userId)
                        && state.getReadAt() != null
                        && state.getReadAt().isAfter(before)
                        && state.getTaskCompletedAt() != null
                        && state.getTaskCompletedAt().isAfter(before)));
    }

    @Test
    void publishForUserPersistsValidActionRoute() {
        UUID audienceUserId = UUID.randomUUID();
        when(noticeRepository.saveAndFlush(any(Notice.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        service.publishForUser(audienceUserId, "标题", "正文", "workflow", "系统",
                "/sales/orders/" + UUID.randomUUID());

        ArgumentCaptor<Notice> captor = ArgumentCaptor.forClass(Notice.class);
        verify(noticeRepository).saveAndFlush(captor.capture());
        Notice saved = captor.getValue();
        assertEquals("workflow", saved.getType());
        assertEquals(audienceUserId, saved.getAudienceUserId());
        assertNotNull(saved.getActionRoute());
        assertTrue(saved.getActionRoute().startsWith("/sales/orders/"));
    }

    @Test
    void publishForUserSilentlyDropsInvalidActionRoute() {
        UUID audienceUserId = UUID.randomUUID();
        when(noticeRepository.saveAndFlush(any(Notice.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        // 非 / 开头 → 不抛异常，actionRoute 静默丢弃保持 null
        service.publishForUser(audienceUserId, "标题", "正文", "workflow", "系统",
                "finance/approvals");

        ArgumentCaptor<Notice> captor = ArgumentCaptor.forClass(Notice.class);
        verify(noticeRepository).saveAndFlush(captor.capture());
        assertNull(captor.getValue().getActionRoute());
    }

    @Test
    void publishForUserWithNullRouteLeavesActionRouteNull() {
        UUID audienceUserId = UUID.randomUUID();
        when(noticeRepository.saveAndFlush(any(Notice.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        service.publishForUser(audienceUserId, "标题", "正文", "task", "系统", null);

        ArgumentCaptor<Notice> captor = ArgumentCaptor.forClass(Notice.class);
        verify(noticeRepository).saveAndFlush(captor.capture());
        assertNull(captor.getValue().getActionRoute());
        assertEquals("task", captor.getValue().getType());
    }
}
