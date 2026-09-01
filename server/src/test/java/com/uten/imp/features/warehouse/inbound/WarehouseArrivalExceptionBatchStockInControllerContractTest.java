package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInItem;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInResult;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.PostMapping;

import java.lang.reflect.Method;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class WarehouseArrivalExceptionBatchStockInControllerContractTest {

    @Test
    void controllerExposesExactBatchRouteAndDelegatesRequest() throws Exception {
        WarehouseArrivalExceptionStockInBatchService batch = mock(
                WarehouseArrivalExceptionStockInBatchService.class);
        WarehouseInboundController controller = new WarehouseInboundController(
                mock(ProcurementArrivalControlService.class),
                mock(PurchaseReceiptService.class),
                mock(SubcontractReceiptService.class),
                mock(WarehouseArrivalRegistrationService.class),
                batch);
        WarehouseArrivalExceptionBatchStockInRequest request =
                new WarehouseArrivalExceptionBatchStockInRequest(
                        "arrival-batch-key-1",
                        List.of(new WarehouseArrivalExceptionBatchStockInItem(
                                UUID.randomUUID(), 3L)));
        WarehouseArrivalExceptionBatchStockInResult expected =
                new WarehouseArrivalExceptionBatchStockInResult(
                        UUID.randomUUID(), false, true, 1, List.of());
        when(batch.stockInBatch(request)).thenReturn(expected);

        assertThat(controller.stockInAcceptedBatch(request)).isSameAs(expected);
        verify(batch).stockInBatch(request);

        Method endpoint = WarehouseInboundController.class.getMethod(
                "stockInAcceptedBatch",
                WarehouseArrivalExceptionBatchStockInRequest.class);
        assertThat(endpoint.getAnnotation(PostMapping.class).value())
                .containsExactly("/arrival-exceptions/batch-stock-in");
        assertThat(endpoint.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_inbound:view') and "
                        + "hasAuthority('warehouse_inbound:stock_in')");
    }

    @Test
    void coordinatorOwnsOneOuterRollbackTransaction() throws Exception {
        Method method = WarehouseArrivalExceptionStockInBatchService.class.getMethod(
                "stockInBatch",
                WarehouseArrivalExceptionBatchStockInRequest.class);

        assertThat(method.getAnnotation(Transactional.class)).isNotNull();
        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_inbound:stock_in')");
    }
}
