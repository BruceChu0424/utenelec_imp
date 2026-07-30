package com.uten.imp.features.suggestion;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.suggestion.dto.SuggestionReplyRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.repository.Lock;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SuggestionPagingAndIntegrityTest {

    private SuggestionRepository suggestionRepository;
    private SuggestionReplyRepository replyRepository;
    private SuggestionLikeRepository likeRepository;
    private SuggestionService service;
    private AuthUser user;

    @BeforeEach
    void setUp() {
        suggestionRepository = mock(SuggestionRepository.class);
        replyRepository = mock(SuggestionReplyRepository.class);
        likeRepository = mock(SuggestionLikeRepository.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        user = new AuthUser(
                UUID.randomUUID(),
                null,
                "tester",
                Set.of(),
                Set.of(),
                false,
                true,
                false);
        when(currentUser.get()).thenReturn(Optional.of(user));
        service = new SuggestionService(
                suggestionRepository,
                replyRepository,
                likeRepository,
                mock(EmployeeRepository.class),
                currentUser);
    }

    @Test
    void listUsesStableServerPageAndOnlyCurrentPageBatchStatistics() {
        Suggestion first = suggestion("reviewing");
        Suggestion second = suggestion("submitted");
        Pageable repositoryPage = PageRequest.of(1, 20);
        when(suggestionRepository.findBySubmitterIdAndCategory(
                eq(user.getId()), eq("process"), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(first, second), repositoryPage, 42));
        when(likeRepository.findLikedSuggestionIds(
                eq(user.getId()), anyList())).thenReturn(List.of(second.getId()));

        SuggestionLikeRepository.SuggestionCount likeCount =
                mock(SuggestionLikeRepository.SuggestionCount.class);
        when(likeCount.getSuggestionId()).thenReturn(first.getId());
        when(likeCount.getTotal()).thenReturn(7L);
        when(likeRepository.countBySuggestionIds(anyList())).thenReturn(List.of(likeCount));

        SuggestionReplyRepository.SuggestionCount replyCount =
                mock(SuggestionReplyRepository.SuggestionCount.class);
        when(replyCount.getSuggestionId()).thenReturn(first.getId());
        when(replyCount.getTotal()).thenReturn(3L);
        when(replyRepository.countBySuggestionIds(anyList())).thenReturn(List.of(replyCount));

        var result = service.list("mine", "process", 2, 20);

        assertEquals(2, result.getPage());
        assertEquals(20, result.getSize());
        assertEquals(42, result.getTotal());
        assertEquals(3, result.getTotalPages());
        assertEquals(7, result.getItems().get(0).likes());
        assertEquals(3, result.getItems().get(0).replyCount());
        assertFalse(result.getItems().get(0).likedByMe());
        assertEquals(0, result.getItems().get(0).replies().size());
        assertTrue(result.getItems().get(1).likedByMe());
        assertEquals(0, result.getItems().get(1).likes());

        var pageableCaptor = org.mockito.ArgumentCaptor.forClass(Pageable.class);
        verify(suggestionRepository).findBySubmitterIdAndCategory(
                eq(user.getId()), eq("process"), pageableCaptor.capture());
        List<Sort.Order> orders = pageableCaptor.getValue().getSort().stream().toList();
        assertEquals(List.of("submittedAt", "id"),
                orders.stream().map(Sort.Order::getProperty).toList());
        assertTrue(orders.stream().allMatch(order -> !order.isAscending()));
        verify(likeRepository, never()).countByIdSuggestionId(any());
        verify(replyRepository, never()).countBySuggestionId(any());
    }

    @Test
    void listRejectsInvalidScopeCategoryAndPageBounds() {
        assertThrows(ApiException.class, () -> service.list("other", null, 1, 20));
        assertThrows(ApiException.class, () -> service.list(null, "unknown", 1, 20));
        assertThrows(ApiException.class, () -> service.list(null, null, 0, 20));
        assertThrows(ApiException.class, () -> service.list(null, null, 1, 0));
        assertThrows(ApiException.class, () -> service.list(null, null, 1, 101));
    }

    @Test
    void likeToggleLocksParentRowBeforeExistsThenMutation() {
        Suggestion suggestion = suggestion("submitted");
        when(suggestionRepository.findByIdForUpdate(suggestion.getId()))
                .thenReturn(Optional.of(suggestion));
        when(likeRepository.existsById(any())).thenReturn(false);
        when(likeRepository.countByIdSuggestionId(suggestion.getId())).thenReturn(1L);
        when(replyRepository.countBySuggestionId(suggestion.getId())).thenReturn(2L);

        var result = service.toggleLike(suggestion.getId());

        assertTrue(result.likedByMe());
        assertEquals(1, result.likes());
        assertEquals(2, result.replyCount());
        verify(suggestionRepository).findByIdForUpdate(suggestion.getId());
        verify(likeRepository).save(any(SuggestionLike.class));
        verify(likeRepository).flush();
    }

    @Test
    void repositoryDeclaresDatabaseWriteLockForConcurrentMutations() throws Exception {
        Lock lock = SuggestionRepository.class
                .getMethod("findByIdForUpdate", UUID.class)
                .getAnnotation(Lock.class);

        assertNotNull(lock);
        assertEquals(LockModeType.PESSIMISTIC_WRITE, lock.value());
    }

    @Test
    void statusMachineRequiresReviewingBeforeTerminalState() {
        Suggestion suggestion = suggestion("submitted");
        when(suggestionRepository.findByIdForUpdate(suggestion.getId()))
                .thenReturn(Optional.of(suggestion));

        assertThrows(
                ApiException.class,
                () -> service.reply(
                        suggestion.getId(),
                        new SuggestionReplyRequest("直接结案不合法", "resolved")));

        assertEquals("submitted", suggestion.getStatus());
        verify(replyRepository, never()).saveAndFlush(any());
    }

    @Test
    void statusMachineAllowsForwardProgressAndSameStateReplyOnly() {
        Suggestion suggestion = suggestion("submitted");
        when(suggestionRepository.findByIdForUpdate(suggestion.getId()))
                .thenReturn(Optional.of(suggestion));
        stubReplyResponse(suggestion);

        service.reply(
                suggestion.getId(),
                new SuggestionReplyRequest("开始评估建议", "reviewing"));

        assertEquals("reviewing", suggestion.getStatus());
        verify(suggestionRepository).save(suggestion);
        verify(replyRepository).saveAndFlush(any(SuggestionReply.class));
    }

    @Test
    void terminalStatusCannotRollbackButCanReceiveReplyWithoutStateChange() {
        Suggestion suggestion = suggestion("resolved");
        when(suggestionRepository.findByIdForUpdate(suggestion.getId()))
                .thenReturn(Optional.of(suggestion));

        assertThrows(
                ApiException.class,
                () -> service.reply(
                        suggestion.getId(),
                        new SuggestionReplyRequest("尝试回退", "reviewing")));

        stubReplyResponse(suggestion);
        service.reply(
                suggestion.getId(),
                new SuggestionReplyRequest("补充实施结果", null));
        assertEquals("resolved", suggestion.getStatus());
        verify(replyRepository).saveAndFlush(any(SuggestionReply.class));
    }

    private void stubReplyResponse(Suggestion suggestion) {
        when(replyRepository.findBySuggestionIdOrderByRepliedAtAsc(suggestion.getId()))
                .thenReturn(List.of());
        when(likeRepository.existsById(any())).thenReturn(false);
        when(likeRepository.countByIdSuggestionId(suggestion.getId())).thenReturn(0L);
    }

    private Suggestion suggestion(String status) {
        Suggestion suggestion = new Suggestion();
        suggestion.setSubmitterId(user.getId());
        suggestion.setSubmitterName("测试员工");
        suggestion.setCategory("process");
        suggestion.setTitle("建议标题");
        suggestion.setContent("建议正文至少十个字符");
        suggestion.setStatus(status);
        suggestion.setSubmittedAt(Instant.parse("2026-07-30T08:00:00Z"));
        return suggestion;
    }
}
