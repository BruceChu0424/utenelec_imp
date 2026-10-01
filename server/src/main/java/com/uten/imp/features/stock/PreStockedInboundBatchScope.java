package com.uten.imp.features.stock;

import com.uten.imp.application.port.ProductionPreStockedInboundPort;
import com.uten.imp.common.concurrency.SavepointSnapshots;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

/** A batch handle proves thread, physical transaction and callback ownership on every use. */
final class PreStockedInboundBatchScope implements ProductionPreStockedInboundPort.Batch, TransactionSynchronization {
    private final Thread owner = Thread.currentThread();
    private final List<UUID> posted;
    private final Set<UUID> validatedWarehouses;
    private final BiConsumer<UUID, String> confirm;
    private final Runnable rollbackOnly;
    private final SavepointSnapshots<Checkpoint> savepoints = new SavepointSnapshots<>();
    private volatile boolean open = true;
    private volatile boolean failed;
    private boolean rollbackMarked;

    private PreStockedInboundBatchScope(List<UUID> posted, Set<UUID> validatedWarehouses,
            BiConsumer<UUID, String> confirm, Runnable rollbackOnly) {
        this.posted = posted;
        this.validatedWarehouses = validatedWarehouses;
        this.confirm = confirm;
        this.rollbackOnly = rollbackOnly;
    }

    static void run(List<UUID> posted, Set<UUID> validatedWarehouses,
            BiConsumer<UUID, String> confirm, Consumer<List<UUID>> finish,
            Runnable rollbackOnly,
            Consumer<ProductionPreStockedInboundPort.Batch> work) {
        Objects.requireNonNull(work, "batch callback");
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()) {
            throw new IllegalStateException("先入库品质批次必须在调用方事务内执行");
        }
        var scope = new PreStockedInboundBatchScope(posted, validatedWarehouses, confirm, rollbackOnly);
        TransactionSynchronizationManager.registerSynchronization(scope);
        try {
            work.accept(scope);
            scope.open = false;
            scope.requireTransaction();
            if (!posted.isEmpty()) finish.accept(List.copyOf(posted));
        } catch (RuntimeException | Error failure) {
            scope.poison();
            throw failure;
        } finally {
            scope.open = false;
        }
    }

    @Override
    public void confirm(UUID documentId, String idempotencyKey) {
        try {
            requireOwned();
            confirm.accept(documentId, idempotencyKey);
        } catch (RuntimeException | Error failure) {
            // An expired handle cannot change an already completed command.
            if (open) poison();
            throw failure;
        }
    }

    private void poison() {
        failed = true;
        // A foreign thread may flag misuse, but only the owner touches Spring's
        // thread-bound status. The owner rechecks this flag before finishing.
        if (Thread.currentThread() == owner && !rollbackMarked) {
            rollbackMarked = true;
            rollbackOnly.run();
        }
    }

    private void requireOwned() {
        if (!open) throw new IllegalStateException("先入库品质批次回调已结束");
        requireTransaction();
    }

    private void requireTransaction() {
        if (failed || Thread.currentThread() != owner
                || !TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()
                || !TransactionSynchronizationManager.getSynchronizations().contains(this)) {
            throw new IllegalStateException("先入库品质批次已失败，或被跨线程、事务、回调复用");
        }
    }

    @Override
    public void savepoint(Object savepoint) {
        if (open) savepoints.record(savepoint, new Checkpoint(List.copyOf(posted), Set.copyOf(validatedWarehouses)));
    }

    @Override
    public void savepointRollback(Object savepoint) {
        if (!open) return;
        // Restore successful cached work, but never clear a failed confirmation:
        // that failure has already marked the owning batch transaction rollback-only.
        Checkpoint retained = savepoints.rollback(savepoint);
        posted.clear();
        validatedWarehouses.clear();
        if (retained != null) {
            posted.addAll(retained.posted());
            validatedWarehouses.addAll(retained.warehouses());
        }
    }

    @Override
    public void afterCompletion(int status) {
        open = false;
        savepoints.clear();
    }

    private record Checkpoint(List<UUID> posted, Set<UUID> warehouses) { }
}
