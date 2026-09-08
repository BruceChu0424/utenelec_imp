package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.application.port.ProcurementIqcRejectionPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.PostMapping;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class ProcurementInspectionBatchContractTest {

    @Test
    void emptyAndDuplicateBatchesFailBeforeAnyBusinessLockOrWrite() {
        EntityManager em = mock(EntityManager.class);
        StockService stock = mock(StockService.class);
        ProductionSupplyTransitionPort purchase = mock(ProductionSupplyTransitionPort.class);
        ProductionSubcontractSupplyTransitionPort subcontract =
                mock(ProductionSubcontractSupplyTransitionPort.class);
        ProcurementInspectionService service = new ProcurementInspectionService(
                em,
                stock,
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                purchase,
                subcontract,
                mock(BusinessEventPublisher.class),
                mock(ProcurementIqcRejectionPort.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS),
                mock(com.uten.imp.common.finance.ProcurementReceiptConsiderationService.class),
                mock(com.uten.imp.application.port.ProcurementInventoryValuePort.class));
        UUID receiptId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();

        assertThatThrownBy(() -> service.passBatch(
                "PURCHASE",
                receiptId,
                new BatchInspectionPassRequest(List.of(), null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能为空");

        BatchInspectionPassRequest.Item first = new BatchInspectionPassRequest.Item(
                itemId,
                BigDecimal.ONE,
                "batch-item-0001");
        BatchInspectionPassRequest.Item duplicate = new BatchInspectionPassRequest.Item(
                itemId,
                BigDecimal.ONE,
                "batch-item-0002");
        assertThatThrownBy(() -> service.passBatch(
                "PURCHASE",
                receiptId,
                new BatchInspectionPassRequest(List.of(first, duplicate), null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能重复");

        verifyNoInteractions(em, stock, purchase, subcontract);
    }

    @Test
    void serviceAndControllerKeepAtomicTransactionAndExactPermissions() throws Exception {
        var serviceMethod = ProcurementInspectionService.class.getMethod(
                "passBatch",
                String.class,
                UUID.class,
                BatchInspectionPassRequest.class);
        assertThat(serviceMethod.getAnnotation(Transactional.class)).isNotNull();
        assertThat(serviceMethod.getAnnotation(PreAuthorize.class).value())
                .contains("procurement_inspection:view")
                .contains("procurement_inspection:handle");

        var controllerMethod = ProcurementInspectionController.class.getMethod(
                "passBatch",
                String.class,
                UUID.class,
                BatchInspectionPassRequest.class);
        assertThat(controllerMethod.getAnnotation(PostMapping.class).value())
                .containsExactly("/{receiptType}/{receiptId}/pass-batch");
        assertThat(controllerMethod.getAnnotation(PreAuthorize.class).value())
                .contains("procurement_inspection:view")
                .contains("procurement_inspection:handle");
    }
}
