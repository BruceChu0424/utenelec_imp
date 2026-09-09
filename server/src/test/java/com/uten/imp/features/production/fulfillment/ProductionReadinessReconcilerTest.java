package com.uten.imp.features.production.fulfillment;

import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.SimpleTransactionStatus;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionReadinessReconcilerTest {
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final PlatformTransactionManager transactions = mock(PlatformTransactionManager.class);
    private final ProductionPlanMutationFootprintService footprint = mock(ProductionPlanMutationFootprintService.class);
    private final ProductionExecutionReadinessService readiness = mock(ProductionExecutionReadinessService.class);
    private final ProductionReadinessReconciler service = new ProductionReadinessReconciler(jdbc, transactions, footprint, readiness);

    @Test void oldSchemaStartsWithoutAttemptingUnavailableSystemWrites() {
        when(transactions.getTransaction(any())).thenAnswer(call -> new SimpleTransactionStatus());
        when(jdbc.queryForObject(contains("to_regprocedure"), eq(Boolean.class))).thenReturn(false);
        assertThat(service.runBatch()).isZero();
        verifyNoInteractions(footprint, readiness);
        verify(transactions).getTransaction(argThat(TransactionDefinition::isReadOnly));
    }

    @Test void aBusyPlanDoesNotPreventTheNextIndependentTransaction() {
        ready();
        var first = candidate(1); var second = candidate(2);
        when(jdbc.query(anyString(), any(RowMapper.class), any(), any())).thenReturn(List.of(first, second));
        doThrow(new IllegalStateException("busy")).when(footprint).lockPlan(first.planId(), List.of());
        assertThat(service.runBatch()).isEqualTo(2);
        verify(readiness, never()).reconcileWaitingSegment(first.planId(), first.segmentId(), first.warehouseId());
        verify(readiness).reconcileWaitingSegment(second.planId(), second.segmentId(), second.warehouseId());
        verify(transactions, times(2)).getTransaction(argThat(definition -> !definition.isReadOnly()
                && definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRES_NEW));
    }

    @Test void fullBatchContinuesAfterItsLastUuidAndWrapsOnlyAfterTheTail() {
        ready();
        List<ProductionReadinessReconciler.Candidate> first = IntStream.rangeClosed(1,25).mapToObj(this::candidate).toList();
        List<UUID> cursors = new ArrayList<>(); AtomicInteger calls = new AtomicInteger();
        when(jdbc.query(anyString(), any(RowMapper.class), any(), any())).thenAnswer(call -> {
            cursors.add(call.getArgument(2));
            return calls.getAndIncrement() == 0 ? first : List.of(candidate(26));
        });
        assertThat(service.runBatch()).isEqualTo(25);
        assertThat(service.runBatch()).isEqualTo(1);
        assertThat(service.runBatch()).isEqualTo(1);
        assertThat(cursors).containsExactly(null, first.getLast().segmentId(), null);
    }

    private void ready() {
        when(jdbc.queryForObject(contains("to_regprocedure"), eq(Boolean.class))).thenReturn(true);
        when(transactions.getTransaction(any())).thenAnswer(call -> new SimpleTransactionStatus());
    }

    private ProductionReadinessReconciler.Candidate candidate(int index) {
        return new ProductionReadinessReconciler.Candidate(new UUID(0,index), new UUID(1,index), new UUID(2,index));
    }
}
