package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * V463（ADR-069）同货品合并行的来源 FIFO 拆分口径：
 * <ul>
 *   <li>按各申请行剩余量「需求日期升序、id 升序」先到先得；</li>
 *   <li>末位来源吸收超额（超采）：60 = 30 + 30（第二来源只剩 20 仍吃 30）；</li>
 *   <li>改小总量时份额为 0 的来源被丢弃：10 只落首来源；</li>
 *   <li>单来源行 alloc = 行数量（与历史单锚一致）。</li>
 * </ul>
 */
class PurchaseOrderSourceMergeSplitTest {

    private record Wiring(
            PurchaseOrderService service,
            PurchaseOrderItemRepository itemRepo,
            Query sourceInsert,
            Map<String, List<Object>> captured,
            UUID sourceA,
            UUID sourceB,
            UUID goodsId,
            UUID unitId) {}

    private static Wiring wire(BigDecimal sourceARemaining,
                               BigDecimal sourceBRemaining) {
        PurchaseOrderRepository orderRepo = mock(PurchaseOrderRepository.class);
        PurchaseOrderItemRepository itemRepo =
                mock(PurchaseOrderItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        PurchaseLineUnitPolicy unitPolicy = mock(PurchaseLineUnitPolicy.class);

        UUID sourceA = UUID.randomUUID();
        UUID sourceB = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        Query settlementQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM settlement_methods method"))))
                .thenReturn(settlementQuery);
        when(settlementQuery.setParameter(anyString(), any()))
                .thenReturn(settlementQuery);
        when(settlementQuery.setMaxResults(ArgumentMatchers.anyInt()))
                .thenReturn(settlementQuery);
        when(settlementQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{UUID.randomUUID(), 1, "CASH", "现金", null}));

        // 剩余量查询（3 列：id / remaining / need_date）：A 日期更早排前。
        Query remainingQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("remaining_qty")
                        && sql.contains("FROM purchase_request_items"))))
                .thenReturn(remainingQuery);
        when(remainingQuery.setParameter(anyString(), any()))
                .thenReturn(remainingQuery);
        when(remainingQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{sourceA, sourceARemaining, LocalDate.of(2026, 9, 1)},
                new Object[]{sourceB, sourceBRemaining, LocalDate.of(2026, 9, 5)}));

        // 申请快照（4 列）与主档快照。
        Query requestQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM purchase_request_items")
                        && !sql.contains("source_doc_no")
                        && !sql.contains("remaining_qty")
                        && !sql.contains("SELECT DISTINCT pr.id"))))
                .thenReturn(requestQuery);
        when(requestQuery.setParameter(anyString(), any())).thenReturn(requestQuery);
        when(requestQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{sourceA, goodsId, "G-OLD", "历史货品"}));
        Query sourceRequestQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("SELECT DISTINCT pr.id"))))
                .thenReturn(sourceRequestQuery);
        when(sourceRequestQuery.setParameter(anyString(), any()))
                .thenReturn(sourceRequestQuery);
        when(sourceRequestQuery.getResultList()).thenReturn(List.of());
        Query lineageQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("source_doc_no"))))
                .thenReturn(lineageQuery);
        when(lineageQuery.setParameter(anyString(), any())).thenReturn(lineageQuery);
        when(lineageQuery.getResultList()).thenReturn(List.of());
        Query masterQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM goods"))))
                .thenReturn(masterQuery);
        when(masterQuery.setParameter(anyString(), any())).thenReturn(masterQuery);
        when(masterQuery.getResultList()).thenReturn(List.<Object[]>of(new Object[]{goodsId,goodsId,"G-MASTER","主档货品"}));

        // sources INSERT：捕获逐参数写入顺序。
        Query sourceInsert = mock(Query.class);
        Map<String, List<Object>> captured = new LinkedHashMap<>();
        when(sourceInsert.setParameter(anyString(), any())).thenAnswer(invocation -> {
            captured.computeIfAbsent(
                    invocation.getArgument(0, String.class),
                    ignored -> new ArrayList<>())
                    .add(invocation.getArgument(1));
            return sourceInsert;
        });
        when(sourceInsert.executeUpdate()).thenReturn(1);
        when(em.createNativeQuery(argThat(sql ->
                sql != null
                        && sql.contains("INSERT INTO purchase_order_item_sources"))))
                .thenReturn(sourceInsert);

        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(unitPolicy.normalizeAndValidate(
                any(), any(), ArgumentMatchers.<BigDecimal>any(),
                ArgumentMatchers.anyInt()))
                .thenAnswer(invocation -> new PurchaseLineUnitPolicy.ResolvedUnit(
                        invocation.getArgument(1),
                        invocation.getArgument(2)));

        PurchaseOrderService service = new PurchaseOrderService(
                orderRepo,
                itemRepo,
                mock(LinkedDocumentIntegrityService.class),
                mock(ProductionSupplyTransitionPort.class),
                mock(TxSessionVars.class),
                currentUser,
                mock(EmployeeNameResolver.class),
                em,
                mock(DocNumberService.class),
                mock(ProductionSupplySourceGuard.class),
                unitPolicy,
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery.class),
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService.class),
                // 2026-09-05 cancel() 撤回财务弹卡用；本测试不触达，传 mock 即可。
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy.class),
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementReviewCancellationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS),
                        org.mockito.Mockito.mock(com.uten.imp.features.purchase.common.ProcurementMasterDefaultsSyncService.class));
        return new Wiring(
                service, itemRepo, sourceInsert, captured, sourceA, sourceB,
                goodsId, unitId);
    }

    private static OrderSaveRequest request(
            Wiring wiring, BigDecimal qty, UUID... requestItemIds) {
        OrderItemLine line = new OrderItemLine();
        line.setLineNo(1);
        line.setGoodsId(wiring.goodsId());
        line.setUnitId(wiring.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(qty);
        line.setPrice(BigDecimal.ONE);
        line.setSupplierId(UUID.randomUUID());
        line.setSettlementMethodId(UUID.randomUUID());
        line.setCurrencyId(UUID.randomUUID());
        line.setExchangeRate(BigDecimal.ONE);
        line.setTaxRate(BigDecimal.ZERO);
        line.setRequestItemId(requestItemIds[0]);
        if (requestItemIds.length > 1) {
            line.setRequestItemIds(List.of(requestItemIds));
        }
        OrderSaveRequest req = new OrderSaveRequest();
        req.setBillDate(LocalDate.of(2026, 9, 3));
        req.setSettlementMethodId(line.getSettlementMethodId());
        req.setSupplierId(line.getSupplierId());
        req.setCurrencyId(line.getCurrencyId());
        req.setExchangeRate(line.getExchangeRate());
        req.setTaxRate(line.getTaxRate());
        req.setItems(List.of(line));
        return req;
    }

    @Test
    void mergedLineSplitsFifoAcrossSourceRemainings() {
        Wiring wiring = wire(new BigDecimal("30"), new BigDecimal("20"));
        wiring.service.create(request(
                wiring, new BigDecimal("50"), wiring.sourceA(), wiring.sourceB()));
        assertSourceAllocations(wiring, new BigDecimal("50"),
                List.of(wiring.sourceA(), wiring.sourceB()),
                List.of(new BigDecimal("30"), new BigDecimal("20")));
    }

    @Test
    void overageIsAbsorbedByTheLastSource() {
        Wiring wiring = wire(new BigDecimal("30"), new BigDecimal("20"));
        wiring.service.create(request(
                wiring, new BigDecimal("60"), wiring.sourceA(), wiring.sourceB()));
        assertSourceAllocations(wiring, new BigDecimal("60"),
                List.of(wiring.sourceA(), wiring.sourceB()),
                List.of(new BigDecimal("30"), new BigDecimal("30")));
    }

    @Test
    void zeroShareSourcesAreDroppedWhenTotalShrinks() {
        Wiring wiring = wire(new BigDecimal("30"), new BigDecimal("20"));
        wiring.service.create(request(
                wiring, new BigDecimal("10"), wiring.sourceA(), wiring.sourceB()));
        assertSourceAllocations(wiring, new BigDecimal("10"),
                List.of(wiring.sourceA()), List.of(new BigDecimal("10")));
    }

    @Test
    void singleSourceLineKeepsWholeQuantityAsAllocation() {
        Wiring wiring = wire(new BigDecimal("30"), new BigDecimal("20"));
        wiring.service.create(request(
                wiring, new BigDecimal("8"), wiring.sourceA()));
        assertSourceAllocations(wiring, new BigDecimal("8"),
                List.of(wiring.sourceA()), List.of(new BigDecimal("8")));
    }

    @Test
    void independentDepartmentOrderDoesNotInventARequestAllocation() {
        Wiring wiring = wire(BigDecimal.TEN, BigDecimal.TEN);
        OrderSaveRequest req = request(wiring, BigDecimal.TEN, wiring.sourceA());
        req.getItems().getFirst().setRequestItemId(null);
        req.getItems().getFirst().setRequestItemIds(null);
        var document = wiring.service.create(req);
        assertNull(document.getItems().getFirst().getRequestItemId());
        assertEquals(0, BigDecimal.TEN.compareTo(document.getItems().getFirst().getQty()));
        assertEquals(Map.of(), wiring.captured());
    }

    private static void assertSourceAllocations(Wiring wiring, BigDecimal documentQty,
                                                List<UUID> sources, List<BigDecimal> physicalShares) {
        assertEquals(sources, wiring.captured().get("requestItemId"), "来源 UUID 必须保留 FIFO 顺序");
        assertEquals(java.util.stream.IntStream.rangeClosed(1, sources.size()).boxed().toList(),
                wiring.captured().get("lineNo"), "来源行号必须与 FIFO 顺序一致");
        var paid = wiring.captured().get("allocQty");
        var gift = wiring.captured().get("giftQty");
        assertEquals(sources.size(), paid.size());
        assertEquals(sources.size(), gift.size());
        BigDecimal paidTotal = BigDecimal.ZERO, giftTotal = BigDecimal.ZERO;
        for (int index = 0; index < sources.size(); index++) {
            BigDecimal sourcePaid = (BigDecimal) paid.get(index);
            BigDecimal sourceGift = (BigDecimal) gift.get(index);
            // NUMERIC(18,4) quantity equality is exact numeric equality. Scale is
            // representation, so 30 and 30.0000 must satisfy the same FIFO contract.
            assertEquals(0, physicalShares.get(index).compareTo(sourcePaid), "原收费份额必须精确保留");
            assertEquals(0, sourceGift.signum(), "未提供额外赠品的行不能伪造赠品来源份额");
            assertEquals(0, physicalShares.get(index).compareTo(sourcePaid.add(sourceGift)),
                    "每个来源的收费、赠品两分量必须共同守恒该来源实物预算");
            assertTrue(sourcePaid.signum() >= 0 && sourceGift.signum() >= 0);
            assertTrue(sourcePaid.scale() <= 4 && sourceGift.scale() <= 4);
            paidTotal = paidTotal.add(sourcePaid);
            giftTotal = giftTotal.add(sourceGift);
        }
        assertEquals(0, documentQty.compareTo(paidTotal));
        assertEquals(0, giftTotal.signum());
        assertEquals(0, documentQty.compareTo(paidTotal.add(giftTotal)));
    }
}
