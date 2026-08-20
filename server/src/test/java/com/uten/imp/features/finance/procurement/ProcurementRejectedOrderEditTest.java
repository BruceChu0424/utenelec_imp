package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderItemRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcurementRejectedOrderEditTest {

    @Test
    void rejectedProductionLinkedPurchaseOrderCanBeEditedAndResubmitted() {
        UUID orderId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        PurchaseOrder order = new PurchaseOrder();
        order.setId(orderId);
        order.setBillNo("PO-REJECTED");
        order.setBillDate(LocalDate.of(2026, 8, 2));
        order.setStatus((short) 0);

        PurchaseOrderRepository orderRepo = mock(PurchaseOrderRepository.class);
        PurchaseOrderItemRepository itemRepo = mock(PurchaseOrderItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        UUID requestItemId = UUID.randomUUID();
        stubPurchaseSnapshots(em, requestItemId, goodsId);
        ProductionSupplySourceGuard sourceGuard = mock(ProductionSupplySourceGuard.class);
        PurchaseLineUnitPolicy unitPolicy = mock(PurchaseLineUnitPolicy.class);
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        when(em.find(PurchaseOrder.class, orderId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
        when(sourceGuard.isPurchaseOrderLinked(orderId)).thenReturn(true);
        when(unitPolicy.normalizeAndValidate(
                goodsId, unitId, BigDecimal.ONE, 1))
                .thenReturn(new PurchaseLineUnitPolicy.ResolvedUnit(
                        unitId, BigDecimal.ONE));
        when(projection.latestForOrder("PURCHASE", orderId, (short) 0))
                .thenReturn(rejectedApproval());

        PurchaseOrderService service = new PurchaseOrderService(
                orderRepo,
                itemRepo,
                mock(LinkedDocumentIntegrityService.class),
                mock(ProductionSupplyTransitionPort.class),
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                em,
                mock(DocNumberService.class),
                sourceGuard,
                unitPolicy,
                projection,
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy.class));

        com.uten.imp.features.purchase.order.dto.OrderSaveRequest request =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 3));
        request.setItems(List.of(purchaseLine(goodsId, unitId, requestItemId)));

        var detail = service.update(orderId, request);

        assertTrue(detail.isProductionLinked());
        assertTrue(detail.isCanEdit());
        assertTrue(detail.isCanDelete());
        assertNull(detail.getRestrictionReason());
        assertEquals("REJECTED", detail.getFinanceApproval().status());
        assertEquals(
                List.of("SUBMIT_FINANCE"),
                detail.getFinanceApproval().allowedActions());
        ArgumentCaptor<com.uten.imp.features.purchase.order.PurchaseOrderItem> savedItem =
                ArgumentCaptor.forClass(
                        com.uten.imp.features.purchase.order.PurchaseOrderItem.class);
        verify(itemRepo).save(savedItem.capture());
        assertEquals("G-OLD", savedItem.getValue().getGoodsCodeSnapshot());
        assertEquals("REQUEST_ITEM_AT_SAVE", savedItem.getValue().getGoodsSnapshotSource());
        verify(projection).requireMutable("PURCHASE", orderId);
        verify(sourceGuard, never()).requirePurchaseOrderMutable(orderId);
    }

    @Test
    void rejectedProductionLinkedSubcontractOrderCanBeEditedAndResubmitted() {
        UUID orderId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        com.uten.imp.features.subcontract.order.SubcontractOrder order =
                new com.uten.imp.features.subcontract.order.SubcontractOrder();
        order.setId(orderId);
        order.setBillNo("SO-REJECTED");
        order.setBillDate(LocalDate.of(2026, 8, 2));
        order.setStatus((short) 0);

        var orderRepo = mock(
                com.uten.imp.features.subcontract.order.SubcontractOrderRepository.class);
        var itemRepo = mock(
                com.uten.imp.features.subcontract.order.SubcontractOrderItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        UUID applicationItemId = UUID.randomUUID();
        stubSubcontractSnapshots(em, applicationItemId, goodsId);
        ProductionSupplySourceGuard sourceGuard = mock(ProductionSupplySourceGuard.class);
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        when(em.find(
                com.uten.imp.features.subcontract.order.SubcontractOrder.class,
                orderId,
                LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
        when(sourceGuard.isSubcontractOrderLinked(orderId)).thenReturn(true);
        when(projection.latestForOrder("SUBCONTRACT", orderId, (short) 0))
                .thenReturn(rejectedApproval());

        var service = new com.uten.imp.features.subcontract.order.SubcontractOrderService(
                orderRepo,
                itemRepo,
                mock(com.uten.imp.features.subcontract.order.SubcontractOrderCostItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(TxSessionVars.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                mock(ProductionSubcontractSupplyTransitionPort.class),
                sourceGuard,
                projection,
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy.class),
                        mock(com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService.class));

        var request =
                new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 3));
        request.setItems(List.of(subcontractLine(goodsId, unitId, applicationItemId)));

        var detail = service.update(orderId, request);

        assertTrue(detail.isProductionLinked());
        assertTrue(detail.isCanEdit());
        assertTrue(detail.isCanDelete());
        assertNull(detail.getRestrictionReason());
        assertEquals("REJECTED", detail.getFinanceApproval().status());
        assertEquals(
                List.of("SUBMIT_FINANCE"),
                detail.getFinanceApproval().allowedActions());
        ArgumentCaptor<com.uten.imp.features.subcontract.order.SubcontractOrderItem>
                savedItem = ArgumentCaptor.forClass(
                        com.uten.imp.features.subcontract.order.SubcontractOrderItem.class);
        verify(itemRepo).save(savedItem.capture());
        assertEquals("G-OLD", savedItem.getValue().getGoodsCodeSnapshot());
        assertEquals("APPLICATION_ITEM_AT_SAVE",
                savedItem.getValue().getGoodsSnapshotSource());
        verify(projection).requireMutable("SUBCONTRACT", orderId);
        verify(sourceGuard, never()).requireSubcontractOrderMutable(orderId);
    }

    private static FinanceApproval rejectedApproval() {
        return new FinanceApproval(
                UUID.randomUUID(),
                "REJECTED",
                1,
                2,
                UUID.randomUUID(),
                UUID.randomUUID(),
                "财务负责人",
                "价格需修正",
                OffsetDateTime.now(),
                List.of("SUBMIT_FINANCE"));
    }

    private static com.uten.imp.features.purchase.order.dto.OrderItemLine purchaseLine(
            UUID goodsId, UUID unitId, UUID requestItemId) {
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setLineNo(1);
        line.setGoodsId(goodsId);
        line.setUnitId(unitId);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);
        line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(BigDecimal.TEN);
        line.setAmountLocal(BigDecimal.TEN);
        line.setRequestItemId(requestItemId);
        return line;
    }

    private static void stubPurchaseSnapshots(
            EntityManager em, UUID requestItemId, UUID goodsId) {
        Query requestQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM purchase_request_items")
                        // 排除订货行谱系继承查询（SELECT id, source_doc_no, ...）
                        // 与详情头来源申请解析（SELECT DISTINCT pr.id, pr.bill_no）。
                        && !sql.contains("source_doc_no")
                        && !sql.contains("SELECT DISTINCT pr.id"))))
                .thenReturn(requestQuery);
        when(requestQuery.setParameter(anyString(), any())).thenReturn(requestQuery);
        when(requestQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{requestItemId, goodsId, "G-OLD", "历史货品"}));
        Query requestLineage = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM purchase_request_items")
                        && sql.contains("source_doc_no"))))
                .thenReturn(requestLineage);
        when(requestLineage.setParameter(anyString(), any())).thenReturn(requestLineage);
        when(requestLineage.getResultList()).thenReturn(List.of());
        Query requestSource = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("SELECT DISTINCT pr.id"))))
                .thenReturn(requestSource);
        when(requestSource.setParameter(anyString(), any())).thenReturn(requestSource);
        when(requestSource.getResultList()).thenReturn(List.of());

        Query masterQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM goods"))))
                .thenReturn(masterQuery);
        when(masterQuery.setParameter(anyString(), any())).thenReturn(masterQuery);
        when(masterQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, goodsId, "G-NEW", "当前货品"}));
    }

    private static com.uten.imp.features.subcontract.order.dto.OrderItemLine subcontractLine(
            UUID goodsId, UUID unitId, UUID applicationItemId) {
        var line = new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setLineNo(1);
        line.setGoodsId(goodsId);
        line.setUnitId(unitId);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);
        line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(BigDecimal.TEN);
        line.setAmountLocal(BigDecimal.TEN);
        line.setApplicationItemId(applicationItemId);
        return line;
    }

    private static void stubSubcontractSnapshots(
            EntityManager em, UUID applicationItemId, UUID goodsId) {
        Query applicationQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM subcontract_application_items")
                        // 排除详情头来源申请解析查询（SELECT DISTINCT sa.id, sa.bill_no）。
                        && !sql.contains("SELECT DISTINCT sa.id"))))
                .thenReturn(applicationQuery);
        when(applicationQuery.setParameter(anyString(), any())).thenReturn(applicationQuery);
        when(applicationQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{applicationItemId, goodsId, "G-OLD", "历史货品"}));
        Query applicationSource = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("SELECT DISTINCT sa.id"))))
                .thenReturn(applicationSource);
        when(applicationSource.setParameter(anyString(), any())).thenReturn(applicationSource);
        when(applicationSource.getResultList()).thenReturn(List.of());

        Query masterQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM goods"))))
                .thenReturn(masterQuery);
        when(masterQuery.setParameter(anyString(), any())).thenReturn(masterQuery);
        when(masterQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, goodsId, "G-NEW", "当前货品"}));
    }
}
