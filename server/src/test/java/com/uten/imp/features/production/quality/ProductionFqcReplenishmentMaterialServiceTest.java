package com.uten.imp.features.production.quality;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService;
import com.uten.imp.features.production.mrp.CompleteKitAllocator;
import com.uten.imp.features.production.mrp.ProductionExecutionPlanningService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Collections;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionFqcReplenishmentMaterialServiceTest {

    @Test
    void blockedRetryReplaysSameKeyAllocatesOnlyRemainderAndCreatesOneDraw() {
        UUID authorizationId = UUID.randomUUID();
        UUID otherAuthorizationId = UUID.randomUUID();
        UUID taskId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID productGoodsId = UUID.randomUUID();
        UUID materialGoodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        UUID actorId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UUID cycleId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        UUID drawId = UUID.randomUUID();

        EntityManager em = mock(EntityManager.class);
        ProductionExecutionPlanningService planning =
                mock(ProductionExecutionPlanningService.class);
        ProductionMaterialAllocationFacade allocation =
                mock(ProductionMaterialAllocationFacade.class);
        ProductionFulfillmentLedgerService ledger =
                mock(ProductionFulfillmentLedgerService.class);
        StockDocumentRepository documents = mock(StockDocumentRepository.class);
        StockDocumentItemRepository items = mock(StockDocumentItemRepository.class);
        DocNumberService numbers = mock(DocNumberService.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
        ChainNoticeService notice = mock(ChainNoticeService.class);

        when(currentUser.requireId()).thenReturn(actorId);
        when(currentUser.requireEmployeeId()).thenReturn(employeeId);
        when(numbers.nextNumber(any())).thenReturn("PD26080001");
        doAnswer(invocation -> {
            StockDocument document = invocation.getArgument(0);
            document.setId(drawId);
            return document;
        }).when(documents).saveAndFlush(any(StockDocument.class));
        doAnswer(invocation -> {
            StockDocumentItem item = invocation.getArgument(0);
            item.setId(UUID.randomUUID());
            return item;
        }).when(items).saveAndFlush(any(StockDocumentItem.class));

        var usage = new CompleteKitAllocator.MaterialUsage(
                materialGoodsId, null, unitId, BigDecimal.ONE, "BUY",
                List.of(new CompleteKitAllocator.ConsumptionRule(
                        "PER_UNIT", BigDecimal.ONE, BigDecimal.ONE, true)));
        var productLine = new CompleteKitAllocator.ProductLine(
                planItemId, 1, productGoodsId, null, unitId, BigDecimal.ONE,
                new BigDecimal("10"), null, null, null, null, null,
                "P001", "Product", new CompleteKitAllocator.Priority(
                null, 1, planItemId), List.of(usage), "a".repeat(64));
        when(planning.lockedSnapshot(planId, warehouseId, Map.of()))
                .thenReturn(new ProductionExecutionPlanningService.Snapshot(
                        planId, warehouseId, "b".repeat(64),
                        List.of(productLine),
                        Map.of(new CompleteKitAllocator.MaterialKey(
                                materialGoodsId, null), new BigDecimal("4")),
                        List.of()));

        AtomicInteger replayCalls = new AtomicInteger();
        AtomicInteger activeCycleCalls = new AtomicInteger();
        AtomicInteger demandCalls = new AtomicInteger();
        AtomicInteger detailCalls = new AtomicInteger();
        String firstHash = CanonicalFingerprint.sha256(List.of(
                "FQC-REPLENISHMENT-MATERIAL-CONFIRM-V1",
                authorizationId.toString()));

        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("SELECT id FROM production_execution_segments")) {
                return query(List.of(segmentId), segmentId, 1);
            }
            if (sql.contains("SELECT task.id, recovery_auth.id")
                    && !sql.contains("CASE")) {
                return query(Collections.singletonList(lockedRow(
                        taskId, authorizationId, segmentId, packageId,
                        planId, planItemId, warehouseId, productGoodsId,
                        unitId, makerId)), null, 1);
            }
            if (sql.contains("COUNT(*)")
                    && sql.contains("replenishment_analysis_links")) {
                return query(List.of(), 1L, 1);
            }
            if (sql.contains("FROM production_fqc_replenishment_attempts attempt")
                    && sql.contains("idempotency_key")) {
                int call = replayCalls.getAndIncrement();
                return query(call == 1 || call == 3
                                ? Collections.singletonList(new Object[]{firstHash}) : List.of(),
                        null, 1);
            }
            if (sql.contains("MAX(generation)")) {
                return query(List.of(), 1, 1);
            }
            if (sql.contains("SELECT demand.id, demand.goods_id")) {
                int call = demandCalls.getAndIncrement();
                BigDecimal committed = switch (call) {
                    case 0 -> BigDecimal.ZERO;
                    case 1, 2 -> new BigDecimal("4");
                    default -> new BigDecimal("10");
                };
                return query(Collections.singletonList(demandRow(
                        demandId, materialGoodsId, unitId, committed)), null, 1);
            }
            if (sql.contains("SELECT goods.id, goods.code, goods.name")) {
                return query(Collections.singletonList(new Object[]{
                        materialGoodsId, "M001", "Material"}), null, 1);
            }
            if (sql.contains("CASE") && sql.contains("task_status")) {
                String status = detailCalls.getAndIncrement() < 2
                        ? "BLOCKED" : "AWAITING_WAREHOUSE";
                return query(Collections.singletonList(taskRow(
                        taskId, authorizationId, segmentId, planId,
                        planItemId, warehouseId, makerId, cycleId,
                        status, status.equals("BLOCKED")
                                ? "外购物料库存不足" : null,
                        status.equals("AWAITING_WAREHOUSE") ? drawId : null)),
                        null, 1);
            }
            return query(List.of(), null, 1);
        });
        when(em.createNativeQuery(anyString(), eq(UUID.class)))
                .thenAnswer(invocation -> {
                    String sql = invocation.getArgument(0);
                    if (sql.contains("recovery_auth.execution_segment_id")) {
                        return query(List.of(segmentId), null, 1);
                    }
                    if (sql.contains("FROM production_fqc_replenishment_cycles")) {
                        return query(activeCycleCalls.getAndIncrement() == 0
                                ? List.of() : List.of(cycleId), null, 1);
                    }
                    if (sql.contains("replenishment_draw_links")) {
                        return query(List.of(), null, 1);
                    }
                    return query(List.of(), null, 1);
                });
        when(allocation.allocate(any())).thenReturn(List.of());

        var service = new ProductionFqcReplenishmentMaterialService(
                em, planning, allocation, ledger, documents, items, numbers,
                currentUser, tx, access, notice);

        var first = service.confirm(authorizationId,
                new ProductionFqcReplenishmentMaterialService.ConfirmRequest(
                        "material-attempt-0001"));
        assertThat(first.status()).isEqualTo("BLOCKED");

        var replay = service.confirm(authorizationId,
                new ProductionFqcReplenishmentMaterialService.ConfirmRequest(
                        "material-attempt-0001"));
        assertThat(replay.status()).isEqualTo("BLOCKED");

        var retry = service.confirm(authorizationId,
                new ProductionFqcReplenishmentMaterialService.ConfirmRequest(
                        "material-attempt-0002"));
        assertThat(retry.status()).isEqualTo("AWAITING_WAREHOUSE");

        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<ProductionMaterialAllocationFacade.AllocationRequest>>
                requests = ArgumentCaptor.forClass(List.class);
        verify(allocation, times(2)).allocate(requests.capture());
        assertThat(requests.getAllValues().get(0).getFirst().requiredQty())
                .isEqualByComparingTo("10");
        assertThat(requests.getAllValues().get(1).getFirst().requiredQty())
                .isEqualByComparingTo("6");
        verify(documents, times(1)).saveAndFlush(any(StockDocument.class));

        assertThatThrownBy(() -> service.confirm(
                otherAuthorizationId,
                new ProductionFqcReplenishmentMaterialService.ConfirmRequest(
                        "material-attempt-0001")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("相同幂等键");
    }

    private static Query query(List<?> rows, Object single, int updated) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        when(query.getSingleResult()).thenReturn(single);
        when(query.executeUpdate()).thenReturn(updated);
        return query;
    }

    private static Object[] lockedRow(
            UUID taskId, UUID authorizationId, UUID segmentId,
            UUID packageId, UUID planId, UUID planItemId, UUID warehouseId,
            UUID productGoodsId, UUID unitId, UUID makerId) {
        return new Object[]{
                taskId, authorizationId, "SCRAP", new BigDecimal("10"),
                warehouseId, productGoodsId, null, unitId, BigDecimal.ONE,
                planItemId, segmentId, packageId, planId, null, null,
                makerId, "PLAN-001", "REPORT-001"};
    }

    private static Object[] demandRow(
            UUID demandId, UUID goodsId, UUID unitId,
            BigDecimal committed) {
        return new Object[]{
                demandId, goodsId, null, unitId,
                new BigDecimal("10"), "BUY", committed};
    }

    private static Object[] taskRow(
            UUID taskId, UUID authorizationId, UUID segmentId, UUID planId,
            UUID planItemId, UUID warehouseId, UUID makerId, UUID cycleId,
            String status, String blockedReason, UUID drawId) {
        return new Object[]{
                taskId, authorizationId, "SCRAP", new BigDecimal("10"),
                warehouseId, planItemId, segmentId, planId, "PLAN-001",
                makerId, "REPORT-001", UUID.randomUUID(), cycleId,
                drawId, drawId == null ? null : "PD26080001",
                drawId == null ? null : (short) 0,
                drawId == null ? null : (short) 0,
                status, blockedReason};
    }
}
