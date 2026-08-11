package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.order.dto.OrderDetail;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.transaction.support.AbstractPlatformTransactionManager;
import org.springframework.transaction.support.DefaultTransactionStatus;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SubcontractOrderFinanceDecisionCommandServiceTest {

    @Test
    void approveAndDecisionDetailCommitInOneOuterTransaction() {
        UUID orderId = UUID.randomUUID();
        FinanceApproval decision = decision("APPROVED");
        ProcurementFinanceApprovalService finance =
                mock(ProcurementFinanceApprovalService.class);
        SubcontractOrderService orders = mock(SubcontractOrderService.class);
        OrderDetail detail = mock(OrderDetail.class);
        when(finance.approve("SUBCONTRACT", orderId, 1L))
                .thenReturn(decision);
        when(orders.financeDecisionResultDetail(orderId, decision))
                .thenReturn(detail);
        RecordingTransactionManager transactions =
                new RecordingTransactionManager();
        SubcontractOrderFinanceDecisionCommandService command = transactionalProxy(
                new SubcontractOrderFinanceDecisionCommandService(finance, orders),
                transactions);

        assertSame(detail, command.approve(orderId, 1L));
        assertEquals(1, transactions.commits);
        assertEquals(0, transactions.rollbacks);
        InOrder sequence = inOrder(finance, orders);
        sequence.verify(finance).approve("SUBCONTRACT", orderId, 1L);
        sequence.verify(orders).financeDecisionResultDetail(orderId, decision);
    }

    @Test
    void decisionDetailFailureRollsBackRejectedSubcontractDecision() {
        UUID orderId = UUID.randomUUID();
        FinanceApproval decision = decision("REJECTED");
        ProcurementFinanceApprovalService finance =
                mock(ProcurementFinanceApprovalService.class);
        SubcontractOrderService orders = mock(SubcontractOrderService.class);
        ApiException failure = new ApiException(
                ErrorCode.NOT_FOUND, "decision detail failed");
        when(finance.reject("SUBCONTRACT", orderId, 1L, "reason"))
                .thenReturn(decision);
        when(orders.financeDecisionResultDetail(orderId, decision))
                .thenThrow(failure);
        RecordingTransactionManager transactions =
                new RecordingTransactionManager();
        SubcontractOrderFinanceDecisionCommandService command = transactionalProxy(
                new SubcontractOrderFinanceDecisionCommandService(finance, orders),
                transactions);

        assertSame(failure, assertThrows(
                ApiException.class,
                () -> command.reject(orderId, 1L, "reason")));
        assertEquals(0, transactions.commits);
        assertEquals(1, transactions.rollbacks);
        InOrder sequence = inOrder(finance, orders);
        sequence.verify(finance)
                .reject("SUBCONTRACT", orderId, 1L, "reason");
        sequence.verify(orders).financeDecisionResultDetail(orderId, decision);
    }

    private static FinanceApproval decision(String status) {
        return new FinanceApproval(
                UUID.randomUUID(),
                status,
                1,
                2,
                UUID.randomUUID(),
                UUID.randomUUID(),
                "finance reviewer",
                null,
                OffsetDateTime.now(),
                List.of());
    }

    private static SubcontractOrderFinanceDecisionCommandService transactionalProxy(
            SubcontractOrderFinanceDecisionCommandService target,
        RecordingTransactionManager transactions) {
        ProxyFactory proxy = new ProxyFactory(target);
        TransactionInterceptor interceptor = new TransactionInterceptor();
        interceptor.setTransactionManager(transactions);
        interceptor.setTransactionAttributeSource(
                new AnnotationTransactionAttributeSource());
        proxy.addAdvice(interceptor);
        return (SubcontractOrderFinanceDecisionCommandService) proxy.getProxy();
    }

    private static final class RecordingTransactionManager
            extends AbstractPlatformTransactionManager {
        private int commits;
        private int rollbacks;

        @Override
        protected Object doGetTransaction() {
            return new Object();
        }

        @Override
        protected void doBegin(
                Object transaction, TransactionDefinition definition) {
        }

        @Override
        protected void doCommit(DefaultTransactionStatus status) {
            commits++;
        }

        @Override
        protected void doRollback(DefaultTransactionStatus status) {
            rollbacks++;
        }
    }
}
