package com.uten.imp.features;

import com.uten.imp.application.port.ProcurementPriceAssessmentPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.pricing.ProcurementPriceAssessmentSupport;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderController;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.subcontract.order.SubcontractOrderController;
import com.uten.imp.features.subcontract.order.SubcontractOrderProgressService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProcurementPriceAssessmentAfterSaveTest {
    @Test void purchaseAssessmentRunsAfterSaveAndUsesTheAuthoritativeTotalInput() {
        var service = mock(PurchaseOrderService.class);
        var support = mock(ProcurementPriceAssessmentSupport.class);
        var controller = new PurchaseOrderController(service, mock(ProcurementFinanceApprovalService.class), mock(AuditDetailViewRecorder.class));
        ReflectionTestUtils.setField(controller, "priceAssessment", support);
        var request = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        var saved = mock(com.uten.imp.features.purchase.order.dto.OrderDetail.class);
        var line = mock(com.uten.imp.features.purchase.order.dto.OrderItemDto.class);
        UUID order = UUID.randomUUID(), item = UUID.randomUUID(), goods = UUID.randomUUID();
        when(saved.getId()).thenReturn(order); when(saved.getItems()).thenReturn(List.of(line));
        when(line.getId()).thenReturn(item); when(line.getGoodsId()).thenReturn(goods);
        when(line.getQty()).thenReturn(new BigDecimal("3000")); when(line.getPrice()).thenReturn(new BigDecimal("0.0333333333"));
        when(line.getTotalAmountInput()).thenReturn(new BigDecimal("100")); when(line.getUnitRate()).thenReturn(BigDecimal.ONE);
        when(service.create(request)).thenReturn(saved);
        var result = new ProcurementPriceAssessmentPort.Assessment("CHECKED", null, List.of());
        when(support.assess(any())).thenReturn(result);
        assertThat(controller.create(request)).isSameAs(saved);
        var orderOfCalls = inOrder(service, support);
        orderOfCalls.verify(service).create(request);
        orderOfCalls.verify(support).assess(argThat(q -> q.kind().equals("PURCHASE") && q.excludeOrderId().equals(order)
                && q.items().getFirst().totalAmountInput().compareTo(new BigDecimal("100")) == 0
                && q.items().getFirst().quantity().compareTo(new BigDecimal("3000")) == 0));
        verify(saved).setPriceAssessment(result);
    }
    @Test void maskedSubcontractPricesNeverReachTheAssessmentPort() {
        var service = mock(SubcontractOrderService.class);
        var support = mock(ProcurementPriceAssessmentSupport.class);
        var controller = new SubcontractOrderController(service, mock(ProcurementFinanceApprovalService.class),
                mock(SubcontractOrderProgressService.class), mock(AuditDetailViewRecorder.class));
        ReflectionTestUtils.setField(controller, "priceAssessment", support);
        var request = new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        var saved = mock(com.uten.imp.features.subcontract.order.dto.OrderDetail.class);
        when(saved.isPriceMasked()).thenReturn(true); when(service.create(request)).thenReturn(saved);
        assertThat(controller.create(request)).isSameAs(saved);
        verifyNoInteractions(support);
        verify(saved, never()).getItems();
    }
}
