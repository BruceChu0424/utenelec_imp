package com.uten.imp.application.concurrency;

import org.springframework.core.Ordered;
import org.springframework.lang.Nullable;
import org.springframework.transaction.TransactionExecution;
import org.springframework.transaction.TransactionExecutionListener;
import org.springframework.transaction.TransactionTimedOutException;
import org.springframework.transaction.support.ResourceHolderSupport;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;

/** Applies the same command deadline after connection acquisition and before commit. */
public final class FulfillmentCommandDeadlineTransactions implements TransactionExecutionListener {
    @Override
    public void afterBegin(TransactionExecution transaction, @Nullable Throwable beginFailure) {
        FulfillmentCommandDeadline deadline = FulfillmentCommandDeadline.current();
        if (beginFailure != null || deadline == null || !transaction.isNewTransaction()
                || !TransactionSynchronizationManager.isSynchronizationActive()) return;

        // beginTransaction may have spent time waiting for a pooled connection.
        // No exception may escape afterBegin: Spring has already bound resources.
        Set<ResourceHolderSupport> holders = Collections.newSetFromMap(new IdentityHashMap<>());
        for (Object resource : TransactionSynchronizationManager.getResourceMap().values()) {
            if (!(resource instanceof ResourceHolderSupport holder) || !holders.add(holder)) continue;
            long remaining = deadline.remainingMillis();
            if (holder.hasTimeout()) {
                remaining = Math.min(remaining, holder.getDeadline().getTime() - System.currentTimeMillis());
            }
            holder.setTimeoutInMillis(Math.max(1, remaining));
        }
        if (deadline.claimRootTransaction()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override public int getOrder() { return Ordered.HIGHEST_PRECEDENCE; }
                @Override public void afterCommit() { deadline.rootCommitted(); }
                @Override public void afterCompletion(int status) { deadline.rootTransactionCompleted(); }
            });
        }
    }

    @Override
    public void beforeCommit(TransactionExecution transaction) {
        FulfillmentCommandDeadline deadline = FulfillmentCommandDeadline.current();
        if (deadline == null || !transaction.isNewTransaction()) return;
        // Execution listeners run after all synchronization beforeCommit and
        // beforeCompletion callbacks, directly before the physical COMMIT.
        deadline.checkBeforeCommit();
        for (Object resource : TransactionSynchronizationManager.getResourceMap().values()) {
            if (resource instanceof ResourceHolderSupport holder) remainingMillis(deadline, holder);
        }
        deadline.checkBeforeCommit();
    }

    private static long remainingMillis(FulfillmentCommandDeadline deadline, ResourceHolderSupport holder) {
        long remaining = deadline.remainingMillis();
        if (holder.hasTimeout()) {
            remaining = Math.min(remaining, holder.getDeadline().getTime() - System.currentTimeMillis());
        }
        if (remaining <= 0) {
            throw new FulfillmentCommandDeadline.BeforeCommitTimeout(
                    new TransactionTimedOutException("履约命令或本次事务处理时限已用完"));
        }
        return remaining;
    }
}
