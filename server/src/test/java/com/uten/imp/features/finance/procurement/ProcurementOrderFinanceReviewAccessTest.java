package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderFinanceDecisionCommandService;
import com.uten.imp.features.purchase.order.PurchaseOrderItemRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.OrderQueryFilter;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.SubcontractOrder;
import com.uten.imp.features.subcontract.order.SubcontractOrderFinanceDecisionCommandService;
import com.uten.imp.features.subcontract.order.SubcontractOrderCostItemRepository;
import com.uten.imp.features.subcontract.order.SubcontractOrderItemRepository;
import com.uten.imp.features.subcontract.order.SubcontractOrderRepository;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcurementOrderFinanceReviewAccessTest {

    @Test
    void eligibleReviewerCanOpenOwnerHiddenPendingTaskForBothOrderTypes() {
        PurchaseFixture purchase = purchaseFixture((short) 0);
        // Explicitly model a reviewer without purchase:view:all.
        when(purchase.access().canRead(purchase.ownerId())).thenReturn(false);
        when(purchase.projection().canCurrentActorReviewPending(
                "PURCHASE", purchase.orderId())).thenReturn(true);

        assertEquals(purchase.orderId(), purchase.service().detail(purchase.orderId()).getId());
        verify(purchase.projection()).canCurrentActorReviewPending(
                "PURCHASE", purchase.orderId());

        SubcontractFixture subcontract = subcontractFixture((short) 0);
        // Explicitly model a reviewer without subcontract:view:all.
        when(subcontract.access().canRead(subcontract.ownerId())).thenReturn(false);
        when(subcontract.projection().canCurrentActorReviewPending(
                "SUBCONTRACT", subcontract.orderId())).thenReturn(true);

        assertEquals(
                subcontract.orderId(),
                subcontract.service().detail(subcontract.orderId()).getId());
        verify(subcontract.projection()).canCurrentActorReviewPending(
                "SUBCONTRACT", subcontract.orderId());
    }

    @Test
    void ownerHiddenOrderWithoutPendingTaskRemainsNotFound() {
        PurchaseFixture purchase = purchaseFixture((short) 1);
        when(purchase.access().canRead(purchase.ownerId())).thenReturn(false);
        when(purchase.projection().canCurrentActorReviewPending(
                "PURCHASE", purchase.orderId())).thenReturn(false);

        ApiException purchaseDenied = assertThrows(
                ApiException.class,
                () -> purchase.service().detail(purchase.orderId()));
        assertEquals(ErrorCode.NOT_FOUND, purchaseDenied.getCode());
        verify(purchase.items(), never()).findByOrderIdOrderByLineNoAsc(any(UUID.class));

        SubcontractFixture subcontract = subcontractFixture((short) 1);
        when(subcontract.access().canRead(subcontract.ownerId())).thenReturn(false);
        when(subcontract.projection().canCurrentActorReviewPending(
                "SUBCONTRACT", subcontract.orderId())).thenReturn(false);

        ApiException subcontractDenied = assertThrows(
                ApiException.class,
                () -> subcontract.service().detail(subcontract.orderId()));
        assertEquals(ErrorCode.NOT_FOUND, subcontractDenied.getCode());
        verify(subcontract.items(), never())
                .findByOrderIdOrderByLineNoAsc(any(UUID.class));
    }

    @Test
    void ordinaryOwnerReadDoesNotDependOnFinanceTaskAccess() {
        PurchaseFixture purchase = purchaseFixture((short) 0);
        when(purchase.access().canRead(purchase.ownerId())).thenReturn(true);

        assertEquals(purchase.orderId(), purchase.service().detail(purchase.orderId()).getId());
        verify(purchase.projection(), never())
                .canCurrentActorReviewPending(anyString(), any(UUID.class));

        SubcontractFixture subcontract = subcontractFixture((short) 0);
        when(subcontract.access().canRead(subcontract.ownerId())).thenReturn(true);

        assertEquals(
                subcontract.orderId(),
                subcontract.service().detail(subcontract.orderId()).getId());
        verify(subcontract.projection(), never())
                .canCurrentActorReviewPending(anyString(), any(UUID.class));
    }

    @Test
    void financeDecisionResultRequiresAuthoritativeReviewerEligibility() {
        PurchaseFixture allowedPurchase = purchaseFixture((short) 1);
        UUID purchaseCaseId = UUID.randomUUID();
        var purchaseDecision = decidedApproval(purchaseCaseId);
        when(allowedPurchase.projection().isCurrentActorEligibleReviewer())
                .thenReturn(true);
        ProcurementFinanceApprovalService purchaseApproval =
                mock(ProcurementFinanceApprovalService.class);
        when(purchaseApproval.approve(
                "PURCHASE", allowedPurchase.orderId(), 1L))
                .thenReturn(purchaseDecision);
        var purchaseResult = new PurchaseOrderFinanceDecisionCommandService(
                purchaseApproval, allowedPurchase.service())
                .approve(allowedPurchase.orderId(), 1L);
        assertEquals(allowedPurchase.orderId(), purchaseResult.getId());
        assertEquals(purchaseCaseId, purchaseResult.getFinanceApproval().caseId());
        verify(allowedPurchase.access(), never()).canRead(any(UUID.class));

        PurchaseFixture deniedPurchase = purchaseFixture((short) 1);
        when(deniedPurchase.projection().isCurrentActorEligibleReviewer())
                .thenReturn(false);
        ProcurementFinanceApprovalService deniedPurchaseApproval =
                mock(ProcurementFinanceApprovalService.class);
        when(deniedPurchaseApproval.approve(
                "PURCHASE", deniedPurchase.orderId(), 1L))
                .thenReturn(decidedApproval(UUID.randomUUID()));
        assertEquals(
                ErrorCode.NOT_FOUND,
                assertThrows(ApiException.class, () ->
                        new PurchaseOrderFinanceDecisionCommandService(
                                deniedPurchaseApproval, deniedPurchase.service())
                                .approve(deniedPurchase.orderId(), 1L)).getCode());

        SubcontractFixture allowedSubcontract = subcontractFixture((short) 1);
        UUID subcontractCaseId = UUID.randomUUID();
        var subcontractDecision = decidedApproval(subcontractCaseId);
        when(allowedSubcontract.projection().isCurrentActorEligibleReviewer())
                .thenReturn(true);
        ProcurementFinanceApprovalService subcontractApproval =
                mock(ProcurementFinanceApprovalService.class);
        when(subcontractApproval.approve(
                "SUBCONTRACT", allowedSubcontract.orderId(), 1L))
                .thenReturn(subcontractDecision);
        var subcontractResult = new SubcontractOrderFinanceDecisionCommandService(
                subcontractApproval, allowedSubcontract.service())
                .approve(allowedSubcontract.orderId(), 1L);
        assertEquals(allowedSubcontract.orderId(), subcontractResult.getId());
        assertEquals(
                subcontractCaseId,
                subcontractResult.getFinanceApproval().caseId());
        verify(allowedSubcontract.access(), never()).canRead(any(UUID.class));

        SubcontractFixture deniedSubcontract = subcontractFixture((short) 1);
        when(deniedSubcontract.projection().isCurrentActorEligibleReviewer())
                .thenReturn(false);
        ProcurementFinanceApprovalService deniedSubcontractApproval =
                mock(ProcurementFinanceApprovalService.class);
        when(deniedSubcontractApproval.approve(
                "SUBCONTRACT", deniedSubcontract.orderId(), 1L))
                .thenReturn(decidedApproval(UUID.randomUUID()));
        assertEquals(
                ErrorCode.NOT_FOUND,
                assertThrows(ApiException.class, () ->
                        new SubcontractOrderFinanceDecisionCommandService(
                                deniedSubcontractApproval,
                                deniedSubcontract.service())
                                .approve(deniedSubcontract.orderId(), 1L)).getCode());
    }

    @Test
    @SuppressWarnings("unchecked")
    void listRemainsBoundToOrdinaryOwnerScope() {
        PurchaseFixture purchase = purchaseFixture((short) 0);
        OwnerVisibility.OwnerScope purchaseScope =
                new OwnerVisibility.OwnerScope(false, Set.of(purchase.ownerId()));
        when(purchase.access().scope()).thenReturn(purchaseScope);
        when(purchase.orders().findAll(
                any(Specification.class), any(Pageable.class)))
                .thenReturn(Page.empty());
        when(purchase.projection().latestForOrders(eq("PURCHASE"), any(Map.class)))
                .thenReturn(Map.of());

        purchase.service().list(
                new OrderQueryFilter(null, null, null, null, null, null),
                1, 20, null, null);
        verify(purchase.access()).scope();
        verify(purchase.projection(), never())
                .canCurrentActorReviewPending(anyString(), any(UUID.class));

        SubcontractFixture subcontract = subcontractFixture((short) 0);
        OwnerVisibility.OwnerScope subcontractScope =
                new OwnerVisibility.OwnerScope(false, Set.of(subcontract.ownerId()));
        when(subcontract.access().scope()).thenReturn(subcontractScope);
        when(subcontract.orders().findAll(
                any(Specification.class), any(Pageable.class)))
                .thenReturn(Page.empty());
        when(subcontract.projection().latestForOrders(
                eq("SUBCONTRACT"), any(Map.class)))
                .thenReturn(Map.of());

        subcontract.service().list(
                new com.uten.imp.features.subcontract.order.dto.OrderQueryFilter(
                        null, null, null, null, null, null, null),
                1, 20, null, null);
        verify(subcontract.access()).scope();
        verify(subcontract.projection(), never())
                .canCurrentActorReviewPending(anyString(), any(UUID.class));
    }

    @Test
    void editRemainsOwnerGatedAndDoesNotUseFinanceReviewBypass() {
        PurchaseFixture purchase = purchaseFixture((short) 0);
        ApiException purchaseForbidden =
                new ApiException(ErrorCode.FORBIDDEN, "owner only");
        doThrow(purchaseForbidden).when(purchase.access()).requireWritable(
                eq(purchase.ownerId()), anyString(), any(String[].class));

        ApiException actualPurchase = assertThrows(
                ApiException.class,
                () -> purchase.service().update(
                        purchase.orderId(),
                        new com.uten.imp.features.purchase.order.dto.OrderSaveRequest()));
        assertSame(purchaseForbidden, actualPurchase);
        verify(purchase.projection(), never())
                .canCurrentActorReviewPending(anyString(), any(UUID.class));
        verify(purchase.projection(), never()).isCurrentActorEligibleReviewer();

        SubcontractFixture subcontract = subcontractFixture((short) 0);
        ApiException subcontractForbidden =
                new ApiException(ErrorCode.FORBIDDEN, "owner only");
        doThrow(subcontractForbidden).when(subcontract.access()).requireWritable(
                eq(subcontract.ownerId()), anyString(), any(String[].class));

        ApiException actualSubcontract = assertThrows(
                ApiException.class,
                () -> subcontract.service().update(
                        subcontract.orderId(),
                        new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest()));
        assertSame(subcontractForbidden, actualSubcontract);
        verify(subcontract.projection(), never())
                .canCurrentActorReviewPending(anyString(), any(UUID.class));
        verify(subcontract.projection(), never()).isCurrentActorEligibleReviewer();
    }

    private static PurchaseFixture purchaseFixture(short status) {
        UUID orderId = UUID.randomUUID();
        UUID ownerId = UUID.randomUUID();
        PurchaseOrder order = new PurchaseOrder();
        order.setId(orderId);
        order.setMakerId(ownerId);
        order.setBillNo("PO-REVIEW");
        order.setBillDate(LocalDate.of(2026, 8, 10));
        order.setStatus(status);

        PurchaseOrderRepository orders = mock(PurchaseOrderRepository.class);
        PurchaseOrderItemRepository items = mock(PurchaseOrderItemRepository.class);
        EntityManager entityManager = mock(EntityManager.class);
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        PurchaseDocumentAccessPolicy access = mock(PurchaseDocumentAccessPolicy.class);
        when(orders.findById(orderId)).thenReturn(Optional.of(order));
        when(items.findByOrderIdOrderByLineNoAsc(orderId)).thenReturn(List.of());
        when(entityManager.find(PurchaseOrder.class, orderId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);

        PurchaseOrderService service = new PurchaseOrderService(
                orders,
                items,
                mock(LinkedDocumentIntegrityService.class),
                mock(ProductionSupplyTransitionPort.class),
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                entityManager,
                mock(DocNumberService.class),
                mock(ProductionSupplySourceGuard.class),
                mock(PurchaseLineUnitPolicy.class),
                projection,
                mock(ProcurementArrivalControlPort.class),
                access);
        return new PurchaseFixture(
                orderId, ownerId, service, orders, items, projection, access);
    }

    private static ProcurementApprovalContracts.FinanceApproval decidedApproval(
            UUID caseId) {
        return new ProcurementApprovalContracts.FinanceApproval(
                caseId,
                "APPROVED",
                1,
                2,
                UUID.randomUUID(),
                UUID.randomUUID(),
                "finance reviewer",
                null,
                OffsetDateTime.now(),
                List.of());
    }

    private static SubcontractFixture subcontractFixture(short status) {
        UUID orderId = UUID.randomUUID();
        UUID ownerId = UUID.randomUUID();
        SubcontractOrder order = new SubcontractOrder();
        order.setId(orderId);
        order.setMakerId(ownerId);
        order.setBillNo("SO-REVIEW");
        order.setBillDate(LocalDate.of(2026, 8, 10));
        order.setStatus(status);

        SubcontractOrderRepository orders = mock(SubcontractOrderRepository.class);
        SubcontractOrderItemRepository items =
                mock(SubcontractOrderItemRepository.class);
        EntityManager entityManager = mock(EntityManager.class);
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        SubcontractDocumentAccessPolicy access =
                mock(SubcontractDocumentAccessPolicy.class);
        when(orders.findById(orderId)).thenReturn(Optional.of(order));
        when(items.findByOrderIdOrderByLineNoAsc(orderId)).thenReturn(List.of());
        when(entityManager.find(
                SubcontractOrder.class, orderId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);

        SubcontractOrderService service = new SubcontractOrderService(
                orders,
                items,
                mock(SubcontractOrderCostItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(TxSessionVars.class),
                entityManager,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                mock(ProductionSubcontractSupplyTransitionPort.class),
                mock(ProductionSupplySourceGuard.class),
                projection,
                mock(ProcurementArrivalControlPort.class),
                access);
        return new SubcontractFixture(
                orderId, ownerId, service, orders, items, projection, access);
    }

    private record PurchaseFixture(
            UUID orderId,
            UUID ownerId,
            PurchaseOrderService service,
            PurchaseOrderRepository orders,
            PurchaseOrderItemRepository items,
            ProcurementApprovalProjectionQuery projection,
            PurchaseDocumentAccessPolicy access) {
    }

    private record SubcontractFixture(
            UUID orderId,
            UUID ownerId,
            SubcontractOrderService service,
            SubcontractOrderRepository orders,
            SubcontractOrderItemRepository items,
            ProcurementApprovalProjectionQuery projection,
            SubcontractDocumentAccessPolicy access) {
    }
}
