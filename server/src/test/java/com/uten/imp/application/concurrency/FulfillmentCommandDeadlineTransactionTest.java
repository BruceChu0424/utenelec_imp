package com.uten.imp.application.concurrency;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionTimedOutException;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.transaction.support.AbstractPlatformTransactionManager;
import org.springframework.transaction.support.DefaultTransactionStatus;
import org.springframework.transaction.support.ResourceHolderSupport;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

/** Real Spring proxy/transaction lifecycle with a deterministic clock and recording resource. */
class FulfillmentCommandDeadlineTransactionTest {
    private final AtomicLong clock = new AtomicLong();
    private final RecordingManager transactions = new RecordingManager(clock);
    private final Target target = new Target(clock);

    @AfterEach
    void contextsAreClean() {
        assertNull(FulfillmentCommandDeadline.current(), "命令结束不能把期限留给线程池下一次请求");
        assertFalse(TransactionSynchronizationManager.isActualTransactionActive());
        assertTrue(TransactionSynchronizationManager.getResourceMap().isEmpty());
    }

    @Test
    void successfulSlowRetryCannotCommitAfterItsRemainingBudget() {
        target.firstAttemptSeconds = 29;
        target.successfulAttemptSeconds = 11;
        Target proxy = proxy();

        RuntimeException failure = assertThrows(RuntimeException.class, proxy::command);

        assertInstanceOf(TransactionTimedOutException.class, failure.getCause());
        assertEquals(List.of(40, 10), transactions.timeouts);
        assertEquals(2, transactions.rollbacks);
        assertEquals(0, transactions.commits, "第二次即使正常返回, 也必须在COMMIT前回滚");
    }

    @Test
    void earlierSuccessfulRetryUsesOnlyTheRetryBudgetAndCommitsOnce() {
        target.firstAttemptSeconds = 4;
        target.successfulAttemptSeconds = 2;

        assertEquals("ok", proxy().command());

        assertEquals(List.of(40, 10), transactions.timeouts);
        assertEquals(1, transactions.rollbacks);
        assertEquals(1, transactions.commits);
    }

    @Test
    void firstAttemptCpuWorkCannotCommitPastTheRootDeadline() {
        target.conflictFirst = false;
        target.successfulAttemptSeconds = 41;

        assertThrows(FulfillmentCommandDeadline.BeforeCommitTimeout.class, () -> proxy().command());

        assertEquals(1, transactions.rollbacks);
        assertEquals(0, transactions.commits);
    }

    @Test
    void connectionAcquisitionUsesTheSameDeadlineAndExpiredWorkRollsBack() {
        transactions.acquireSeconds = 8;
        target.conflictFirst = false;
        target.successfulAttemptSeconds = 33;

        assertThrows(FulfillmentCommandDeadline.BeforeCommitTimeout.class, () -> proxy().command());

        assertTrue(transactions.resourceRemainingMillis.getFirst() <= 32_000);
        assertEquals(1, transactions.rollbacks);
        assertEquals(0, transactions.commits);
    }

    @Test
    void explicitLongTransactionKeepsItsContractAndNextCommandGetsFreshBudget() {
        target.conflictFirst = false;
        target.successfulAttemptSeconds = 70;
        Target proxy = proxy();
        assertEquals("ok", proxy.longCommand());
        target.successfulAttemptSeconds = 1;
        assertEquals("ok", proxy.command());

        assertEquals(List.of(120, 40), transactions.timeouts);
        assertEquals(2, transactions.commits);
    }

    @Test
    void timeSpentAfterCommitNeverChangesACommittedResultIntoAnError() {
        target.conflictFirst = false;
        target.successfulAttemptSeconds = 1;
        target.afterCommitSeconds = 80;
        target.afterCommitAction = () -> assertNull(FulfillmentCommandDeadline.current(),
                "原事务已提交, 提交后的独立事务不能继承过期根期限");

        assertEquals("ok", proxy().command());

        assertEquals(1, transactions.commits);
        assertEquals(0, transactions.rollbacks);
    }

    @Test
    void workInLateBeforeCommitCallbacksIsStillInsideTheRootDeadline() {
        target.conflictFirst = false;
        target.successfulAttemptSeconds = 1;
        target.beforeCommitSeconds = 40;

        assertThrows(FulfillmentCommandDeadline.BeforeCommitTimeout.class, () -> proxy().command());

        assertEquals(1, transactions.rollbacks);
        assertEquals(0, transactions.commits);
    }

    @Test
    void aSourceConflictAfterCommitCannotReplayTheAlreadyCommittedCommand() {
        target.conflictFirst = false;
        target.afterCommitSeconds = 1;
        target.afterCommitAction = () -> { throw new FulfillmentSourceConflictException("提交后来源变化", true); };

        IllegalStateException failure = assertThrows(IllegalStateException.class, () -> proxy().command());

        assertInstanceOf(FulfillmentSourceConflictException.class, failure.getCause());
        assertEquals(1, transactions.commits);
        assertEquals(0, transactions.rollbacks);
        assertEquals(1, target.attempts);
    }

