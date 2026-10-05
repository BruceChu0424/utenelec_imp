package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WorkshopStockCountPostingPort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@SuppressWarnings("unchecked")
class StockCountNoticeHandlerTest {
    private final JdbcTemplate db = mock(JdbcTemplate.class);
    private final NoticeService notices = mock(NoticeService.class);
    private final NoticePermissionCandidateQuery candidates = mock(NoticePermissionCandidateQuery.class);
    private final UserAccountRepository users = mock(UserAccountRepository.class);
    private final PermissionResolver permissions = mock(PermissionResolver.class);
    private final WorkshopStockCountPostingPort workshop = mock(WorkshopStockCountPostingPort.class);
    private final WarehouseTaskScopePort warehouseScopes = mock(WarehouseTaskScopePort.class);
    private final StockCountNoticeHandler handler = new StockCountNoticeHandler(db, notices, candidates, users, permissions,
            workshop, new WarehouseNoticeRouter(warehouseScopes));

    StockCountNoticeHandlerTest() {
        // 默认: 唯一分发规则原样返回池(还没配置负责人)。
        when(warehouseScopes.noticeRecipients(any(), any()))
                .thenAnswer(call -> List.copyOf((java.util.Collection<UUID>) call.getArgument(0)));
    }
    private final UUID request = UUID.randomUUID(), warehouse = UUID.randomUUID(), submitter = UUID.randomUUID();

    @Test void workshopReviewRecipientsNeedCurrentReviewPermissionNoticePermissionAndExactWarehouseScope() {
        header("WAREHOUSE", "PENDING");
        UserAccount allowed = user(), otherWorkshop = user(), revoked = user(), noNotices = user();
        pool(allowed, otherWorkshop, revoked, noNotices);
        when(permissions.permsOf(allowed)).thenReturn(Set.of("notice:read", "stock:count:warehouse_review"));
        when(permissions.permsOf(otherWorkshop)).thenReturn(Set.of("notice:read", "stock:count:warehouse_review"));
        when(permissions.permsOf(revoked)).thenReturn(Set.of("notice:read"));
        when(permissions.permsOf(noNotices)).thenReturn(Set.of("stock:count:warehouse_review"));
        when(workshop.canAccessWarehouseForUser(warehouse, allowed.getId())).thenReturn(true);
        deliver("STOCK_COUNT_SUBMITTED");
        verify(notices).publishForUser(eq(allowed.getId()), anyString(), anyString(), eq("approval"), eq("库存盘点"),
                eq("/warehouse/stock-count-review?requestId=" + request), eq(StockCountNoticeHandler.WAREHOUSE_EVENT), eq("important"), eq(request));
        verifyNoMoreInteractions(notices);
    }

    @Test void registeredKeepersNarrowWarehouseReviewToResponsiblePermissionHolders() {
        // ADR-149 唯一分发规则: 池 = 持审核与通知权限且能看这个仓的人; 再由规则收窄到该仓子仓负责人。
        // 负责人没权限不进池, 非负责人有权限也不发。
        header("WAREHOUSE", "PENDING");
        UserAccount keeper = user(), keeperWithoutPerm = user(), outsiderWithPerm = user();
        pool(keeper, keeperWithoutPerm, outsiderWithPerm);
        when(permissions.permsOf(keeper)).thenReturn(Set.of("notice:read", "stock:count:warehouse_review"));
        when(permissions.permsOf(keeperWithoutPerm)).thenReturn(Set.of("notice:read"));
        when(permissions.permsOf(outsiderWithPerm)).thenReturn(Set.of("notice:read", "stock:count:warehouse_review"));
        when(workshop.canAccessWarehouseForUser(warehouse, keeper.getId())).thenReturn(true);
        when(workshop.canAccessWarehouseForUser(warehouse, outsiderWithPerm.getId())).thenReturn(true);
        when(warehouseScopes.noticeRecipients(anyCollection(), eq(List.of(warehouse)))).thenAnswer(call ->
                ((java.util.Collection<UUID>) call.getArgument(0)).stream()
                        .filter(id -> id.equals(keeper.getId()) || id.equals(keeperWithoutPerm.getId())).toList());
        deliver("STOCK_COUNT_SUBMITTED");
        verify(warehouseScopes).noticeRecipients(
                argThat(pool -> pool.size() == 2 && pool.contains(keeper.getId()) && pool.contains(outsiderWithPerm.getId())),
                eq(List.of(warehouse)));
        verify(notices).publishForUser(eq(keeper.getId()), anyString(), anyString(), eq("approval"), eq("库存盘点"),
                eq("/warehouse/stock-count-review?requestId=" + request), eq(StockCountNoticeHandler.WAREHOUSE_EVENT), eq("important"), eq(request));
        verifyNoMoreInteractions(notices);
    }

