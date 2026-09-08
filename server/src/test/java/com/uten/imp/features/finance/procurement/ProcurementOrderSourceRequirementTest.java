package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrderItemRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementOrderSourceRequirementTest {

    private final Validator validator =
            Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void purchaseCreateRejectsMissingSourceAtDtoAndServiceBoundaries() {
        var request = purchaseRequest();
        assertTrue(validator.validate(request).stream().anyMatch(
                violation -> violation.getPropertyPath().toString()
                        .equals("items[0].requestItemId")));

        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        DocNumberService numbers = mock(DocNumberService.class);
        when(numbers.nextNumber(any())).thenReturn("PO-SOURCE-REQUIRED");
        EntityManager em = mock(EntityManager.class);
        // 请求携带结账方式（2026-09 起 @NotNull 改 service 运行时校验）→
        // applyHeader 走 UUID resolver 查 settlement_methods，stub 一行有效映射。
        jakarta.persistence.Query settlementQuery =
                mock(jakarta.persistence.Query.class);
        when(em.createNativeQuery(org.mockito.ArgumentMatchers.argThat(sql ->
                sql != null && sql.contains("FROM settlement_methods method"))))
                .thenReturn(settlementQuery);
        when(settlementQuery.setParameter(any(String.class), any()))
                .thenReturn(settlementQuery);
        when(settlementQuery.setMaxResults(org.mockito.ArgumentMatchers.anyInt()))
                .thenReturn(settlementQuery);
        when(settlementQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{UUID.randomUUID(), 1, "CASH", "现金", null}));
        PurchaseOrderService service = new PurchaseOrderService(
                mock(PurchaseOrderRepository.class),
                mock(PurchaseOrderItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(ProductionSupplyTransitionPort.class),
                mock(TxSessionVars.class),
                currentUser,
                mock(EmployeeNameResolver.class),
                em,
                numbers,
                mock(ProductionSupplySourceGuard.class),
                mock(PurchaseLineUnitPolicy.class),
                mock(ProcurementApprovalProjectionQuery.class),
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService.class),
                // 2026-09-05 cancel() 撤回财务弹卡用；本测试不触达，传 mock 即可。
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy.class),
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementReviewCancellationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS));

        ApiException error =
                assertThrows(ApiException.class, () -> service.create(request));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertTrue(error.getMessage().contains("必须关联采购申请明细"));
    }

    @Test
    void subcontractCreateAllowsManualLineWithoutApplicationSource() {
        // V304 委外全链路重设计：委外订货两条来源（计划申请分解 / 委外自建手工行），
        // 手工行 applicationItemId 为空，DTO 与 create 边界均不再拦截；
        // 申请来源一致性校验只作用于申请分解行（提交财务时逐行核验）。
        var request = subcontractRequest();
        assertTrue(validator.validate(request).stream().noneMatch(
                violation -> violation.getPropertyPath().toString()
                        .equals("items[0].applicationItemId")));

        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        DocNumberService numbers = mock(DocNumberService.class);
        when(numbers.nextNumber(any())).thenReturn("SO-MANUAL");
        EntityManager em = mock(EntityManager.class);
        jakarta.persistence.Query query = mock(jakarta.persistence.Query.class);
        when(em.createNativeQuery(any())).thenReturn(query);
        when(query.setParameter(any(String.class), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        var service =
                new com.uten.imp.features.subcontract.order.SubcontractOrderService(
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderRepository.class),
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderItemRepository.class),
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderCostItemRepository.class),
                        mock(LinkedDocumentIntegrityService.class),
                        mock(TxSessionVars.class),
                        em,
                        currentUser,
                        mock(EmployeeNameResolver.class),
                        numbers,
                        mock(ProductionSubcontractSupplyTransitionPort.class),
                        mock(ProductionSupplySourceGuard.class),
                        mock(ProcurementApprovalProjectionQuery.class),
                        mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                        mock(com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy.class),
                        mock(com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService.class),
                                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService.class),
                        mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),
                        mock(com.uten.imp.application.port.ProcurementReviewCancellationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS));

        // 手工行不再被「必须关联委外申请明细」拦截；mock 环境下只会停在后续的
        // 货品主档快照缺失校验（证明流程已越过来源校验进入保存管线）。
        ApiException error =
                assertThrows(ApiException.class, () -> service.create(request));
        org.junit.jupiter.api.Assertions.assertFalse(
                error.getMessage().contains("必须关联委外申请明细"));
    }

    private static com.uten.imp.features.purchase.order.dto.OrderSaveRequest
            purchaseRequest() {
        var request =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 2));
        // 结账方式随 2026-09 行级条款改造从 @NotNull 移到 service 运行时校验；
        // 本测试锁「缺申请来源」边界，带齐结账方式让流程走到来源校验。
        request.setSettlementMethodId(UUID.randomUUID());
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(UUID.randomUUID());
        line.setQty(BigDecimal.ONE);
        request.setItems(List.of(line));
        return request;
    }

    private static com.uten.imp.features.subcontract.order.dto.OrderSaveRequest
            subcontractRequest() {
        var request =
                new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 2));
        var line =
                new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setGoodsId(UUID.randomUUID());
        line.setQty(BigDecimal.ONE);
        request.setItems(List.of(line));
        return request;
    }
}
