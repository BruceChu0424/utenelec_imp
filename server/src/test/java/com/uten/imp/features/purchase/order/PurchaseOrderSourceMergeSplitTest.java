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
import static org.junit.jupiter.api.Assertions.assertThrows;
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
        when(masterQuery.getResultList()).thenReturn(List.<Object[]>of());

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
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy.class),
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class));
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
        line.setAmountOriginal(qty);
        line.setAmountLocal(qty);
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
        assertEquals(
                List.of(new BigDecimal("30"), new BigDecimal("20")),
                wiring.captured().get("allocQty"),
                "50 应按剩余量 FIFO 拆成 30 + 20");
        assertEquals(2, wiring.captured().get("lineNo").size());
    }

    @Test
    void overageIsAbsorbedByTheLastSource() {
        Wiring wiring = wire(new BigDecimal("30"), new BigDecimal("20"));
        wiring.service.create(request(
                wiring, new BigDecimal("60"), wiring.sourceA(), wiring.sourceB()));
        assertEquals(
                List.of(new BigDecimal("30"), new BigDecimal("30")),
                wiring.captured().get("allocQty"),
                "超采 60：首来源吃满剩余 30，末位来源吸收超额 30");
    }

    @Test
    void zeroShareSourcesAreDroppedWhenTotalShrinks() {
        Wiring wiring = wire(new BigDecimal("30"), new BigDecimal("20"));
        wiring.service.create(request(
                wiring, new BigDecimal("10"), wiring.sourceA(), wiring.sourceB()));
        assertEquals(
                List.of(new BigDecimal("10")),
                wiring.captured().get("allocQty"),
                "改小为 10：只落首来源一份，0 份额来源不落库");
    }

    @Test
    void singleSourceLineKeepsWholeQuantityAsAllocation() {
        Wiring wiring = wire(new BigDecimal("30"), new BigDecimal("20"));
        wiring.service.create(request(
                wiring, new BigDecimal("8"), wiring.sourceA()));
        assertEquals(
                List.of(new BigDecimal("8")),
                wiring.captured().get("allocQty"),
                "单来源行 alloc = 行数量（历史单锚语义）");
    }

    @Test
    void missingAnchorStillRejectedBeforeSplit() {
        Wiring wiring = wire(BigDecimal.TEN, BigDecimal.TEN);
        OrderSaveRequest req = request(wiring, BigDecimal.TEN, wiring.sourceA());
        req.getItems().getFirst().setRequestItemId(null);
        req.getItems().getFirst().setRequestItemIds(null);
        var error = assertThrows(
                com.uten.imp.common.web.ApiException.class,
                () -> wiring.service.create(req));
        assertEquals("第 1 行必须关联采购申请明细", error.getMessage());
    }
}
