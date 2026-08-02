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
        PurchaseOrderService service = new PurchaseOrderService(
                mock(PurchaseOrderRepository.class),
                mock(PurchaseOrderItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(ProductionSupplyTransitionPort.class),
                mock(TxSessionVars.class),
                currentUser,
                mock(EmployeeNameResolver.class),
                mock(EntityManager.class),
                numbers,
                mock(ProductionSupplySourceGuard.class),
                mock(PurchaseLineUnitPolicy.class),
                mock(ProcurementApprovalProjectionQuery.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class));

        ApiException error =
                assertThrows(ApiException.class, () -> service.create(request));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertTrue(error.getMessage().contains("必须关联采购申请明细"));
    }

    @Test
    void subcontractCreateRejectsMissingSourceAtDtoAndServiceBoundaries() {
        var request = subcontractRequest();
        assertTrue(validator.validate(request).stream().anyMatch(
                violation -> violation.getPropertyPath().toString()
                        .equals("items[0].applicationItemId")));

        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        DocNumberService numbers = mock(DocNumberService.class);
        when(numbers.nextNumber(any())).thenReturn("SO-SOURCE-REQUIRED");
        var service =
                new com.uten.imp.features.subcontract.order.SubcontractOrderService(
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderRepository.class),
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderItemRepository.class),
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderCostItemRepository.class),
                        mock(LinkedDocumentIntegrityService.class),
                        mock(TxSessionVars.class),
                        mock(EntityManager.class),
                        currentUser,
                        mock(EmployeeNameResolver.class),
                        numbers,
                        mock(ProductionSubcontractSupplyTransitionPort.class),
                        mock(ProductionSupplySourceGuard.class),
                        mock(ProcurementApprovalProjectionQuery.class),
                        mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class));

        ApiException error =
                assertThrows(ApiException.class, () -> service.create(request));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertTrue(error.getMessage().contains("必须关联委外申请明细"));
    }

    private static com.uten.imp.features.purchase.order.dto.OrderSaveRequest
            purchaseRequest() {
        var request =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 2));
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
