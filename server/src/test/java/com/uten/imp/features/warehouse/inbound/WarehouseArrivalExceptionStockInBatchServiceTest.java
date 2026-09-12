package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInItem;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInResult;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionStockInItemResult;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionStockInReceiptGroup;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.transaction.support.AbstractPlatformTransactionManager;
import org.springframework.transaction.support.DefaultTransactionStatus;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class WarehouseArrivalExceptionStockInBatchServiceTest {

    private static final UUID ACTOR_USER =
            UUID.fromString("00000000-0000-0000-0000-000000000101");
    private static final UUID ACTOR_EMPLOYEE =
            UUID.fromString("00000000-0000-0000-0000-000000000102");
    private static final UUID EXCEPTION_A =
            UUID.fromString("10000000-0000-0000-0000-000000000001");
    private static final UUID EXCEPTION_B =
            UUID.fromString("10000000-0000-0000-0000-000000000002");
    private static final UUID PURCHASE_RECEIPT =
            UUID.fromString("20000000-0000-0000-0000-000000000001");
    private static final UUID SUBCONTRACT_RECEIPT =
            UUID.fromString("30000000-0000-0000-0000-000000000001");

    @Test
    void sameKeySameBodyReplaysCompleteResultAndDifferentBodyConflicts()
            throws Exception {
        Fixture replay = fixture();
        WarehouseArrivalExceptionBatchStockInRequest request =
                request("stock-in-key-1", item(EXCEPTION_A, 3));
        UUID batchId = UUID.randomUUID();
        WarehouseArrivalExceptionBatchStockInResult stored =
                new WarehouseArrivalExceptionBatchStockInResult(
                        batchId,
                        false,
                        true,
                        1,
                        List.of(new WarehouseArrivalExceptionStockInReceiptGroup(
                                "PURCHASE",
                                PURCHASE_RECEIPT,
                                "PR-001",
                                true,
                                List.of(new WarehouseArrivalExceptionStockInItemResult(
                                        EXCEPTION_A, 3, "CLOSED", 4)))));
        when(replay.batches().findExisting(ACTOR_USER, "stock-in-key-1"))
                .thenReturn(new WarehouseArrivalExceptionStockInBatchRepository.ExistingCommand(
                        batchId,
                        WarehouseArrivalExceptionStockInBatchService.requestHash(request),
                        "COMPLETED",
                        replay.mapper().writeValueAsString(stored)));

        WarehouseArrivalExceptionBatchStockInResult result =
                replay.service().stockInBatch(request);

        assertThat(result.replay()).isTrue();
        assertThat(result.batchId()).isEqualTo(batchId);
        assertThat(result.submittedForInspection()).isTrue();
        verifyNoInteractions(
                replay.arrivalControl(),
                replay.purchaseReceipts(),
                replay.subcontractReceipts());
        verify(replay.batches(), never()).insertPending(
                any(), any(), any(), any(), any(), anyInt());

        Fixture conflict = fixture();
        when(conflict.batches().findExisting(ACTOR_USER, "stock-in-key-1"))
                .thenReturn(new WarehouseArrivalExceptionStockInBatchRepository.ExistingCommand(
                        batchId, "different-hash", "COMPLETED", "{}"));

        assertThatThrownBy(() -> conflict.service().stockInBatch(request))
                .isInstanceOfSatisfying(ApiException.class, error ->
                        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        verifyNoInteractions(
                conflict.arrivalControl(),
                conflict.purchaseReceipts(),
                conflict.subcontractReceipts());
    }

    @Test
    void sameReceiptIsApprovedOnceAndPersistedInStableExceptionOrder() {
        Fixture fixture = fixture();
        WarehouseArrivalExceptionBatchStockInRequest request =
                request(
                        "stock-in-key-2",
                        item(EXCEPTION_B, 7),
                        item(EXCEPTION_A, 3));
        when(fixture.batches().lockExceptions(anyList())).thenReturn(List.of(
                locked(EXCEPTION_B, "PURCHASE", PURCHASE_RECEIPT, "PR-001", 7),
                locked(EXCEPTION_A, "PURCHASE", PURCHASE_RECEIPT, "PR-001", 3)));
        answerApproval(fixture, "PURCHASE", PURCHASE_RECEIPT);
        ArrivalExceptionTask resultA = resultTask("CLOSED", 4);
        ArrivalExceptionTask resultB = resultTask("RECEIPT_POSTED", 8);
        when(fixture.arrivalControl().warehouseExceptionDetail(EXCEPTION_A))
                .thenReturn(resultA);
        when(fixture.arrivalControl().warehouseExceptionDetail(EXCEPTION_B))
                .thenReturn(resultB);

        WarehouseArrivalExceptionBatchStockInResult result =
                fixture.service().stockInBatch(request);

        assertThat(result.processedExceptions()).isEqualTo(2);
        assertThat(result.receiptGroups()).hasSize(1);
        assertThat(result.receiptGroups().getFirst().items())
                .extracting(WarehouseArrivalExceptionStockInItemResult::exceptionId)
                .containsExactly(EXCEPTION_A, EXCEPTION_B);
        verify(fixture.purchaseReceipts()).approveFromWarehouseDecision(PURCHASE_RECEIPT);
        verify(fixture.subcontractReceipts(), never())
                .approveFromWarehouseDecision(any());
        verify(fixture.arrivalControl()).stockInWithDecisionSession(
                any(), any());
        org.mockito.InOrder prelock = inOrder(
                fixture.batches(), fixture.arrivalControl());
        prelock.verify(fixture.batches()).lockExceptions(anyList());
        prelock.verify(fixture.arrivalControl()).stockInWithDecisionSession(
                any(), any());

        @SuppressWarnings("unchecked")
        org.mockito.ArgumentCaptor<List<
                WarehouseArrivalExceptionStockInBatchRepository.PersistedItem>> persisted =
                org.mockito.ArgumentCaptor.forClass(List.class);
        verify(fixture.batches()).insertItems(any(), persisted.capture());
        assertThat(persisted.getValue())
                .extracting(
                        WarehouseArrivalExceptionStockInBatchRepository.PersistedItem::exceptionId)
                .containsExactly(EXCEPTION_A, EXCEPTION_B);
        verify(fixture.batches()).complete(any(), org.mockito.ArgumentMatchers.eq(1), any());
    }

    @Test
    void secondReceiptFailureMarksTheOuterTransactionRollbackOnly() {
        Fixture fixture = fixture();
        WarehouseArrivalExceptionBatchStockInRequest request =
                request(
                        "stock-in-key-3",
                        item(EXCEPTION_B, 5),
                        item(EXCEPTION_A, 3));
        when(fixture.batches().lockExceptions(anyList())).thenReturn(List.of(
                locked(
                        EXCEPTION_B,
                        "SUBCONTRACT",
                        SUBCONTRACT_RECEIPT,
                        "SR-001",
                        5),
                locked(EXCEPTION_A, "PURCHASE", PURCHASE_RECEIPT, "PR-001", 3)));
        answerApprovalByException(fixture);
        ArrivalExceptionTask resultA = resultTask("CLOSED", 4);
        when(fixture.arrivalControl().warehouseExceptionDetail(EXCEPTION_A))
                .thenReturn(resultA);
        doThrow(new ApiException(ErrorCode.CONFLICT, "second group failed"))
                .when(fixture.subcontractReceipts()).approveFromWarehouseDecision(SUBCONTRACT_RECEIPT);

        RecordingTransactionManager transactions = new RecordingTransactionManager();
        ProxyFactory proxyFactory = new ProxyFactory(fixture.service());
        proxyFactory.setProxyTargetClass(true);
        proxyFactory.addAdvice(new TransactionInterceptor(
                transactions,
                new AnnotationTransactionAttributeSource()));
        WarehouseArrivalExceptionStockInBatchService transactional =
                (WarehouseArrivalExceptionStockInBatchService) proxyFactory.getProxy();

        assertThatThrownBy(() -> transactional.stockInBatch(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("second group failed");

        org.mockito.InOrder order = inOrder(
                fixture.purchaseReceipts(), fixture.subcontractReceipts());
        order.verify(fixture.purchaseReceipts())
                .approveFromWarehouseDecision(PURCHASE_RECEIPT);
        order.verify(fixture.subcontractReceipts())
                .approveFromWarehouseDecision(SUBCONTRACT_RECEIPT);
        assertThat(transactions.rolledBack).isTrue();
        assertThat(transactions.committed).isFalse();
        verify(fixture.batches(), never()).insertItems(any(), anyList());
        verify(fixture.batches(), never()).complete(any(), anyInt(), any());
    }

    @Test
    void duplicateExceptionIsRejectedBeforeAnyBatchRowLock() {
        Fixture fixture = fixture();
        WarehouseArrivalExceptionBatchStockInRequest request =
                request(
                        "stock-in-key-4",
                        item(EXCEPTION_A, 3),
                        item(EXCEPTION_A, 3));

        assertThatThrownBy(() -> fixture.service().stockInBatch(request))
                .isInstanceOfSatisfying(ApiException.class, error ->
                        assertThat(error.getCode())
                                .isEqualTo(ErrorCode.VALIDATION_FAILED));
        verify(fixture.batches(), never()).lockCommand(any(), any());
        verify(fixture.batches(), never()).lockExceptions(anyList());
    }

    private static Fixture fixture() {
        WarehouseArrivalExceptionStockInBatchRepository batches =
                mock(WarehouseArrivalExceptionStockInBatchRepository.class);
        ProcurementArrivalControlService arrivalControl =
                mock(ProcurementArrivalControlService.class);
        PurchaseReceiptService purchaseReceipts =
                mock(PurchaseReceiptService.class);
        SubcontractReceiptService subcontractReceipts =
                mock(SubcontractReceiptService.class);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
        when(currentUser.requireId()).thenReturn(ACTOR_USER);
        when(currentUser.requireEmployeeId()).thenReturn(ACTOR_EMPLOYEE);
        WarehouseArrivalExceptionStockInBatchService service =
                new WarehouseArrivalExceptionStockInBatchService(
                        batches,
                        arrivalControl,
                        purchaseReceipts,
                        subcontractReceipts,
                        currentUser,
                        tx,
                        mapper,
                        com.uten.imp.support.FulfillmentMutationLockTestSupport.procurementLocks());
        return new Fixture(
                service,
                batches,
                arrivalControl,
                purchaseReceipts,
                subcontractReceipts,
                mapper);
    }

    private static void answerApproval(
            Fixture fixture, String orderType, UUID receiptId) {
        when(fixture.arrivalControl().stockTargets(any())).thenAnswer(invocation -> {
            java.util.Collection<UUID> ids=invocation.getArgument(0);
            return ids.stream().collect(java.util.stream.Collectors.toMap(id -> id,
                    id -> new ProcurementArrivalControlService.StockTarget(orderType,receiptId)));
        });
        when(fixture.arrivalControl().stockInWithDecisionSession(any(), any()))
                .thenAnswer(invocation -> {
                    @SuppressWarnings("unchecked")
                    Consumer<ProcurementArrivalControlService.StockTarget> action =
                            invocation.getArgument(1);
                    action.accept(new ProcurementArrivalControlService.StockTarget(
                            orderType, receiptId));
                    return null;
                });
    }

    private static void answerApprovalByException(Fixture fixture) {
        when(fixture.arrivalControl().stockTargets(any())).thenReturn(java.util.Map.of(
                EXCEPTION_A,new ProcurementArrivalControlService.StockTarget("PURCHASE",PURCHASE_RECEIPT),
                EXCEPTION_B,new ProcurementArrivalControlService.StockTarget("SUBCONTRACT",SUBCONTRACT_RECEIPT)));
        when(fixture.arrivalControl().stockInWithDecisionSession(any(), any()))
                .thenAnswer(invocation -> {
                    UUID exceptionId = invocation.getArgument(0);
                    @SuppressWarnings("unchecked")
                    Consumer<ProcurementArrivalControlService.StockTarget> action =
                            invocation.getArgument(1);
                    if (EXCEPTION_A.equals(exceptionId)) {
                        action.accept(new ProcurementArrivalControlService.StockTarget(
                                "PURCHASE", PURCHASE_RECEIPT));
                    } else {
                        action.accept(new ProcurementArrivalControlService.StockTarget(
                                "SUBCONTRACT", SUBCONTRACT_RECEIPT));
                    }
                    return null;
                });
    }

    private static ArrivalExceptionTask resultTask(String status, long version) {
        ArrivalExceptionTask task = mock(ArrivalExceptionTask.class);
        when(task.status()).thenReturn(status);
        when(task.version()).thenReturn(version);
        return task;
    }

    private static WarehouseArrivalExceptionStockInBatchRepository.LockedException locked(
            UUID exceptionId,
            String orderType,
            UUID receiptId,
            String receiptBillNo,
            long version) {
        return new WarehouseArrivalExceptionStockInBatchRepository.LockedException(
                exceptionId,
                orderType,
                receiptId,
                receiptBillNo,
                BigDecimal.TEN,
                "RECEIPT_ADJUSTED",
                version);
    }

    private static WarehouseArrivalExceptionBatchStockInRequest request(
            String key,
            WarehouseArrivalExceptionBatchStockInItem... items) {
        return new WarehouseArrivalExceptionBatchStockInRequest(
                key, List.of(items));
    }

    private static WarehouseArrivalExceptionBatchStockInItem item(
            UUID id, long version) {
        return new WarehouseArrivalExceptionBatchStockInItem(id, version);
    }

    private record Fixture(
            WarehouseArrivalExceptionStockInBatchService service,
            WarehouseArrivalExceptionStockInBatchRepository batches,
            ProcurementArrivalControlService arrivalControl,
            PurchaseReceiptService purchaseReceipts,
            SubcontractReceiptService subcontractReceipts,
            ObjectMapper mapper) {
    }

    private static final class RecordingTransactionManager
            extends AbstractPlatformTransactionManager {
        private boolean committed;
        private boolean rolledBack;

        @Override
        protected Object doGetTransaction() {
            return new Object();
        }

        @Override
        protected void doBegin(Object transaction, TransactionDefinition definition) {
        }

        @Override
        protected void doCommit(DefaultTransactionStatus status) {
            committed = true;
        }

        @Override
        protected void doRollback(DefaultTransactionStatus status) {
            rolledBack = true;
        }
    }
}
