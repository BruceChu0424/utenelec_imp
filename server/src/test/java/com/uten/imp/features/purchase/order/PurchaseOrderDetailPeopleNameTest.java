package com.uten.imp.features.purchase.order;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.common.ProcurementMasterDefaultsSyncService;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 采购订货单详情随单返回人员「姓名(工号)」(2026-10-17 口径)：采购员(purchaserName)与
 * 制单员(makerName)都由服务端解析，前端不再渲染裸 purchaserId/账号名（详情页此前把
 * employees.id 原样显示给用户）。与仓库详情 StockDocDetailPeopleNameTest 同一模式：
 * 名称由服务端随单下发，前端不逐张调员工档案接口(该接口要求 employee:view 且落人事
 * 查看审计，采购账号通常没有)。
 */
class PurchaseOrderDetailPeopleNameTest {

    @Test
    void detailCarriesPurchaserAndMakerNamesWithEmployeeCode() {
        UUID purchaser = UUID.randomUUID();
        UUID maker = UUID.randomUUID();
        PurchaseOrder order = order(purchaser, maker);
        PurchaseOrderRepository orderRepo = mock(PurchaseOrderRepository.class);
        when(orderRepo.findById(order.getId())).thenReturn(Optional.of(order));
        PurchaseOrderItemRepository itemRepo = mock(PurchaseOrderItemRepository.class);
        when(itemRepo.findByOrderIdOrderByLineNoAsc(order.getId())).thenReturn(List.of());
        PurchaseDocumentAccessPolicy access = mock(PurchaseDocumentAccessPolicy.class);
        when(access.canRead(maker)).thenReturn(true);
        com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery approvalProjection =
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery.class);
        when(approvalProjection.latestForOrder(org.mockito.ArgumentMatchers.anyString(),
                        org.mockito.ArgumentMatchers.eq(order.getId()), org.mockito.ArgumentMatchers.anyShort()))
                .thenReturn(null);

        EmployeeNameResolver employeeNames = mock(EmployeeNameResolver.class);
        when(employeeNames.nameWithCodeOf(purchaser)).thenReturn("李采购(E1024)");
        when(employeeNames.nameWithCodeOf(maker)).thenReturn("朱振炜(E1001)");

        OrderDetail detail = service(orderRepo, itemRepo, access, approvalProjection, employeeNames)
                .detail(order.getId());

        assertEquals(purchaser, detail.getPurchaserId());
        assertEquals("李采购(E1024)", detail.getPurchaserName());
        assertEquals("朱振炜(E1001)", detail.getMakerName());
        verify(employeeNames).nameWithCodeOf(purchaser);
        verify(employeeNames).nameWithCodeOf(maker);
    }

    /** 历史单据采购员为空时：purchaserName 为 null，前端按「—」占位，与旧口径一致。 */
    @Test
    void detailLeavesPurchaserNameNullWhenOrderHasNoPurchaser() {
        PurchaseOrder order = order(null, UUID.randomUUID());
        PurchaseOrderRepository orderRepo = mock(PurchaseOrderRepository.class);
        when(orderRepo.findById(order.getId())).thenReturn(Optional.of(order));
        PurchaseOrderItemRepository itemRepo = mock(PurchaseOrderItemRepository.class);
        when(itemRepo.findByOrderIdOrderByLineNoAsc(order.getId())).thenReturn(List.of());
        PurchaseDocumentAccessPolicy access = mock(PurchaseDocumentAccessPolicy.class);
        when(access.canRead(org.mockito.ArgumentMatchers.any())).thenReturn(true);

        OrderDetail detail = service(orderRepo, itemRepo, access,
                        mock(com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery.class),
                        mock(EmployeeNameResolver.class))
                .detail(order.getId());

        assertNull(detail.getPurchaserId());
        assertNull(detail.getPurchaserName());
    }

    private PurchaseOrderService service(
            PurchaseOrderRepository orderRepo,
            PurchaseOrderItemRepository itemRepo,
            PurchaseDocumentAccessPolicy access,
            com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery approvalProjection,
            EmployeeNameResolver employeeNames) {
        return new PurchaseOrderService(
                orderRepo,
                itemRepo,
                mock(com.uten.imp.common.integrity.LinkedDocumentIntegrityService.class),
                mock(com.uten.imp.application.port.ProductionSupplyTransitionPort.class),
                mock(com.uten.imp.security.TxSessionVars.class),
                mock(com.uten.imp.security.SecurityContextCurrentUser.class),
                employeeNames,
                mock(EntityManager.class),
                mock(com.uten.imp.common.docnumber.DocNumberService.class),
                mock(com.uten.imp.common.integrity.ProductionSupplySourceGuard.class),
                mock(com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy.class),
                approvalProjection,
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                access,
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),
                mock(com.uten.imp.application.port.ProcurementReviewCancellationPort.class),
                mock(com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.class),
                mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class),
                mock(ProcurementMasterDefaultsSyncService.class));
    }

    private static PurchaseOrder order(UUID purchaserId, UUID makerId) {
        PurchaseOrder order = new PurchaseOrder();
        order.setId(UUID.randomUUID());
        order.setBillNo("PO-TEST-001");
        order.setStatus((short) 0);
        order.setPurchaserId(purchaserId);
        order.setMakerId(makerId);
        return order;
    }
}
