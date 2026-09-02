package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.notice.NoticeAcknowledgmentRepository.NoticeAcknowledgerRow;
import com.uten.imp.features.notice.NoticeBlessingRepository.NoticeBlessingRow;
import com.uten.imp.features.notice.dto.CelebrationBatchRequest;
import com.uten.imp.features.notice.dto.CelebrationBatchResult;
import com.uten.imp.features.notice.dto.MyCelebrationTodayDto;
import com.uten.imp.features.notice.dto.NoticeCelebrationPreviewDto;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.features.notice.dto.NoticePublishRequest;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.Query;

import java.time.Instant;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class NoticeServiceTest {

    private NoticeRepository noticeRepository;
    private NoticeUserStateRepository stateRepository;
    private NoticeAcknowledgmentRepository ackRepository;
    private NoticeBlessingRepository blessRepo;
    private NoticeCelebrationSubjectRepository subjectRepo;
    private EmployeeRepository employeeRepository;
    private SecurityContextCurrentUser currentUser;
    private NoticeAudienceService audienceService;
    private SystemSettingsService systemSettings;
    private NoticeService service;
    private UUID userId;
    private AuthUser authUser;
    // V459：认领人姓名解析（pending-review-status 用）
    private com.uten.imp.application.port.EmployeeNameLookupPort nameLookup;

    @BeforeEach
    void setUp() {
        noticeRepository = mock(NoticeRepository.class);
        stateRepository = mock(NoticeUserStateRepository.class);
        ackRepository = mock(NoticeAcknowledgmentRepository.class);
        blessRepo = mock(NoticeBlessingRepository.class);
        subjectRepo = mock(NoticeCelebrationSubjectRepository.class);
        employeeRepository = mock(EmployeeRepository.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        audienceService = mock(NoticeAudienceService.class);
        systemSettings = mock(SystemSettingsService.class);
        nameLookup = mock(com.uten.imp.application.port.EmployeeNameLookupPort.class);
        when(nameLookup.findName(any())).thenReturn(Optional.of("张三"));
        authUser = mock(AuthUser.class);
        userId = UUID.randomUUID();

        when(currentUser.get()).thenReturn(Optional.of(authUser));
        when(authUser.isVisitor()).thenReturn(false);
        when(authUser.getId()).thenReturn(userId);
        // V454：主角名单默认空（bless 卡 toDto 装配路径不 NPE）
        when(subjectRepo.findByNoticeIdOrderByCreatedAtAsc(any()))
                .thenReturn(List.of());
        when(subjectRepo.findByNoticeIdInOrderByCreatedAtAsc(any()))
                .thenReturn(List.of());

        service = new NoticeService(
                noticeRepository,
                stateRepository,
                ackRepository,
                blessRepo,
                subjectRepo,
                employeeRepository,
                currentUser,
                new ObjectMapper(),
                audienceService,
                mock(TxSessionVars.class),
                systemSettings,
                mock(com.uten.imp.audit.AuditService.class),
                mock(com.uten.imp.features.common.taskclaim.TaskClaimRepository.class),
                nameLookup);
    }

    @Test
    void listUsesBoundedDatabaseQueryInsteadOfLoadingEveryNotice() {
        Notice notice = new Notice();
        notice.setTitle("title");
        notice.setContent("content");
        notice.setType("system");
        notice.setSourceEvent("SYSTEM_TEST_EVENT");
        notice.setPublisher("system");
        notice.setPublishedAt(Instant.parse("2026-07-30T00:00:00Z"));
        when(noticeRepository.findVisible(eq(userId), eq(false), any()))
                .thenReturn(List.of(notice));
        when(stateRepository.findByIdUserIdAndIdNoticeIdIn(eq(userId), any()))
                .thenReturn(List.of());
        // system 类型 = acknowledge 模式 → toDto 会查回执数
        when(ackRepository.countByIdNoticeId(any())).thenReturn(0L);
        when(ackRepository.existsByIdNoticeIdAndIdUserId(any(), any())).thenReturn(false);
        when(ackRepository.findRecentAcknowledgers(any(), anyInt())).thenReturn(List.of());

        List<NoticeDto> items = service.list(false);
        assertEquals(1, items.size());
        assertEquals("SYSTEM_TEST_EVENT", items.getFirst().sourceEvent());

        verify(noticeRepository, never()).findAll();
    }


    @Test
    void firstCursorPageStartsAtEpochAndReplaysAllUnreadArrivals() {
        Notice unread = arrivalNotice(
                Instant.parse("2024-01-01T00:00:00Z"), "历史未读公告");
        UUID zeroId = new UUID(0L, 0L);
        when(noticeRepository.findVisibleArrivalsAfter(
                eq(userId), eq(Instant.EPOCH), eq(zeroId), any()))
                .thenReturn(List.of(unread));
        when(stateRepository.findByIdUserIdAndIdNoticeIdIn(
                eq(userId), any())).thenReturn(List.of());

        NoticeService.ArrivalPage page = service.arrivals(null, null, 500);

        assertEquals(1, page.items().size());
        assertEquals(unread.getPublishedAt(), page.cursorPublishedAt());
        assertEquals(unread.getId(), page.cursorId());
        assertFalse(page.hasMore());
        ArgumentCaptor<Pageable> pageable =
                ArgumentCaptor.forClass(Pageable.class);
        verify(noticeRepository).findVisibleArrivalsAfter(
                eq(userId), eq(Instant.EPOCH), eq(zeroId), pageable.capture());
        assertEquals(101, pageable.getValue().getPageSize());
    }

    @Test
    void cursorPageIsAscendingHasMoreAndSkipsInteractionHydration() {
        Instant after = Instant.parse("2026-08-22T01:00:00Z");
        UUID afterId = UUID.randomUUID();
        Notice first = arrivalNotice(
                Instant.parse("2026-08-22T01:01:00Z"), "公告一");
        Notice second = arrivalNotice(
                Instant.parse("2026-08-22T01:02:00Z"), "公告二");
        Notice overflow = arrivalNotice(
                Instant.parse("2026-08-22T01:03:00Z"), "公告三");
        when(noticeRepository.findVisibleArrivalsAfter(
                eq(userId), eq(after), eq(afterId), any()))
                .thenReturn(List.of(first, second, overflow));
        when(stateRepository.findByIdUserIdAndIdNoticeIdIn(
                eq(userId), any())).thenReturn(List.of());

        NoticeService.ArrivalPage page =
                service.arrivals(after, afterId, 2);

        assertEquals(
                List.of(first.getId().toString(), second.getId().toString()),
                page.items().stream().map(NoticeDto::id).toList());
        assertTrue(page.hasMore());
        assertEquals(second.getPublishedAt(), page.cursorPublishedAt());
        assertEquals(second.getId(), page.cursorId());
        ArgumentCaptor<Pageable> pageable =
                ArgumentCaptor.forClass(Pageable.class);
        verify(noticeRepository).findVisibleArrivalsAfter(
                eq(userId), eq(after), eq(afterId), pageable.capture());
        assertEquals(3, pageable.getValue().getPageSize());
        verify(ackRepository, never()).countByIdNoticeId(any());
        verify(blessRepo, never()).countByNoticeId(any());
    }

    @Test
    void cursorParametersMustBeProvidedTogetherAndQueryUsesStableAscendingOrder()
            throws Exception {
        assertThrows(
                ApiException.class,
                () -> service.arrivals(Instant.EPOCH, null, 100));

        Query query = NoticeRepository.class
                .getMethod(
                        "findVisibleArrivalsAfter",
                        UUID.class,
                        Instant.class,
                        UUID.class,
                        Pageable.class)
                .getAnnotation(Query.class);
        assertNotNull(query);
        assertTrue(query.value().contains(
                "ORDER BY n.publishedAt ASC, n.id ASC"));
        assertTrue(query.value().contains("n.id > :afterId"));
        assertTrue(query.value().contains("s.readAt IS NULL"));
        assertTrue(query.value().contains("s.popupAcknowledgedAt IS NULL"));
        assertFalse(query.value().contains("topPriority"));
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
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");

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
        assertEquals("acknowledge", published.interactionMode());
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
                        && state.getPopupAcknowledgedAt() != null
                        && state.getPopupAcknowledgedAt().isAfter(before)
                        && state.getTaskCompletedAt() != null
                        && state.getTaskCompletedAt().isAfter(before)));
    }

    @Test
    void popupAcknowledgementDoesNotMarkNotificationReadOrCompleteTodo() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setAudienceScope("all");
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));
        when(stateRepository.findById(new NoticeUserStateId(noticeId, userId)))
                .thenReturn(Optional.empty());

        service.acknowledgePopup(noticeId);

        verify(stateRepository).save(argThat(state ->
                state.getId().getNoticeId().equals(noticeId)
                        && state.getPopupAcknowledgedAt() != null
                        && state.getReadAt() == null
                        && state.getTaskCompletedAt() == null));
    }

    @Test
    void acknowledgingAnAlreadyAcknowledgedPopupIsIdempotent() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setAudienceScope("all");
        NoticeUserState state = new NoticeUserState();
        state.setId(new NoticeUserStateId(noticeId, userId));
        state.setPopupAcknowledgedAt(Instant.parse("2026-08-27T00:00:00Z"));
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));
        when(stateRepository.findById(new NoticeUserStateId(noticeId, userId)))
                .thenReturn(Optional.of(state));

        service.acknowledgePopup(noticeId);

        verify(stateRepository, never()).save(any());
        assertEquals(
                Instant.parse("2026-08-27T00:00:00Z"),
                state.getPopupAcknowledgedAt());
    }

    @Test
    void markReadAlsoAcknowledgesAPreviouslyUnacknowledgedPopup() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setAudienceScope("all");
        NoticeUserState state = new NoticeUserState();
        state.setId(new NoticeUserStateId(noticeId, userId));
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));
        when(stateRepository.findById(new NoticeUserStateId(noticeId, userId)))
                .thenReturn(Optional.of(state));

        service.markRead(noticeId);

        verify(stateRepository).save(argThat(saved ->
                saved.getReadAt() != null
                        && saved.getPopupAcknowledgedAt() != null));
    }

    @Test
    void snoozeSetsUntilAndMarksReadButRejectsResolvedNotices() {
        // 已办结的审核通知无重弹意义 → 拒绝
        UUID resolvedId = UUID.randomUUID();
        Notice resolved = new Notice();
        resolved.setId(resolvedId);
        resolved.setAudienceUserId(userId);
        resolved.setResolvedAt(Instant.now());
        when(noticeRepository.findById(resolvedId)).thenReturn(Optional.of(resolved));
        org.assertj.core.api.Assertions
                .assertThatThrownBy(() -> service.snoozeNotice(resolvedId, 15))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);

        // 未办结 → snoozed_until + 同时置已读（R6：稍后再看也算已处理提醒）
        UUID pendingId = UUID.randomUUID();
        Notice pending = new Notice();
        pending.setId(pendingId);
        pending.setAudienceUserId(userId);
        NoticeUserState state = new NoticeUserState();
        state.setId(new NoticeUserStateId(pendingId, userId));
        when(noticeRepository.findById(pendingId)).thenReturn(Optional.of(pending));
        when(stateRepository.findById(new NoticeUserStateId(pendingId, userId)))
                .thenReturn(Optional.of(state));

        Instant until = service.snoozeNotice(pendingId, 15);

        org.junit.jupiter.api.Assertions.assertNotNull(until);
        verify(stateRepository).save(argThat(saved ->
                saved.getSnoozedUntil() != null && saved.getReadAt() != null));
    }

    @Test
    void publishForUserBindsAggregateOnlyForRegisteredReviewEvents() {
        when(noticeRepository.saveAndFlush(any(Notice.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));
        UUID aggregateId = UUID.randomUUID();
        UUID audienceUserId = UUID.randomUUID();

        // 注册事件：绑定 (kind,id)
        Notice review = service.publishForUser(
                audienceUserId, "待财务确认", "正文", "approval", "系统",
                "/finance/sales-order-confirmations/" + UUID.randomUUID(),
                "SALES_ORDER_PENDING_FINANCE_CONFIRM", null, aggregateId);
        org.junit.jupiter.api.Assertions.assertEquals("SALES_ORDER", review.getAggregateKind());
        org.junit.jupiter.api.Assertions.assertEquals(aggregateId, review.getAggregateId());

        // 未注册事件：aggregateId 忽略，保持普通通知（历史行为不变）
        Notice plain = service.publishForUser(
                audienceUserId, "普通通知", "正文", "task", "系统",
                null, "SOME_PLAIN_EVENT", null, aggregateId);
        org.junit.jupiter.api.Assertions.assertNull(plain.getAggregateKind());
        org.junit.jupiter.api.Assertions.assertNull(plain.getAggregateId());
    }

    @Test
    void resolveReviewNoticesDelegatesBoundedUpdateAndValidatesShape() {
        org.assertj.core.api.Assertions
                .assertThatThrownBy(() -> service.resolveReviewNotices(" ", null, null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);

        UUID aggregateId = UUID.randomUUID();
        when(noticeRepository.resolveReviewPendingByAggregate(
                "SALES_ORDER", aggregateId, "APPROVED")).thenReturn(3);

        int affected = service.resolveReviewNotices("SALES_ORDER", aggregateId, "APPROVED");

        org.junit.jupiter.api.Assertions.assertEquals(3, affected);
        // reason 缺省归一为 COMPLETED
        service.resolveReviewNotices("SALES_ORDER", aggregateId, null);
        verify(noticeRepository).resolveReviewPendingByAggregate(
                "SALES_ORDER", aggregateId, "COMPLETED");
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
        assertEquals("none", saved.getInteractionMode());
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

    @Test
    void urgentSystemTypeUsesUrgentPriorityAndPersistsSourceEvent() {
        UUID audienceUserId = UUID.randomUUID();
        when(noticeRepository.saveAndFlush(any(Notice.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        service.publishForUser(
                audienceUserId,
                "订单被驳回",
                "原因",
                "urgent",
                "系统",
                "/sales/orders/" + UUID.randomUUID(),
                "SALES_ORDER_FINANCE_REJECTED");

        ArgumentCaptor<Notice> captor = ArgumentCaptor.forClass(Notice.class);
        verify(noticeRepository).saveAndFlush(captor.capture());
        assertEquals("urgent", captor.getValue().getPriority());
        assertEquals(
                "SALES_ORDER_FINANCE_REJECTED",
                captor.getValue().getSourceEvent());
    }

    @Test
    void explicitNormalPriorityKeepsDepartmentBroadcastNonBlocking() {
        UUID audienceUserId = UUID.randomUUID();
        when(noticeRepository.saveAndFlush(any(Notice.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        service.publishForUser(
                audienceUserId,
                "部门广播",
                "公共任务",
                "urgent",
                "系统",
                "/production/schedule",
                "PRODUCTION_DRAW_ISSUE_REVERSED",
                "normal");

        ArgumentCaptor<Notice> captor = ArgumentCaptor.forClass(Notice.class);
        verify(noticeRepository).saveAndFlush(captor.capture());
        assertEquals("normal", captor.getValue().getPriority());
    }

    @Test
    void directedReturnTaskUsesImportantPriorityFromEventPolicy() {
        UUID audienceUserId = UUID.randomUUID();
        when(noticeRepository.saveAndFlush(any(Notice.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        service.publishForUser(
                audienceUserId,
                "供应商退回任务",
                "请处理",
                "task",
                "系统",
                "/procurement/arrival-exceptions",
                "PROCUREMENT_SUPPLIER_RETURN_REQUIRED");

        ArgumentCaptor<Notice> captor = ArgumentCaptor.forClass(Notice.class);
        verify(noticeRepository).saveAndFlush(captor.capture());
        assertEquals("important", captor.getValue().getPriority());
    }

    // =========================== V224：庆典发布 / 互动 ===========================

    @Test
    void publishBlessTypeRequiresSubjectEmployeeAndDerivesEventLabel() {
        UUID subjectId = UUID.randomUUID();
        Employee subject = new Employee();
        subject.setId(subjectId);
        subject.setFullName("张三");
        subject.setHireDate(BusinessTime.today().minusYears(3)); // 入职3周年
        when(employeeRepository.findById(subjectId)).thenReturn(Optional.of(subject));
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");
        when(noticeRepository.saveAndFlush(any())).thenAnswer(i -> i.getArgument(0));
        when(blessRepo.countByNoticeId(any())).thenReturn(0L);
        when(blessRepo.findTop5ByNoticeIdOrderByCreatedAtDesc(any())).thenReturn(List.of());

        // 标题留空 → 由 subjectName+eventLabel 自动补全
        NoticeDto dto = service.publish(new NoticePublishRequest(
                null, "今日寿星", "birthday",
                false, "normal", List.of(), "selected", null, null,
                null, null, null, subjectId, null));

        assertEquals("birthday", dto.type());
        assertEquals("bless", dto.interactionMode());
        assertEquals("张三", dto.subjectName());
        assertEquals("生日快乐", dto.eventLabel());
        assertEquals("祝 张三 生日快乐！", dto.title());
        // 庆典通知强制 audience=all（忽略 selected）
        assertEquals("all", dto.audienceScope());

        ArgumentCaptor<Notice> captor = ArgumentCaptor.forClass(Notice.class);
        verify(noticeRepository).saveAndFlush(captor.capture());
        assertEquals("bless", captor.getValue().getInteractionMode());
        assertEquals(subjectId, captor.getValue().getSubjectEmployeeId());
    }

    @Test
    void publishAnniversaryComputesYearsInEventLabel() {
        UUID subjectId = UUID.randomUUID();
        Employee subject = new Employee();
        subject.setId(subjectId);
        subject.setFullName("李四");
        subject.setHireDate(BusinessTime.today().minusYears(5));
        when(employeeRepository.findById(subjectId)).thenReturn(Optional.of(subject));
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");
        when(noticeRepository.saveAndFlush(any())).thenAnswer(i -> i.getArgument(0));
        when(blessRepo.countByNoticeId(any())).thenReturn(0L);
        when(blessRepo.findTop5ByNoticeIdOrderByCreatedAtDesc(any())).thenReturn(List.of());

        NoticeDto dto = service.publish(new NoticePublishRequest(
                "标题", "正文", "anniversary",
                false, "normal", List.of(), "all", null, null,
                null, null, null, subjectId, null));

        assertEquals("入职5周年", dto.eventLabel());
    }

    @Test
    void publishBlessWithoutSubjectIsRejected() {
        NoticePublishRequest req = new NoticePublishRequest(
                "标题", "正文", "birthday",
                false, "normal", List.of(), "all", null, null,
                null, null, null, null, null);

        assertThrows(ApiException.class, () -> service.publish(req));
        verify(noticeRepository, never()).saveAndFlush(any());
    }

    @Test
    void publishNonBlessUnaffectedByCelebrationLogic() {
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");
        when(noticeRepository.saveAndFlush(any())).thenAnswer(i -> i.getArgument(0));
        when(ackRepository.countByIdNoticeId(any())).thenReturn(0L);
        when(ackRepository.existsByIdNoticeIdAndIdUserId(any(), any())).thenReturn(false);
        when(ackRepository.findRecentAcknowledgers(any(), anyInt())).thenReturn(List.of());

        NoticeDto dto = service.publish(new NoticePublishRequest(
                "通知", "正文", "system",
                false, "normal", List.of(), "all", null, null,
                null, null, null, null, null));

        assertEquals("acknowledge", dto.interactionMode());
        assertNull(dto.subjectName());
        assertNull(dto.eventLabel());
    }

    @Test
    void acknowledgeIsIdempotentAndReturnsCurrentCount() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setType("announcement");
        notice.setInteractionMode("acknowledge");
        notice.setAudienceScope("all");
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));
        when(ackRepository.findById(new NoticeAcknowledgmentId(noticeId, userId)))
                .thenReturn(Optional.empty())
                .thenReturn(Optional.of(existingAck(noticeId, userId)));
        when(ackRepository.countByIdNoticeId(noticeId)).thenReturn(1L).thenReturn(1L);

        NoticeService.AckResult first = service.acknowledge(noticeId);
        assertEquals(1L, first.ackCount());
        assertTrue(first.myAcked());

        NoticeService.AckResult second = service.acknowledge(noticeId);
        assertTrue(second.myAcked());
        verify(ackRepository, atLeastOnce()).save(any());
    }

    @Test
    void acknowledgeRejectsNoticeWithoutAckMode() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setType("birthday");
        notice.setInteractionMode("bless");
        notice.setAudienceScope("all");
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));

        assertThrows(ApiException.class, () -> service.acknowledge(noticeId));
        verify(ackRepository, never()).save(any());
    }

    @Test
    void blessUpsertsAndWithdrawsCorrectly() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setType("birthday");
        notice.setInteractionMode("bless");
        notice.setAudienceScope("all");
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");

        // 第一次发送（新增）
        when(blessRepo.findByNoticeIdAndUserId(noticeId, userId)).thenReturn(Optional.empty());
        when(blessRepo.save(any())).thenAnswer(i -> i.getArgument(0));
        when(blessRepo.countByNoticeId(noticeId)).thenReturn(1L);

        NoticeService.BlessResult created = service.bless(noticeId, "生日快乐！");
        assertEquals(1L, created.blessingCount());
        assertEquals("生日快乐！", created.myBlessing());

        // 撤回
        when(blessRepo.countByNoticeId(noticeId)).thenReturn(0L);
        long afterWithdraw = service.withdrawBlessing(noticeId);
        assertEquals(0L, afterWithdraw);
        verify(blessRepo).deleteByNoticeIdAndUserId(noticeId, userId);
    }

    @Test
    void blessRejectsNoticeWithoutBlessMode() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setType("system");
        notice.setInteractionMode("acknowledge");
        notice.setAudienceScope("all");
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));

        assertThrows(ApiException.class, () -> service.bless(noticeId, "祝福"));
        verify(blessRepo, never()).save(any());
    }

    @Test
    void blessRejectsBlankAndOverlongContent() {
        UUID noticeId = UUID.randomUUID();
        Notice notice = new Notice();
        notice.setId(noticeId);
        notice.setType("birthday");
        notice.setInteractionMode("bless");
        notice.setAudienceScope("all");
        when(noticeRepository.findById(noticeId)).thenReturn(Optional.of(notice));

        assertThrows(ApiException.class, () -> service.bless(noticeId, "   "));
        assertThrows(ApiException.class, () -> service.bless(noticeId, "x".repeat(201)));
    }

    @Test
    void listBlessingsMarksMineAndLimitsPageSize() {
        UUID noticeId = UUID.randomUUID();
        UUID otherUser = UUID.randomUUID();
        UUID b1 = UUID.randomUUID();
        UUID b2 = UUID.randomUUID();
        when(blessRepo.findPage(eq(noticeId), anyInt(), anyInt())).thenReturn(List.of(
                blessingRow(b1, "张三", "生日快乐", otherUser),
                blessingRow(b2, "我", "同祝", userId)));
        when(blessRepo.countByNoticeId(noticeId)).thenReturn(2L);

        NoticeService.BlessingPage p = service.listBlessings(noticeId, 0, 50);
        assertEquals(2L, p.count());
        assertEquals(2, p.items().size());
        assertFalse(p.items().get(0).mine());     // 他人
        assertTrue(p.items().get(1).mine());       // 本人
    }

    @Test
    void listAcknowledgersDelegatesToProjectionQuery() {
        UUID noticeId = UUID.randomUUID();
        Instant t = Instant.now();
        when(ackRepository.findRecentAcknowledgers(eq(noticeId), anyInt())).thenReturn(List.of(
                ackerRow("张三", t),
                ackerRow("李四", t)));
        when(ackRepository.countByIdNoticeId(noticeId)).thenReturn(2L);

        NoticeService.AcknowledgerPage p = service.listAcknowledgers(noticeId, 8);
        assertEquals(2L, p.count());
        assertEquals(2, p.items().size());
        assertEquals("张三", p.items().get(0).name());
    }

    @Test
    void celebrationPreviewReturnsDerivedLabelAndTemplates() {
        UUID subjectId = UUID.randomUUID();
        Employee subject = new Employee();
        subject.setId(subjectId);
        subject.setFullName("王五");
        subject.setHireDate(BusinessTime.today().minusYears(2));
        when(employeeRepository.findById(subjectId)).thenReturn(Optional.of(subject));

        NoticeCelebrationPreviewDto dto = service.celebrationPreview(subjectId, "anniversary");
        assertEquals("王五", dto.subjectName());
        assertEquals("入职2周年", dto.eventLabel());
        assertEquals("祝 王五 入职2周年！", dto.suggestedTitle());
        assertFalse(dto.suggestedTemplates().isEmpty());
        // 模板只用 {name} 占位符（年数在 eventLabel 里，不在模板里）
        assertTrue(dto.suggestedTemplates().stream().noneMatch(t -> t.contains("{years}")));
        assertTrue(dto.suggestedTemplates().stream().allMatch(t -> t.contains("{name}")));
    }

    @Test
    void publishCelebrationBroadcastWritesBlessNoticeWithSubjectSnapshot() {
        UUID subjectId = UUID.randomUUID();
        when(employeeRepository.findById(subjectId)).thenReturn(Optional.empty());
        when(noticeRepository.saveAndFlush(any())).thenAnswer(i -> {
            Notice n = i.getArgument(0);
            n.setId(UUID.randomUUID());
            return n;
        });

        Notice n = service.publishCelebrationBroadcast(
                "birthday", subjectId, "赵六", "生日快乐", "公司");

        assertEquals("birthday", n.getType());
        assertEquals("bless", n.getInteractionMode());
        assertEquals("祝 赵六 生日快乐！", n.getTitle());
        assertEquals("公司", n.getPublisher());
        assertEquals("all", n.getAudienceScope());
        assertEquals("赵六", n.getSubjectName());
        assertEquals(subjectId, n.getSubjectEmployeeId());

        // V454：单人卡也落一行主角快照（幂等/跳转口径统一）
        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<NoticeCelebrationSubject>> subjectsCaptor =
                ArgumentCaptor.forClass(List.class);
        verify(subjectRepo).saveAll(subjectsCaptor.capture());
        assertEquals(1, subjectsCaptor.getValue().size());
        NoticeCelebrationSubject row = subjectsCaptor.getValue().getFirst();
        assertEquals(n.getId(), row.getNoticeId());
        assertEquals(subjectId, row.getEmployeeId());
        assertEquals("赵六", row.getEmployeeName());
        assertEquals("生日快乐", row.getEventLabel());
    }

    @Test
    void publishCelebrationGroupBroadcastMergesAllSubjectsIntoOneCard() {
        when(noticeRepository.saveAndFlush(any())).thenAnswer(i -> {
            Notice n = i.getArgument(0);
            n.setId(UUID.randomUUID());
            return n;
        });

        Notice n = service.publishCelebrationGroupBroadcast(
                "anniversary",
                List.of(
                        new NoticeService.CelebrationSubject(
                                UUID.randomUUID(), "张三", "入职5周年"),
                        new NoticeService.CelebrationSubject(
                                UUID.randomUUID(), "李四", "入职10周年")),
                "公司");

        assertEquals("anniversary", n.getType());
        assertEquals("bless", n.getInteractionMode());
        // 聚合卡：无单人外键，摘要快照 + 类型级标签（逐人标签在主角表）
        assertNull(n.getSubjectEmployeeId());
        assertEquals("张三、李四", n.getSubjectName());
        assertEquals("入职周年快乐", n.getEventLabel());
        assertEquals("祝 张三、李四 入职周年快乐！", n.getTitle());
        assertTrue(n.getContent().contains("2 位同事"));
        assertTrue(n.getContent().contains("张三（入职5周年）"));
        assertTrue(n.getContent().contains("李四（入职10周年）"));

        verify(noticeRepository, times(1)).saveAndFlush(any());
        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<NoticeCelebrationSubject>> subjectsCaptor =
                ArgumentCaptor.forClass(List.class);
        verify(subjectRepo).saveAll(subjectsCaptor.capture());
        assertEquals(2, subjectsCaptor.getValue().size());
        // 聚合卡模板面向「各位」，不含 {name} 占位符
        assertNotNull(n.getBlessingTemplates());
        assertTrue(n.getBlessingTemplates().contains("祝各位"));
        assertFalse(n.getBlessingTemplates().contains("{name}"));
    }

    @Test
    void publishCelebrationGroupBroadcastWithSingleSubjectKeepsPersonalCard() {
        when(noticeRepository.saveAndFlush(any())).thenAnswer(i -> {
            Notice n = i.getArgument(0);
            n.setId(UUID.randomUUID());
            return n;
        });
        UUID subjectId = UUID.randomUUID();

        Notice n = service.publishCelebrationGroupBroadcast(
                "birthday",
                List.of(new NoticeService.CelebrationSubject(
                        subjectId, "王五", "生日快乐")),
                "公司");

        // 单人卡保持原样式（外键 + 姓名 + {name} 模板），避免单人场景体验回退
        assertEquals(subjectId, n.getSubjectEmployeeId());
        assertEquals("祝 王五 生日快乐！", n.getTitle());
        assertTrue(n.getBlessingTemplates().contains("{name}"));
    }

    @Test
    void getCelebrationSettingsReadsThreeKeys() {
        when(systemSettings.readBool("celebration.auto_enabled", true)).thenReturn(true);
        when(systemSettings.readString("celebration.auto_types", "birthday,anniversary"))
                .thenReturn("birthday");
        when(systemSettings.readString("celebration.publisher_name", "公司"))
                .thenReturn("人力资源部");

        var dto = service.getCelebrationSettings();
        assertTrue(dto.autoEnabled());
        assertEquals(List.of("birthday"), dto.autoTypes());
        assertEquals("人力资源部", dto.publisherName());
    }

    // =========================== 庆典体验：我的今日 / 一键批量祝福 ===========================

    @Test
    void myCelebrationTodayReturnsBirthdayWhenTodayIsEmployeeBirthday() {
        UUID empId = UUID.randomUUID();
        Employee me = celebrationSubject(empId, "寿星", BusinessTime.today().minusYears(5).minusMonths(2));
        LocalDate today = BusinessTime.today();
        me.setBirthMonthDay(String.format("%02d-%02d", today.getMonthValue(), today.getDayOfMonth())); // 月日 = 今天
        when(authUser.getEmployeeId()).thenReturn(empId);
        when(employeeRepository.findById(empId)).thenReturn(Optional.of(me));
        UUID noticeId = UUID.randomUUID();
        when(subjectRepo.findCelebrationNoticeIds(eq(empId), eq("birthday"), any()))
                .thenReturn(List.of(noticeId));

        List<MyCelebrationTodayDto> items = service.myCelebrationToday();

        assertEquals(1, items.size());
        assertEquals("birthday", items.get(0).type());
        assertEquals("寿星", items.get(0).subjectName());
        assertEquals("生日快乐", items.get(0).eventLabel());
        assertEquals(noticeId, items.get(0).noticeId());
    }

    @Test
    void myCelebrationTodayReturnsAnniversaryOverOneYear() {
        UUID empId = UUID.randomUUID();
        Employee me = celebrationSubject(empId, "老员工", BusinessTime.today().minusYears(5)); // 5 年前的今天
        me.setBirthMonthDay(null);
        when(authUser.getEmployeeId()).thenReturn(empId);
        when(employeeRepository.findById(empId)).thenReturn(Optional.of(me));

        List<MyCelebrationTodayDto> items = service.myCelebrationToday();

        assertEquals(1, items.size());
        assertEquals("anniversary", items.get(0).type());
        assertEquals("入职5周年", items.get(0).eventLabel());
    }

    @Test
    void myCelebrationTodayIncludesTodaysWeddingAndNewbornNotices() {
        UUID empId = UUID.randomUUID();
        Employee me = celebrationSubject(empId, "新婚", BusinessTime.today().minusYears(5).minusDays(1));
        LocalDate nonBirthday = BusinessTime.today().minusDays(1);
        me.setBirthMonthDay(String.format("%02d-%02d", nonBirthday.getMonthValue(), nonBirthday.getDayOfMonth())); // 非今天，避免生日命中
        when(authUser.getEmployeeId()).thenReturn(empId);
        when(employeeRepository.findById(empId)).thenReturn(Optional.of(me));
        Notice wedding = new Notice();
        wedding.setId(UUID.randomUUID());
        wedding.setType("wedding");
        wedding.setEventLabel("新婚快乐");
        when(subjectRepo.findBySubjectAndTypesSince(eq(empId), any(), any()))
                .thenReturn(List.of(wedding));

        List<MyCelebrationTodayDto> items = service.myCelebrationToday();

        assertEquals(1, items.size());
        assertEquals("wedding", items.get(0).type());
        assertEquals(wedding.getId(), items.get(0).noticeId());
    }

    @Test
    void myCelebrationTodayEmptyWhenNothingMatches() {
        UUID empId = UUID.randomUUID();
        Employee me = celebrationSubject(empId, "普通", BusinessTime.today().minusYears(5).minusDays(1));
        LocalDate nonBirthday = BusinessTime.today().minusDays(1);
        me.setBirthMonthDay(String.format("%02d-%02d", nonBirthday.getMonthValue(), nonBirthday.getDayOfMonth()));
        when(authUser.getEmployeeId()).thenReturn(empId);
        when(employeeRepository.findById(empId)).thenReturn(Optional.of(me));
        when(subjectRepo.findBySubjectAndTypesSince(eq(empId), any(), any()))
                .thenReturn(List.of());

        assertTrue(service.myCelebrationToday().isEmpty());
    }

    @Test
    void myCelebrationTodayEmptyWhenUserHasNoEmployeeId() {
        when(authUser.getEmployeeId()).thenReturn(null);
        assertTrue(service.myCelebrationToday().isEmpty());
    }

    @Test
    void publishCelebrationBatchMergesEligibleEmployeesIntoOneGroupCard() {
        UUID a = UUID.randomUUID();
        UUID b = UUID.randomUUID();
        when(employeeRepository.findById(a)).thenReturn(
                Optional.of(celebrationSubject(a, "张三", BusinessTime.today().minusYears(2))));
        when(employeeRepository.findById(b)).thenReturn(
                Optional.of(celebrationSubject(b, "李四", BusinessTime.today().minusYears(4))));
        when(subjectRepo.existsCelebrationSince(any(), any(), any())).thenReturn(false);
        when(noticeRepository.saveAndFlush(any())).thenAnswer(i -> {
            Notice n = i.getArgument(0);
            n.setId(UUID.randomUUID());
            return n;
        });
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");

        CelebrationBatchResult result = service.publishCelebrationBatch(
                new CelebrationBatchRequest("birthday", List.of(a, b)));

        // V454：覆盖 2 位主角，但只发一张聚合卡
        assertEquals(2, result.published());
        assertEquals(0, result.skipped());
        assertEquals(1, result.notices());
        verify(noticeRepository, times(1)).saveAndFlush(any());
        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<NoticeCelebrationSubject>> subjectsCaptor =
                ArgumentCaptor.forClass(List.class);
        verify(subjectRepo).saveAll(subjectsCaptor.capture());
        assertEquals(2, subjectsCaptor.getValue().size());
    }

    @Test
    void publishCelebrationBatchSkipsAlreadyCelebrated() {
        UUID a = UUID.randomUUID();
        when(employeeRepository.findById(a)).thenReturn(
                Optional.of(celebrationSubject(a, "张三", BusinessTime.today().minusYears(2))));
        when(subjectRepo.existsCelebrationSince(any(), any(), any())).thenReturn(true);
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");

        CelebrationBatchResult result = service.publishCelebrationBatch(
                new CelebrationBatchRequest("birthday", List.of(a)));

        assertEquals(0, result.published());
        assertEquals(1, result.skipped());
        assertEquals(0, result.notices());
        verify(noticeRepository, never()).saveAndFlush(any());
        verify(subjectRepo, never()).saveAll(any());
    }

    @Test
    void publishCelebrationBatchRejectsNonCelebrationType() {
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");

        assertThrows(ApiException.class, () -> service.publishCelebrationBatch(
                new CelebrationBatchRequest("system", List.of(UUID.randomUUID()))));
    }

    @Test
    void publishCelebrationBatchRejectsEmptyEmployeeList() {
        when(authUser.getEmployeeId()).thenReturn(null);
        when(authUser.getLoginAccount()).thenReturn("hr");

        assertThrows(ApiException.class, () -> service.publishCelebrationBatch(
                new CelebrationBatchRequest("birthday", List.of())));
    }

    @Test
    void markReadByRoutesDedupesBlankFiltersAndCapsAtFifty() {
        when(stateRepository.markVisibleReadByRoutes(eq(userId), any())).thenReturn(3);
        String repeated = "/purchase/orders/" + UUID.randomUUID();
        List<String> routes = new java.util.ArrayList<>(List.of(
                repeated, repeated, " ", "",
                "/purchase/requests/" + UUID.randomUUID()));
        for (int i = 0; i < 60; i++) {
            routes.add("/purchase/orders/extra-" + i);
        }

        assertEquals(3, service.markReadByRoutes(routes));

        ArgumentCaptor<List<String>> captor = ArgumentCaptor.forClass(List.class);
        verify(stateRepository).markVisibleReadByRoutes(eq(userId), captor.capture());
        List<String> passed = captor.getValue();
        assertEquals(50, passed.size());
        assertFalse(passed.contains(" "));
        assertFalse(passed.contains(""));
        assertEquals(1, java.util.Collections.frequency(passed, repeated));
        // 保持首次出现顺序：去重后的前两项是业务路由，其余为追加项。
        assertEquals(repeated, passed.getFirst());
    }

    @Test
    void markReadByRoutesSkipsEmptyInputWithoutTouchingState() {
        assertEquals(0, service.markReadByRoutes(List.of()));
        assertEquals(0, service.markReadByRoutes(null));
        assertEquals(0, service.markReadByRoutes(List.of(" ", "")));
        verify(stateRepository, never()).markVisibleReadByRoutes(any(), any());
    }

    // ---------- 测试夹具 ----------

    private Notice arrivalNotice(Instant publishedAt, String title) {
        Notice notice = new Notice();
        notice.setId(UUID.randomUUID());
        notice.setTitle(title);
        notice.setContent("到达正文");
        notice.setType("announcement");
        notice.setPublisher("系统");
        notice.setPublishedAt(publishedAt);
        return notice;
    }

    private Employee celebrationSubject(UUID id, String name, LocalDate hireDate) {
        Employee e = new Employee();
        e.setId(id);
        e.setFullName(name);
        e.setHireDate(hireDate);
        return e;
    }

    private NoticeAcknowledgment existingAck(UUID noticeId, UUID userId) {
        NoticeAcknowledgment ack = new NoticeAcknowledgment();
        ack.setId(new NoticeAcknowledgmentId(noticeId, userId));
        ack.setAckedAt(Instant.now());
        return ack;
    }

    private NoticeBlessingRow blessingRow(UUID id, String name, String content, UUID userId) {
        return new NoticeBlessingRow() {
            @Override public UUID getId() { return id; }
            @Override public String getSenderName() { return name; }
            @Override public String getContent() { return content; }
            @Override public Instant getCreatedAt() { return Instant.now(); }
            @Override public UUID getUserId() { return userId; }
        };
    }

    private NoticeAcknowledgerRow ackerRow(String name, Instant ackedAt) {
        return new NoticeAcknowledgerRow() {
            @Override public UUID getUserId() { return UUID.randomUUID(); }
            @Override public String getName() { return name; }
            @Override public Instant getAckedAt() { return ackedAt; }
        };
    }
}
