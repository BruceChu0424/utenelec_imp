package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class SalesOrderFinanceConfirmServiceTest {

    @Test
    void modifiedOrderRejectsMissingOrStaleReviewVersionBeforeDecision() {
        SalesOrder order = approvedOrder();
        order.setFinanceReviewRevision(2);
        Fixture fixture = fixture(order);
        assertThrows(ApiException.class, () -> fixture.service().confirm(order.getId(), null));
        assertThrows(ApiException.class, () -> fixture.service().confirm(order.getId(),
                new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null, 1L)));
        assertThrows(ApiException.class, () -> fixture.service().reject(order.getId(),
                new SalesOrderFinanceConfirmService.FinanceRejectRequest("金额需修改", 1L)));
        assertFalse(order.isFinanceConfirmed());
        assertFalse(order.isFinanceRejected());
        verifyNoInteractions(fixture.notice());
        fixture.service().confirm(order.getId(),
                new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null, 2L));
        assertTrue(order.isFinanceConfirmed());
    }

    @Test
    void staleVersionInBatchPreventsEveryDecision() {
        SalesOrder first = approvedOrder();
        SalesOrder second = approvedOrder();
        second.setFinanceReviewRevision(1);
        Fixture fixture = fixture(Map.of(first.getId(), first, second.getId(), second));
        assertThrows(ApiException.class, () -> fixture.service().confirmBatch(
                new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(
                        List.of(first.getId(), second.getId()), null,
                        Map.of(first.getId(), 0L, second.getId(), 0L))));
        assertFalse(first.isFinanceConfirmed());
        assertFalse(second.isFinanceConfirmed());
        verifyNoInteractions(fixture.notice());
    }

    @Test
    void rejectedOrderMustBeRevisedBeforeFinanceCanConfirm() {
        SalesOrder order = approvedOrder();
        Fixture fixture = fixture(order);

        fixture.service().reject(
                order.getId(),
                new SalesOrderFinanceConfirmService.FinanceRejectRequest("金额需核对"));

        assertTrue(order.isFinanceRejected());
        assertEquals("金额需核对", order.getFinanceRejectedReason());
        assertThrows(
                ApiException.class,
                () -> fixture.service().confirm(order.getId(), null));

        // 相同请求重放幂等；不同原因不能覆盖第一次已提交的审核事实。
        fixture.service().reject(
                order.getId(),
                new SalesOrderFinanceConfirmService.FinanceRejectRequest("金额需核对"));
        assertThrows(
                ApiException.class,
                () -> fixture.service().reject(
                        order.getId(),
                        new SalesOrderFinanceConfirmService.FinanceRejectRequest("改成其它原因")));

        verify(fixture.repository(), times(4))
                .findActiveByIdForUpdate(order.getId());
        verify(fixture.notice(), times(1))
                .notifyOrderFinanceRejected(order.getId(), "金额需核对");
        assertFalse(order.isFinanceConfirmed());
    }

    @Test
    void confirmedDecisionIsIdempotentAndWinsAgainstLaterReject() {
        SalesOrder order = approvedOrder();
        Fixture fixture = fixture(order);

        fixture.service().confirm(
                order.getId(),
                new SalesOrderFinanceConfirmService.FinanceConfirmRequest("同意"));
        fixture.service().confirm(order.getId(), null);

        assertTrue(order.isFinanceConfirmed());
        assertEquals("同意", order.getFinanceConfirmRemark());
        assertThrows(
                ApiException.class,
                () -> fixture.service().reject(
                        order.getId(),
                        new SalesOrderFinanceConfirmService.FinanceRejectRequest("过期页面驳回")));
        verify(fixture.notice(), times(1))
                .notifyOrderFinanceConfirmed(order.getId());
    }

    @Test
    void batchConfirmDeduplicatesSortsAndUsesOneDecisionSnapshot() {
        UUID firstId = UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID secondId = UUID.fromString("ffffffff-0000-0000-0000-000000000002");
        SalesOrder first = approvedOrder(firstId);
        SalesOrder second = approvedOrder(secondId);
        Fixture fixture = fixture(Map.of(firstId, first, secondId, second));

        SalesOrderFinanceConfirmService.FinanceBatchConfirmResult result =
                fixture.service().confirmBatch(
                        new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(
                                List.of(secondId, firstId, secondId), "  批量核对通过  "));

        assertEquals(2, result.requestedCount());
        assertEquals(2, result.newlyConfirmedCount());
        assertEquals(0, result.alreadyConfirmedCount());
        assertEquals(List.of(firstId, secondId), result.orderIds());
        assertTrue(first.isFinanceConfirmed());
        assertTrue(second.isFinanceConfirmed());
        assertEquals("批量核对通过", first.getFinanceConfirmRemark());
        assertEquals(first.getFinanceConfirmRemark(), second.getFinanceConfirmRemark());
        assertEquals(fixture.employeeId(), first.getFinanceConfirmedBy());
        assertEquals(first.getFinanceConfirmedBy(), second.getFinanceConfirmedBy());
        assertEquals(first.getFinanceConfirmedAt(), second.getFinanceConfirmedAt());

        InOrder lockOrder = inOrder(fixture.repository());
        lockOrder.verify(fixture.repository()).findActiveByIdForUpdate(firstId);
        lockOrder.verify(fixture.repository()).findActiveByIdForUpdate(secondId);
        verify(fixture.notice()).notifyOrderFinanceConfirmed(firstId);
        verify(fixture.notice()).notifyOrderFinanceConfirmed(secondId);
    }

    @Test
    void batchConfirmValidatesEveryLockedOrderBeforeWritingAnyOrder() {
        UUID validId = UUID.fromString("00000000-0000-0000-0000-000000000011");
        UUID rejectedId = UUID.fromString("00000000-0000-0000-0000-000000000012");
        SalesOrder valid = approvedOrder(validId);
        SalesOrder rejected = approvedOrder(rejectedId);
        rejected.setFinanceRejected(true);
        Fixture fixture = fixture(Map.of(validId, valid, rejectedId, rejected));

        assertThrows(
                ApiException.class,
                () -> fixture.service().confirmBatch(
                        new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(
                                List.of(validId, rejectedId), null)));

        assertFalse(valid.isFinanceConfirmed());
        assertFalse(rejected.isFinanceConfirmed());
        verify(fixture.repository(), never()).save(any(SalesOrder.class));
        verifyNoInteractions(fixture.notice());
    }

    @Test
    void batchConfirmTreatsAlreadyConfirmedOrderAsIdempotentNoOp() {
        UUID existingId = UUID.fromString("00000000-0000-0000-0000-000000000021");
        UUID freshId = UUID.fromString("00000000-0000-0000-0000-000000000022");
        SalesOrder existing = approvedOrder(existingId);
        UUID originalActor = UUID.randomUUID();
        OffsetDateTime originalTime = OffsetDateTime.parse("2026-08-20T10:15:30Z");
        existing.setFinanceConfirmed(true);
        existing.setFinanceConfirmedBy(originalActor);
        existing.setFinanceConfirmedAt(originalTime);
        existing.setFinanceConfirmRemark("原确认");
        SalesOrder fresh = approvedOrder(freshId);
        Fixture fixture = fixture(Map.of(existingId, existing, freshId, fresh));

        SalesOrderFinanceConfirmService.FinanceBatchConfirmResult result =
                fixture.service().confirmBatch(
                        new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(
                                List.of(freshId, existingId), "新备注"));

        assertEquals(2, result.requestedCount());
        assertEquals(1, result.newlyConfirmedCount());
        assertEquals(1, result.alreadyConfirmedCount());
        assertEquals(originalActor, existing.getFinanceConfirmedBy());
        assertEquals(originalTime, existing.getFinanceConfirmedAt());
        assertEquals("原确认", existing.getFinanceConfirmRemark());
        assertTrue(fresh.isFinanceConfirmed());
        verify(fixture.repository(), never()).save(existing);
        verify(fixture.notice(), never()).notifyOrderFinanceConfirmed(existingId);
        verify(fixture.notice()).notifyOrderFinanceConfirmed(freshId);
    }

    @Test
    void batchConfirmRejectsMoreThanOneHundredRawIdsBeforeLocking() {
        Fixture fixture = fixture(Map.of());
        List<UUID> ids = IntStream.rangeClosed(1, 101)
                .mapToObj(value -> new UUID(0L, value))
                .toList();

        assertThrows(
                ApiException.class,
                () -> fixture.service().confirmBatch(
                        new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(
                                ids, null)));

        verifyNoInteractions(fixture.repository());
        verifyNoInteractions(fixture.notice());
    }

    @Test
    void pendingKeywordIsBoundToBillClientAndSellerQueries() {
        EntityManager entityManager = mock(EntityManager.class);
        Query countQuery = mock(Query.class);
        Query rowsQuery = mock(Query.class);
        when(entityManager.createNativeQuery(anyString()))
                .thenReturn(countQuery, rowsQuery);
        when(countQuery.setParameter(anyString(), any())).thenReturn(countQuery);
        when(rowsQuery.setParameter(anyString(), any())).thenReturn(rowsQuery);
        when(countQuery.getSingleResult()).thenReturn(0L);
        when(rowsQuery.getResultList()).thenReturn(List.of());
        SalesOrderFinanceConfirmService service =
                new SalesOrderFinanceConfirmService(
                        entityManager,
                        mock(SalesOrderRepository.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class),
                        mock(ChainNoticeService.class),
                        mock(SalesOrderFinanceConfirmerEligibility.class),
                        mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                        mock(SalesOrderRevisionService.class));

        assertEquals(0, service.pending(1, 20, false, "  AcMe  ").getTotal());

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager, times(2)).createNativeQuery(sql.capture());
        for (String statement : sql.getAllValues()) {
            assertTrue(statement.contains("LOWER(COALESCE(o.bill_no"));
            assertTrue(statement.contains("LOWER(COALESCE(c.name"));
            assertTrue(statement.contains("LOWER(COALESCE(e.full_name"));
        }
        verify(countQuery).setParameter("keyword", "acme");
        verify(rowsQuery).setParameter("keyword", "acme");
    }

    private static SalesOrder approvedOrder() {
        return approvedOrder(UUID.randomUUID());
    }

    private static SalesOrder approvedOrder(UUID orderId) {
        SalesOrder order = new SalesOrder();
        order.setId(orderId);
        order.setStatus((short) 1);
        order.setClosed(false);
        order.setStopped(false);
        order.setFinanceConfirmed(false);
        order.setFinanceRejected(false);
        return order;
    }

    private static Fixture fixture(SalesOrder order) {
        return fixture(Map.of(order.getId(), order));
    }

    private static Fixture fixture(Map<UUID, SalesOrder> orders) {
        EntityManager entityManager = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(eq("orderId"), any(UUID.class))).thenReturn(query);
        when(query.getSingleResult()).thenReturn(0L);

        SalesOrderRepository repository = mock(SalesOrderRepository.class);
        when(repository.findActiveByIdForUpdate(any(UUID.class)))
                .thenAnswer(invocation -> Optional.ofNullable(
                        orders.get(invocation.getArgument(0, UUID.class))));
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(userId);
        when(currentUser.requireEmployeeId()).thenReturn(employeeId);
        SalesOrderFinanceConfirmerEligibility eligibility =
                mock(SalesOrderFinanceConfirmerEligibility.class);
        when(eligibility.isEligible(userId)).thenReturn(true);
        ChainNoticeService notice = mock(ChainNoticeService.class);
        SalesOrderFinanceConfirmService service =
                new SalesOrderFinanceConfirmService(
                        entityManager,
                        repository,
                        currentUser,
                        mock(TxSessionVars.class),
                        notice,
                        eligibility,
                        mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                        mock(SalesOrderRevisionService.class));
        return new Fixture(service, repository, notice, employeeId);
    }

    private record Fixture(
            SalesOrderFinanceConfirmService service,
            SalesOrderRepository repository,
            ChainNoticeService notice,
            UUID employeeId) {
    }
}
