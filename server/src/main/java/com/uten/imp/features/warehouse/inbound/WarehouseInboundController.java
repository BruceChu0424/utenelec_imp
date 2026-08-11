package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationTask;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/warehouse/inbound")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('warehouse_inbound:view')")
public class WarehouseInboundController {

    private final ProcurementArrivalControlService service;
    private final PurchaseReceiptService purchaseReceiptService;
    private final SubcontractReceiptService subcontractReceiptService;

    @GetMapping("/expectations")
    public PageResponse<InboundExpectationTask> expectations(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.expectations(page, size);
    }

    @GetMapping("/expectations/count")
    public Map<String, Long> expectationCount() {
        return Map.of("count", service.countExpectations());
    }

    @GetMapping("/arrival-exceptions")
    public PageResponse<ArrivalExceptionTask> arrivalExceptions(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String keyword,
            @RequestParam(name = "history", defaultValue = "false") boolean includeHistory) {
        return service.warehouseExceptions(page, size, keyword, includeHistory);
    }

    @GetMapping("/arrival-exceptions/count")
    public Map<String, Long> arrivalExceptionCount() {
        return Map.of("count", service.countWarehouseExceptions());
    }

    /**
     * 到货异常「一键入库」：财务已定案(RECEIPT_ADJUSTED)后，仓库无需再手动重开草稿收货单审核，
     * 直接按财务接受量入库+立应付。复用各收货单 Service.approve 的完整链路（库存/AP/recordApproval）。
     */
    @PostMapping("/arrival-exceptions/{id}/stock-in")
    @PreAuthorize(
            "hasAuthority('purchase_receipt:edit') or hasAuthority('subcontract_receipt:edit')")
    public ArrivalExceptionTask stockInAccepted(@PathVariable UUID id) {
        ProcurementArrivalControlService.StockTarget target =
                service.requireStockableException(id);
        if (ProcurementArrivalControlPort.PURCHASE.equals(target.orderType())) {
            purchaseReceiptService.approve(target.receiptId());
        } else {
            subcontractReceiptService.approve(target.receiptId());
        }
        return service.warehouseExceptionDetail(id);
    }
}
