package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProductionInspectionStockInPort.QualityReport;
import com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn;
import com.uten.imp.application.port.ProductionInspectionStockInPort.ResolvedReceipt;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BiConsumer;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class QualityReportFollowupScopeTest {
    @BeforeEach void begin() {
        TransactionSynchronizationManager.initSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(true);
    }
    @AfterEach void clear() { TransactionSynchronizationManager.clear(); }

    @Test void sourceAdvancementRemainsImmediateAndFinalProjectionRunsOnce() {
        QualityReport advance = mock(QualityReport.class);
        @SuppressWarnings("unchecked") BiConsumer<List<ResolvedReceipt>, List<ReceiptStockIn>> finish = mock(BiConsumer.class);
        Runnable rollback = mock(Runnable.class);
        UUID receipt = UUID.randomUUID();
        var partial = new ReceiptStockIn("SUBCONTRACT", UUID.randomUUID(), UUID.randomUUID(), List.of(UUID.randomUUID()));
        AtomicReference<QualityReport> escaped = new AtomicReference<>();
        QualityReportFollowupScope.run(advance, finish, rollback, report -> {
            escaped.set(report);
            report.afterQualityReceiptResolved("PURCHASE", receipt, List.of());
            verify(advance).afterQualityReceiptResolved("PURCHASE", receipt, List.of());
            verifyNoInteractions(finish);
            report.afterInspectionStockInConfirmed(List.of(partial));
            verify(advance).afterInspectionStockInConfirmed(List.of(partial));
            verifyNoInteractions(finish);
        });
        verify(finish).accept(List.of(new ResolvedReceipt("PURCHASE", receipt)), List.of(partial));
        assertThrows(IllegalStateException.class, () -> escaped.get().afterInspectionStockInConfirmed(List.of(partial)));
        verifyNoInteractions(rollback);
    }

    @Test void swallowedAdvancementFailureStillPoisonsTheOwningTransaction() {
        QualityReport advance = mock(QualityReport.class);
        @SuppressWarnings("unchecked") BiConsumer<List<ResolvedReceipt>, List<ReceiptStockIn>> finish = mock(BiConsumer.class);
        Runnable rollback = mock(Runnable.class);
        UUID receipt = UUID.randomUUID();
        doThrow(new IllegalStateException("source conflict")).when(advance)
                .afterQualityReceiptResolved("PURCHASE", receipt, List.of());
        assertThrows(IllegalStateException.class, () -> QualityReportFollowupScope.run(advance, finish, rollback, report -> {
            assertThrows(IllegalStateException.class, () -> report.afterQualityReceiptResolved("PURCHASE", receipt, List.of()));
        }));
        verify(rollback).run();
        verifyNoInteractions(finish);
    }

    @Test void rolledBackSavepointCannotRefreshAReceiptWhoseAdvancementWasReverted() {
        QualityReport advance = mock(QualityReport.class);
        @SuppressWarnings("unchecked") BiConsumer<List<ResolvedReceipt>, List<ReceiptStockIn>> finish = mock(BiConsumer.class);
        UUID first = UUID.randomUUID(), rolledBack = UUID.randomUUID();
        QualityReportFollowupScope.run(advance, finish, () -> fail("rollback-only"), report -> {
            report.afterQualityReceiptResolved("PURCHASE", first, List.of());
            var synchronization = TransactionSynchronizationManager.getSynchronizations().getFirst();
            Object point = new Object();
            synchronization.savepoint(point);
            report.afterQualityReceiptResolved("SUBCONTRACT", rolledBack, List.of());
            synchronization.savepointRollback(point);
        });
        verify(finish).accept(List.of(new ResolvedReceipt("PURCHASE", first)), List.of());
    }

    @Test void finalProjectionFailureRollsBackAllAlreadyAdvancedReceipts() {
        Runnable rollback = mock(Runnable.class);
        assertThrows(IllegalStateException.class, () -> QualityReportFollowupScope.run(mock(QualityReport.class),
                (receipts, batches) -> { throw new IllegalStateException("refresh conflict"); }, rollback,
                report -> report.afterQualityReceiptResolved("PURCHASE", UUID.randomUUID(), List.of())));
        verify(rollback).run();
    }
}
