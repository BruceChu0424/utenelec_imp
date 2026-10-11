package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProductionInspectionStockInPort.QualityReport;
import com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn;
import com.uten.imp.application.port.ProductionInspectionStockInPort.ResolvedReceipt;
import com.uten.imp.common.concurrency.SavepointSnapshots;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

/** Callback-local IQC projection collection; physical stock and source allocation remain immediate. */
final class QualityReportFollowupScope implements QualityReport, TransactionSynchronization {
    private final Thread owner = Thread.currentThread();
    private final QualityReport advance;
    private final Runnable rollbackOnly;
    private final List<ResolvedReceipt> receipts = new ArrayList<>();
    private final List<ReceiptStockIn> partialBatches = new ArrayList<>();
    private final SavepointSnapshots<Checkpoint> savepoints = new SavepointSnapshots<>();
    private volatile boolean open = true;
    private volatile boolean failed;
    private boolean rollbackMarked;

    private QualityReportFollowupScope(QualityReport advance, Runnable rollbackOnly) {
        this.advance = advance;
        this.rollbackOnly = rollbackOnly;
    }

    static void run(QualityReport advance, BiConsumer<List<ResolvedReceipt>, List<ReceiptStockIn>> finish,
                    Runnable rollbackOnly, Consumer<QualityReport> work) {
        Objects.requireNonNull(work, "quality report callback");
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()) {
            throw new IllegalStateException("品质报告收尾必须在调用方事务内执行");
        }
        var scope = new QualityReportFollowupScope(advance, rollbackOnly);
        TransactionSynchronizationManager.registerSynchronization(scope);
        try {
            work.accept(scope);
            scope.open = false;
            scope.requireTransaction();
            if (!scope.receipts.isEmpty() || !scope.partialBatches.isEmpty()) {
                finish.accept(List.copyOf(scope.receipts), List.copyOf(scope.partialBatches));
            }
        } catch (RuntimeException | Error failure) {
            scope.poison();
            throw failure;
        } finally {
            scope.open = false;
        }
    }

    @Override
    public void afterQualityReceiptResolved(String type, UUID receipt, List<ReceiptStockIn> batches) {
        use(() -> {
            advance.afterQualityReceiptResolved(type, receipt, List.copyOf(batches));
            // The whole resolved receipt already covers its automatic stock-in dimensions.
            receipts.add(new ResolvedReceipt(type, receipt));
        });
    }

    @Override
    public void afterInspectionStockInConfirmed(List<ReceiptStockIn> batches) {
        use(() -> {
            List<ReceiptStockIn> frozen = List.copyOf(batches);
            advance.afterInspectionStockInConfirmed(frozen);
            partialBatches.addAll(frozen);
        });
    }

    private void use(Runnable action) {
        try {
            if (!open) throw new IllegalStateException("品质报告收尾回调已结束");
            requireTransaction();
            action.run();
        } catch (RuntimeException | Error failure) {
            if (open) poison();
            throw failure;
        }
    }

    private void poison() {
        failed = true;
        if (Thread.currentThread() == owner && !rollbackMarked) {
            rollbackMarked = true;
            rollbackOnly.run();
        }
    }

    private void requireTransaction() {
        if (failed || Thread.currentThread() != owner
                || !TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()
                || !TransactionSynchronizationManager.getSynchronizations().contains(this)) {
            throw new IllegalStateException("品质报告收尾已失败，或被跨线程、事务、回调复用");
        }
    }

    @Override public void savepoint(Object savepoint) {
        if (open) savepoints.record(savepoint, new Checkpoint(List.copyOf(receipts), List.copyOf(partialBatches)));
    }

    @Override public void savepointRollback(Object savepoint) {
        if (!open) return;
        Checkpoint checkpoint = savepoints.rollback(savepoint);
        receipts.clear();
        partialBatches.clear();
        if (checkpoint != null) {
            receipts.addAll(checkpoint.receipts());
            partialBatches.addAll(checkpoint.batches());
        }
    }

    @Override public void afterCompletion(int status) {
        open = false;
        savepoints.clear();
    }

    private record Checkpoint(List<ResolvedReceipt> receipts, List<ReceiptStockIn> batches) {}
}