    @Test void financeQueueUsesFinancePermissionAndDoesNotCallWorkshopScope() {
        header("FINANCE", "PENDING");
        var finance = user(); pool(finance);
        when(permissions.permsOf(finance)).thenReturn(Set.of("notice:read", "stock:count:finance_review"));
        deliver("STOCK_COUNT_SUBMITTED");
        verify(notices).publishForUser(eq(finance.getId()), anyString(), anyString(), eq("approval"), eq("库存盘点"),
                eq("/finance/stock-count-review?requestId=" + request), eq(StockCountNoticeHandler.FINANCE_EVENT), eq("important"), eq(request));
        verifyNoInteractions(workshop);
    }

    @Test void lateSubmissionCannotReopenAnAlreadyCompletedReviewTask() {
        header("FINANCE", "APPROVED"); deliver("STOCK_COUNT_SUBMITTED");
        verifyNoInteractions(notices, candidates, users, permissions, workshop);
    }

    @Test void rejectedRequestResolvesReviewerCardsAndNotifiesOnlyItsSubmitter() {
        header("WAREHOUSE", "REJECTED");
        var maker = user(); maker.setId(submitter);
        when(users.findById(submitter)).thenReturn(Optional.of(maker));
        when(permissions.permsOf(maker)).thenReturn(Set.of("notice:read", "stock:count:submit"));
        deliver("STOCK_COUNT_REJECTED");
        verify(notices).resolveReviewNotices("STOCK_COUNT_REQUEST", request, "REJECTED");
        verify(notices).publishForUser(eq(submitter), contains("已退回"), contains("库存未"), eq("workflow"), eq("库存盘点"),
                eq("/stock/count-requests?requestId=" + request), eq("STOCK_COUNT_REJECTED"), eq("normal"), isNull());
        verifyNoInteractions(candidates, workshop);
    }

    @Test void catalogAndFeedEligibilityUseTheSameSeparateReviewAuthorities() {
        assertThat(ReviewNoticeCatalog.of(StockCountNoticeHandler.FINANCE_EVENT).orElseThrow().aggregateKind())
                .isEqualTo("STOCK_COUNT_REQUEST");
        assertThat(ReviewNoticeAudience.eligible(StockCountNoticeHandler.FINANCE_EVENT,
                Set.of("notice:read", "stock:count:finance_review"), Set.of())).isTrue();
        assertThat(ReviewNoticeAudience.eligible(StockCountNoticeHandler.WAREHOUSE_EVENT,
                Set.of("notice:read", "stock:count:finance_review"), Set.of())).isFalse();
    }

    private void header(String route, String status) {
        when(db.queryForList(anyString(), eq(request))).thenReturn(List.of(Map.of("id", request, "request_no", "PD01",
                "warehouse_id", warehouse, "warehouse_name", "测试仓", "review_route", route, "status", status,
                "submitted_by", submitter, "review_reason", "数量请复核")));
    }
    private void pool(UserAccount... accounts) {
        var ids = java.util.Arrays.stream(accounts).map(UserAccount::getId).collect(java.util.stream.Collectors.toSet());
        when(candidates.possibleUsers(anySet())).thenReturn(Optional.of(ids));
        when(users.findAllById(ids)).thenReturn(List.of(accounts));
    }
    private static UserAccount user() {
        var user = new UserAccount(); user.setId(UUID.randomUUID()); user.setEmployeeId(UUID.randomUUID()); user.setStatus("active"); return user;
    }
    private void deliver(String type) { handler.handle(UUID.randomUUID(), type, request, JsonNodeFactory.instance.objectNode(), submitter); }
}
