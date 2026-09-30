package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.AiJobUsagePort;
import com.uten.imp.application.port.SalesMasterLearningPort.LearnedLine;
import com.uten.imp.application.port.SalesMasterLearningPort.SalesLearningRequest;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.core.Ordered;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.SimpleTransactionStatus;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 学习入口的两段式契约: 事务内只校验与登记, 提交后在新事务里学习, 失败不外抛。 */
class SalesMasterLearningAdapterTest {

    private final UUID actor = UUID.randomUUID();
    private final UUID docId = UUID.randomUUID();
    private final UUID clientId = UUID.randomUUID();
    private final UUID jobId = UUID.randomUUID();
    private final UUID goodsId = UUID.randomUUID();

    private SalesMasterLearningApplier applier;
    private AiJobUsagePort usage;
    private PlatformTransactionManager transactions;
    private final List<TransactionDefinition> openedTransactions = new ArrayList<>();
    private SalesMasterLearningAdapter adapter;

    @BeforeEach
    void setUp() {
        applier = mock(SalesMasterLearningApplier.class);
        usage = mock(AiJobUsagePort.class);
        transactions = mock(PlatformTransactionManager.class);
        when(transactions.getTransaction(any())).thenAnswer(invocation -> {
            openedTransactions.add(invocation.getArgument(0));
            return new SimpleTransactionStatus();
        });
        @SuppressWarnings("unchecked")
        ObjectProvider<AiJobUsagePort> provider = mock(ObjectProvider.class);
        when(provider.getIfAvailable()).thenReturn(usage);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.of(
                new AuthUser(actor, UUID.randomUUID(), "sales-a", Set.of("sales_quote:create"), false, true, false)));
        adapter = new SalesMasterLearningAdapter(applier, provider, currentUser, transactions);
        when(applier.apply(anyString(), any(), any(), any(), any(), anyMap()))
                .thenReturn(SalesMasterLearningApplier.Outcome.none());
        TransactionSynchronizationManager.initSynchronization();
    }

    @AfterEach
    void tearDown() {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.clearSynchronization();
        }
    }

    @Test
    void emptyCurrentDocumentStillReconcilesItsPriorLearningEvidence() {
        when(applier.hasDocumentLearning("quote",docId)).thenReturn(true);
        adapter.learnAfterCommit(new SalesLearningRequest("quote",docId,clientId,actor,null,List.of(),Map.of(),null));
        TransactionSynchronizationManager.getSynchronizations().getFirst().afterCommit();
        var capture=org.mockito.ArgumentCaptor.forClass(SalesLearningPlanner.Plan.class);
        verify(applier).apply(eq("quote"),eq(docId),eq(clientId),eq(actor),capture.capture(),eq(Map.of()));
        assertThat(capture.getValue().aliases()).isEmpty();assertThat(capture.getValue().retainedSources()).isEmpty();
    }

    @Test
    void invalidTickedClientFieldFailsInsideTheSaveTransactionBeforeAnythingIsRegistered() {
        Throwable thrown = catchThrowable(() -> adapter.learnAfterCommit(request(Map.of("email", "broken"))));

        assertThat(thrown).isInstanceOf(ApiException.class);
        assertThat(((ApiException) thrown).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(TransactionSynchronizationManager.getSynchronizations()).isEmpty();
        verify(applier, never()).apply(anyString(), any(), any(), any(), any(), anyMap());
    }

    @Test
    void learningRunsOnlyAfterCommitInNewTransactionsAndPurgesTheJobLast() {
        Map<String, Object> result = Map.of("lines", List.of(Map.of(
                "key", "S1R9", "partNo", "GZ23/D", "status", "MATCHED",
                "selectedGoodsId", goodsId.toString(), "contextNorm", "Z9|白")));
        when(usage.resultFor(jobId, actor)).thenReturn(Optional.of(result));

        adapter.learnAfterCommit(request(Map.of("email", " buyer@sunas.example ")));

        verify(applier, never()).apply(anyString(), any(), any(), any(), any(), anyMap());
        List<TransactionSynchronization> registered = TransactionSynchronizationManager.getSynchronizations();
        assertThat(registered).hasSize(1);
        assertThat(registered.getFirst().getOrder())
                .as("清空识别结果的回调排在最后, 其它读同一结果的回调先跑")
                .isEqualTo(Ordered.LOWEST_PRECEDENCE);

        registered.getFirst().afterCommit();

        var inOrder = org.mockito.Mockito.inOrder(usage, applier);
        inOrder.verify(usage).resultFor(jobId, actor);
        inOrder.verify(applier).apply(eq("quote"), eq(docId), eq(clientId), eq(actor),
                org.mockito.ArgumentMatchers.argThat(plan -> plan.aliases().size() == 2),
                eq(Map.of("email", "buyer@sunas.example")));
        inOrder.verify(usage).markUsed(jobId, actor, "quote", docId);
        assertThat(openedTransactions).hasSize(2)
                .allMatch(definition -> definition.getPropagationBehavior()
                        == TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        assertThat(openedTransactions.getFirst().isReadOnly()).isTrue();
    }

    @Test
    void multipleFilesWithIdenticalRowKeysLearnTogetherWithoutRetractingEarlierFile() {
        UUID secondJob = UUID.randomUUID();
        UUID secondGoods = UUID.randomUUID();
        when(usage.resultFor(jobId, actor)).thenReturn(Optional.of(Map.of("lines", List.of(Map.of(
                "key", "S1R9", "partNo", "MODEL-A", "status", "MATCHED", "selectedGoodsId", goodsId.toString())))));
        when(usage.resultFor(secondJob, actor)).thenReturn(Optional.of(Map.of("lines", List.of(Map.of(
                "key", "S1R9", "partNo", "MODEL-B", "status", "MATCHED", "selectedGoodsId", secondGoods.toString())))));
        adapter.learnAfterCommit(new SalesLearningRequest("quote", docId, clientId, actor, null,
                List.of(new LearnedLine(goodsId, "MODEL-A", null, jobId + ":S1R9", false, false),
                        new LearnedLine(secondGoods, "MODEL-B", null, secondJob + ":S1R9", false, false)),
                Map.of(), secondJob, List.of(jobId)));
        TransactionSynchronizationManager.getSynchronizations().getFirst().afterCommit();
        verify(applier).apply(eq("quote"), eq(docId), eq(clientId), eq(actor),
                org.mockito.ArgumentMatchers.argThat(plan -> plan.aliases().size() == 4 &&
                        plan.aliases().stream().map(SalesLearningPlanner.AliasUpsert::goodsId).distinct().count() == 2), eq(Map.of()));
        verify(usage).markUsed(jobId, actor, "quote", docId);
        verify(usage).markUsed(secondJob, actor, "quote", docId);
    }

    @Test
    void forgedAdditionalSourceKeyDoesNotConsumeUnrelatedOwnedTask() {
        UUID unrelated = UUID.randomUUID();
        when(usage.resultFor(jobId, actor)).thenReturn(Optional.empty());
        when(usage.resultFor(unrelated, actor)).thenReturn(Optional.of(Map.of("lines", List.of(Map.of(
                "key", "S1R9", "partNo", "MODEL-A", "status", "MATCHED", "selectedGoodsId", goodsId.toString())))));
        adapter.learnAfterCommit(new SalesLearningRequest("quote", docId, clientId, actor, null,
                List.of(new LearnedLine(goodsId, "MODEL-A", null, unrelated + ":S1R999", false, false)),
                Map.of(), jobId, List.of(unrelated)));
        TransactionSynchronizationManager.getSynchronizations().getFirst().afterCommit();
        verify(usage, never()).markUsed(unrelated, actor, "quote", docId);
        verify(applier, never()).apply(anyString(), any(), any(), any(), any(), anyMap());
    }

    @Test
    void learningFailureIsSwallowedAndItsTrustedResultRemainsForRetry() {
        when(usage.resultFor(jobId, actor)).thenReturn(Optional.empty());
        doThrow(new IllegalStateException("simulated failure with customer text"))
                .when(applier).apply(anyString(), any(), any(), any(), any(), anyMap());

        adapter.learnAfterCommit(request(Map.of("email", "buyer@sunas.example")));
        TransactionSynchronization sync = TransactionSynchronizationManager.getSynchronizations().getFirst();

        Throwable thrown = catchThrowable(sync::afterCommit);

        assertThat(thrown).isNull();
        verify(usage, never()).markUsed(jobId, actor, "quote", docId);
    }

    @Test
    void actorMismatchSkipsLearningWithoutFailingTheSave() {
        SalesLearningRequest foreign = new SalesLearningRequest("order", docId, clientId, UUID.randomUUID(), null,
                List.of(new LearnedLine(goodsId, "GZ23/D", null, null, true, false)), Map.of(), jobId);

        adapter.learnAfterCommit(foreign);

        assertThat(TransactionSynchronizationManager.getSynchronizations()).isEmpty();
    }

    @Test
    void unknownDocTypeIsAProgrammingError() {
        SalesLearningRequest bad = new SalesLearningRequest("shipment", docId, clientId, actor, null,
                List.of(), Map.of(), null);
        assertThat(catchThrowable(() -> adapter.learnAfterCommit(bad))).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void withoutActiveTransactionLearningRunsImmediately() {
        TransactionSynchronizationManager.clearSynchronization();
        when(usage.resultFor(jobId, actor)).thenReturn(Optional.empty());

        adapter.learnAfterCommit(new SalesLearningRequest("quote", docId, clientId, actor, null,
                List.of(new LearnedLine(goodsId, "K-100", null, null, true, false)), Map.of(), jobId));

        verify(applier).apply(eq("quote"), eq(docId), eq(clientId), eq(actor),
                org.mockito.ArgumentMatchers.argThat(plan -> plan.aliases().size() == 1), eq(Map.of()));
        verify(usage).markUsed(jobId, actor, "quote", docId);
    }

    private SalesLearningRequest request(Map<String, String> clientFields) {
        return new SalesLearningRequest("Quote", docId, clientId, actor, UUID.randomUUID(),
                List.of(new LearnedLine(goodsId, "GZ23/D", null, "S1R9", false, false)), clientFields, jobId);
    }
}