    @Test
    void stricterNestedTransactionTimeoutAndRollbackRulesArePreserved() throws Exception {
        var annotations = new AnnotationTransactionAttributeSource();
        var source = new FulfillmentDeadlineTransactionAttributeSource(annotations);
        var method = Target.class.getMethod("shortIndependent");
        try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(40), clock::get)) {
            var attribute = source.getTransactionAttribute(method, Target.class);
            assertNotNull(attribute);
            assertEquals(3, attribute.getTimeout());
            assertEquals(TransactionDefinition.PROPAGATION_REQUIRES_NEW, attribute.getPropagationBehavior());
            assertFalse(attribute.rollbackOn(new IllegalArgumentException()));
            assertTrue(attribute.rollbackOn(new IllegalStateException()));
        }
        assertEquals(3, source.getTransactionAttribute(method, Target.class).getTimeout());
    }

    @Test
    void backgroundTransactionWithoutCommandScopeIsUntouched() {
        var template = new org.springframework.transaction.support.TransactionTemplate(transactions);
        template.setTimeout(1800);
        template.executeWithoutResult(status -> clock.addAndGet(TimeUnit.MINUTES.toNanos(5)));
        assertEquals(List.of(1800), transactions.timeouts);
        assertEquals(1, transactions.commits);
    }

    private Target proxy() {
        var attributes = new AnnotationTransactionAttributeSource();
        var factory = new ProxyFactory(target);
        factory.addAdvice(new FulfillmentSourceConflictRetryInterceptor(
                millis -> clock.addAndGet(TimeUnit.MILLISECONDS.toNanos(millis)), clock::get,
                Duration.ofSeconds(40), attributes));
        var transaction = new TransactionInterceptor();
        transaction.setTransactionManager(transactions);
        transaction.setTransactionAttributeSource(new FulfillmentDeadlineTransactionAttributeSource(attributes));
        factory.addAdvice(transaction);
        return (Target) factory.getProxy();
    }

    static class Target {
        private final AtomicLong clock;
        boolean conflictFirst = true;
        long firstAttemptSeconds;
        long successfulAttemptSeconds;
        long afterCommitSeconds;
        long beforeCommitSeconds;
        Runnable afterCommitAction;
        int attempts;

        Target(AtomicLong clock) { this.clock = clock; }

        @Transactional
        public String command() {
            if (++attempts == 1 && conflictFirst) {
                clock.addAndGet(TimeUnit.SECONDS.toNanos(firstAttemptSeconds));
                throw new FulfillmentSourceConflictException("来源变化", true);
            }
            clock.addAndGet(TimeUnit.SECONDS.toNanos(successfulAttemptSeconds));
            if (beforeCommitSeconds > 0) {
                TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                    @Override public void beforeCommit(boolean readOnly) {
                        clock.addAndGet(TimeUnit.SECONDS.toNanos(beforeCommitSeconds));
                    }
                });
            }
            if (afterCommitSeconds > 0) {
                TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                    @Override public void afterCommit() {
                        if (afterCommitAction != null) afterCommitAction.run();
                        clock.addAndGet(TimeUnit.SECONDS.toNanos(afterCommitSeconds));
                    }
                });
            }
            return "ok";
        }

        @Transactional(timeout = 120)
        public String longCommand() { return command(); }

        @Transactional(timeout = 3, propagation = Propagation.REQUIRES_NEW,
                noRollbackFor = IllegalArgumentException.class)
        public String shortIndependent() { return "ok"; }
    }

    static final class RecordingManager extends AbstractPlatformTransactionManager {
        final AtomicLong clock;
        final List<Integer> timeouts = new ArrayList<>();
        final List<Long> resourceRemainingMillis = new ArrayList<>();
        long acquireSeconds;
        int commits;
        int rollbacks;

        RecordingManager(AtomicLong clock) {
            this.clock = clock;
            setDefaultTimeout(40);
            setTransactionExecutionListeners(List.of(new FulfillmentCommandDeadlineTransactions()));
        }

        @Override protected Object doGetTransaction() { return new Object(); }

        @Override protected void doBegin(Object transaction, TransactionDefinition definition) {
            int timeout = determineTimeout(definition);
            timeouts.add(timeout);
            clock.addAndGet(TimeUnit.SECONDS.toNanos(acquireSeconds));
            ResourceHolderSupport holder = new ResourceHolderSupport() { };
            holder.setTimeoutInSeconds(timeout);
            TransactionSynchronizationManager.bindResource(this, holder);
        }

        @Override protected void doCommit(DefaultTransactionStatus status) {
            commits++;
        }

        @Override protected void doRollback(DefaultTransactionStatus status) {
            rollbacks++;
        }

        @Override protected void doCleanupAfterCompletion(Object transaction) {
            ResourceHolderSupport holder = (ResourceHolderSupport) TransactionSynchronizationManager.unbindResource(this);
            resourceRemainingMillis.add(holder.getDeadline().getTime() - System.currentTimeMillis());
        }
    }
}
