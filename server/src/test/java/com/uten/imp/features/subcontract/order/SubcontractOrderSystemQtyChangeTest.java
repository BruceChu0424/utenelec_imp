package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-103 §2.5 实施记录：系统按约定允许损耗自动结案的受控改量只跳过订货单属主守卫,
 * 财务复核 case **照开**(V503 守卫要求批准后改量同事务开一条 PENDING 复核, 缺了直接回滚),
 * 改量日志挂在这条 case 上; 人工「接受损耗」判定走的 changeQtyForShortDelivery 两者都做。
 */
class SubcontractOrderSystemQtyChangeTest {

    private SubcontractOrderItemRepository itemRepo;
    private SubcontractOrderRepository orderRepo;
    private com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService materialPlans;
    private ProcurementApprovalReconfirmationService reconfirmation;
    private SubcontractDocumentAccessPolicy access;
    private EntityManager em;
    private Query query;
    private SubcontractOrderService service;

    @BeforeEach
    void setUp() {
        orderRepo = mock(SubcontractOrderRepository.class);
        itemRepo = mock(SubcontractOrderItemRepository.class);
        materialPlans = mock(com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService.class);
        reconfirmation = mock(ProcurementApprovalReconfirmationService.class);
        access = mock(SubcontractDocumentAccessPolicy.class);
        em = mock(EntityManager.class);
        query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.setParameter(anyInt(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        // ProcurementOrderQuantityBounds.receipts：received / returned / iqc_returned / excess 基本量全 0。
        when(query.getSingleResult()).thenReturn(
                new Object[]{BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO});
        when(materialPlans.minimumOrderQtyFromIssued(any(), any())).thenReturn(BigDecimal.ZERO);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        service = new SubcontractOrderService(
                orderRepo,
                itemRepo,
                mock(SubcontractOrderCostItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(TxSessionVars.class),
                em,
                currentUser,
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                mock(ProductionSubcontractSupplyTransitionPort.class),
                mock(ProductionSupplySourceGuard.class),
                mock(ProcurementApprovalProjectionQuery.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                access,
                materialPlans,
                reconfirmation,
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),
                mock(com.uten.imp.application.port.ProcurementReviewCancellationPort.class),
                mock(com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.class),
                mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS),
                mock(com.uten.imp.features.purchase.common.ProcurementMasterDefaultsSyncService.class));
    }

    @Test
    void systemInitiatedShortDeliverySettlementOpensReconfirmationCaseButSkipsOwnerGuard() {
        UUID orderId = UUID.randomUUID();
        SubcontractOrderItem item = stub(orderId);
        UUID caseId = UUID.randomUUID();
        when(reconfirmation.openReconfirmationCase(any(), anyLong())).thenReturn(caseId);

        assertNull(service.changeQtyForShortDeliveryBySystem(orderId, request(item, "950")),
                "系统路径不构造面向人的读模型");

        verify(reconfirmation).openReconfirmationCase(any(), eq(1L));
        verify(access, never()).requireWritable(any(), anyString());
        String insert = changeLogInsert();
        assertTrue(insert.contains("case_id, changed_by_employee_id)"), insert);
        assertTrue(insert.contains("?, ?)"), "改量日志的 case_id 按参数绑定(V503 守卫要求挂复核 case): " + insert);
        verify(query).setParameter(6, caseId);
        assertEquals(0, new BigDecimal("950").compareTo(item.getQty()), "订货量改到累计回厂量");
        verify(itemRepo).save(item);
    }

    @Test
    void manualShortDeliveryDecisionStillOpensReconfirmationCase() {
        UUID orderId = UUID.randomUUID();
        SubcontractOrderItem item = stub(orderId);
        UUID caseId = UUID.randomUUID();
        when(reconfirmation.openReconfirmationCase(any(), anyLong())).thenReturn(caseId);

        try {
            service.changeQtyForShortDelivery(orderId, request(item, "950"));
        } catch (RuntimeException readModelNotUnderTest) {
            // 人工路径末尾要组装 detail(id) 读模型, 那部分不在本用例范围; 改量与复核已在此前完成。
        }

        verify(reconfirmation).openReconfirmationCase(any(), eq(1L));
        verify(access).requireWritable(any(), anyString());
        String insert = changeLogInsert();
        assertTrue(insert.contains("?, ?)"), "人为改量的 case_id 按参数绑定: " + insert);
        verify(query).setParameter(6, caseId);
    }

    private String changeLogInsert() {
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.atLeastOnce()).createNativeQuery(sql.capture());
        return sql.getAllValues().stream()
                .filter(text -> text.contains("INSERT INTO procurement_order_qty_change_logs"))
                .findFirst()
                .orElseThrow(() -> new AssertionError("change log insert not issued: " + sql.getAllValues()));
    }

    private static OrderQtyChangeRequest request(SubcontractOrderItem item, String newQty) {
        return new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(item.getId(), new BigDecimal(newQty))));
    }

    private SubcontractOrderItem stub(UUID orderId) {
        SubcontractOrder order = new SubcontractOrder();
        order.setId(orderId);
        order.setBillNo("EO202609220001");
        order.setBillDate(LocalDate.of(2026, 9, 22));
        order.setStatus((short) 1);
        order.setMakerId(UUID.randomUUID());
        order.setTotalLocal(BigDecimal.ZERO);
        order.setTotalOriginal(BigDecimal.ZERO);
        SubcontractOrderItem item = new SubcontractOrderItem();
        item.setId(UUID.randomUUID());
        item.setOrderId(orderId);
        item.setLineNo(1);
        item.setGoodsId(UUID.randomUUID());
        item.setUnitId(UUID.randomUUID());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal("1000"));
        item.setReceivedQty(new BigDecimal("950"));
        item.setReturnedQty(BigDecimal.ZERO);
        item.setIssuedQty(BigDecimal.ZERO);
        item.setMaterialReturnedQty(BigDecimal.ZERO);
        when(em.find(SubcontractOrder.class, orderId, LockModeType.PESSIMISTIC_WRITE)).thenReturn(order);
        when(orderRepo.findById(orderId)).thenReturn(Optional.of(order));
        when(itemRepo.findByOrderIdOrderByLineNoAsc(orderId)).thenReturn(List.of(item));
        return item;
    }
}
