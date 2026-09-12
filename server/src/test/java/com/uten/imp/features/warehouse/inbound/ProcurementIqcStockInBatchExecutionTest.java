package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.application.port.PreplanInboundAllocationReadPort;
import com.uten.imp.application.port.ProductionInspectionStockInPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.finance.ProcurementReceiptConsiderationService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.warehouse.WarehouseScopeService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Exercises the command ordering and replay behavior; PostgreSQL full-chain tests own ledger guards. */
class ProcurementIqcStockInBatchExecutionTest {
    private static final UUID WAREHOUSE = UUID.randomUUID();
    private static final UUID GOODS = UUID.randomUUID();

    @Test
    void validatesAllReceiptsBeforeWritingAndAdvancesProductionOnceAfterEveryPosting() {
        Fixture f = new Fixture();
        BatchConfirmEntry first = f.entry(1, "first-stock-in", "2");
        BatchConfirmEntry second = f.entry(2, "second-stock-in", "3");
        doAnswer(call -> {
            assertThat(f.movements).hasSize(2);
            assertThat(f.readSlices).containsExactly(first.receiptId(), second.receiptId());
            List<ProductionInspectionStockInPort.ReceiptStockIn> batches = call.getArgument(0);
            assertThat(batches).extracting(ProductionInspectionStockInPort.ReceiptStockIn::receiptId)
                    .containsExactly(first.receiptId(), second.receiptId());
            f.productionAdvanced = true;
            return null;
        }).when(f.production).afterInspectionStockInConfirmed(anyList());

        BatchConfirmResult result = f.service.batchConfirm(new BatchConfirmRequest(List.of(second, first)));

        assertThat(result.confirmedReceipts()).isEqualTo(2);
        assertThat(result.confirmedItemCount()).isEqualTo(2);
        assertThat(f.movements).extracting(StockService.MovementRequest::qty)
                .containsExactly(new BigDecimal("2.0000"), new BigDecimal("3.0000"));
        verify(f.locks, times(1)).stockIn(any());
        verify(f.guard, times(1)).verifyUnchanged();
        verify(f.warehouses, times(1)).requireActiveLeafWarehouse(WAREHOUSE, "入库仓库");
        verify(f.production, times(1)).afterInspectionStockInConfirmed(anyList());
        verify(f.allocations, times(1)).actualForBatches(anyList());
    }

    @Test
    void staleSecondReceiptRejectsTheEntireCommandBeforeAnyStockOrCostWrite() {
        Fixture f = new Fixture();
        BatchConfirmEntry first = f.entry(1, "first-stock-in", "2");
        BatchConfirmEntry second = f.entry(2, "second-stock-in", "3");
        f.slices.get(second.receiptId())[17] = new BigDecimal("2");

        assertThatThrownBy(() -> f.service.batchConfirm(new BatchConfirmRequest(List.of(first, second))))
                .isInstanceOf(ApiException.class).hasMessageContaining("余量已变化");

        assertThat(f.writeSql).isEmpty();
        verifyNoInteractions(f.stock, f.consideration, f.production, f.peg);
    }

    @Test
    void normalizedDuplicateKeysAreRejectedBeforeLockDiscovery() {
        Fixture f = new Fixture();
        BatchConfirmEntry first = f.entry(1, "same-stock-in", "2");
        BatchConfirmEntry second = f.entry(2, " same-stock-in ", "3");
        assertThatThrownBy(() -> f.service.batchConfirm(new BatchConfirmRequest(List.of(first, second))))
                .isInstanceOf(ApiException.class).hasMessageContaining("重复幂等键");
        verifyNoInteractions(f.locks, f.stock, f.production);
    }

    @Test
    void replayDoesNotReadPendingSlicesOrPostStockOrRepeatProduction() {
        Fixture f = new Fixture();
        BatchConfirmEntry entry = f.entry(1, "replayed-stock-in", "2");
        Object normalized = ReflectionTestUtils.invokeMethod(f.service, "normalize", "PURCHASE", entry.receiptId(),
                new ConfirmRequest(entry.idempotencyKey(), entry.items()));
        String hash = ReflectionTestUtils.invokeMethod(normalized, "requestHash");
        UUID batchId = UUID.randomUUID();
        f.existing.put(entry.idempotencyKey(), new Object[]{batchId, hash, 1, OffsetDateTime.now()});
        f.productionAdvanced = true; // The prior committed transaction already completed its follow-up.

        ConfirmResult result = f.service.confirm("PURCHASE", entry.receiptId(),
                new ConfirmRequest(entry.idempotencyKey(), entry.items()));

        assertThat(result.replayed()).isTrue();
        assertThat(result.batchId()).isEqualTo(batchId);
        assertThat(f.readSlices).isEmpty();
        assertThat(f.writeSql).isEmpty();
        verifyNoInteractions(f.stock, f.consideration, f.production, f.peg, f.warehouses);
    }

    private static class Fixture {
        final EntityManager em = mock(EntityManager.class);
        final StockService stock = mock(StockService.class);
        final PreplanAnalysisPegPort peg = mock(PreplanAnalysisPegPort.class);
        final ProductionInspectionStockInPort production = mock(ProductionInspectionStockInPort.class);
        final ProcurementMutationLocks locks = mock(ProcurementMutationLocks.class);
        final FulfillmentMutationLocks.Guard guard = mock(FulfillmentMutationLocks.Guard.class);
        final ProcurementReceiptConsiderationService consideration = mock(ProcurementReceiptConsiderationService.class);
        final WarehouseScopeService warehouses = mock(WarehouseScopeService.class);
        final PreplanInboundAllocationReadPort allocations = mock(PreplanInboundAllocationReadPort.class);
        final Map<UUID, Object[]> slices = new HashMap<>();
        final Map<String, Object[]> existing = new HashMap<>();
        final List<UUID> readSlices = new ArrayList<>();
        final List<String> writeSql = new ArrayList<>();
        final List<StockService.MovementRequest> movements = new ArrayList<>();
        final ProcurementIqcStockInService service;
        boolean productionAdvanced;

        Fixture() {
            SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
            when(user.requireId()).thenReturn(UUID.randomUUID());
            when(user.requireEmployeeId()).thenReturn(UUID.randomUUID());
            service = new ProcurementIqcStockInService(em, stock, user, mock(TxSessionVars.class),
                    mock(ProductionSupplyTransitionPort.class), mock(ProductionSubcontractSupplyTransitionPort.class),
                    production, peg, mock(ChainNoticeService.class), locks, consideration);
            service.setInboundAllocationRead(allocations);
            ReflectionTestUtils.setField(service, "warehouseScopes", warehouses);
            when(locks.stockIn(any())).thenReturn(guard);
            when(em.createNativeQuery(anyString())).thenAnswer(call -> query(call.getArgument(0)));
            when(allocations.actualForBatches(any())).thenAnswer(call -> {
                assertThat(productionAdvanced).as("actual result must include final production state").isTrue();
                return List.of();
            });
            when(allocations.actualForBatch(any())).thenAnswer(call -> {
                assertThat(productionAdvanced).isTrue();
                return List.of();
            });
            doAnswer(call -> { movements.add(call.getArgument(1)); return null; })
                    .when(stock).recordMovementWithId(any(), any());
        }

        BatchConfirmEntry entry(int id, String key, String qty) {
            UUID receipt = new UUID(0, id);
            UUID event = UUID.randomUUID();
            UUID unit = UUID.randomUUID();
            BigDecimal quantity = new BigDecimal(qty);
            slices.put(receipt, new Object[]{event, UUID.randomUUID(), WAREHOUSE, GOODS, null, unit,
                    BigDecimal.ONE, quantity, new BigDecimal("10"), null, null, quantity, BigDecimal.ZERO,
                    quantity, new BigDecimal("10"), null, BigDecimal.ZERO, quantity, "合格",
                    OffsetDateTime.now(), "G001", "货品", null, "件", null, "A1", "检验员", "PO001", unit,
                    UUID.randomUUID()});
            return new BatchConfirmEntry("PURCHASE", receipt, key,
                    List.of(new ConfirmItem(event, quantity, quantity, "A1")));
        }

        Query query(String sql) {
            Query query = mock(Query.class);
            Map<String, Object> params = new HashMap<>();
            when(query.setParameter(anyString(), any())).thenAnswer(call -> {
                params.put(call.getArgument(0), call.getArgument(1)); return query;
            });
            when(query.getResultList()).thenAnswer(call -> {
                if (sql.contains("SELECT id, request_hash, confirmed_count")) {
                    Object[] row = existing.get(params.get("key"));
                    return row == null ? List.of() : java.util.Collections.singletonList(row);
                }
                if (sql.contains("SELECT event.id,")) {
                    UUID receipt = (UUID) params.get("receiptId");
                    readSlices.add(receipt);
                    return java.util.Collections.singletonList(slices.get(receipt));
                }
                if (sql.contains("SELECT receipt.bill_no, receipt.bill_date")) {
                    return java.util.Collections.singletonList(new Object[]{"PR001", LocalDate.now(),
                            UUID.randomUUID(), "供应商", WAREHOUSE, "仓库"});
                }
                return List.of();
            });
            when(query.executeUpdate()).thenAnswer(call -> { writeSql.add(sql); return 1; });
            return query;
        }
    }
}
