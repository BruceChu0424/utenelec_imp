package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.GoodsProfileHintRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/** 仓库入库工作台接口（/api/warehouse/inbound）：到货预期 + 到货异常（含财务定案后一键入库）。 */
@RestController
@RequestMapping("/api/warehouse/inbound")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('warehouse_inbound:view')")
public class WarehouseInboundController {

    private final ProcurementArrivalControlService service;
    private final PurchaseReceiptService purchaseReceiptService;
    private final SubcontractReceiptService subcontractReceiptService;
    private final WarehouseArrivalRegistrationService arrivalRegistration;

    @GetMapping("/expectations")
    public PageResponse<InboundExpectationTask> expectations(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "") String orderType,
            @RequestParam(defaultValue = "") String keyword) {
        return service.expectations(page, size, orderType, keyword);
    }

    @GetMapping("/expectations/count")
    public Map<String, Long> expectationCount() {
        return Map.of("count", service.countExpectations());
    }

    /** 预计到货按订货类型计数（全部/采购/委外筛选卡的全量口径）。 */
    @GetMapping("/expectations/type-counts")
    public Map<String, Long> expectationTypeCounts() {
        return service.countExpectationsByType();
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
     * 到货登记一步完成（登记 + 送检审核）：币种/汇率/结算方式由服务端按来源订货单权威回填，
     * 仓库只登记数量与库位；正常路径保存即转品质部待检（IQC），实到超量时按
     * EXCESS_QUARANTINED 返回（草稿已建、未入库未立应付，等待财务定案）。
     * 建单/审核权限由各收货单 Service 自身 @PreAuthorize 收口。
     */
    @PostMapping("/arrivals")
    public WarehouseArrivalRegisterResult registerArrival(
            @Valid @RequestBody WarehouseArrivalRegisterRequest request) {
        return arrivalRegistration.register(request);
    }

    /**
     * 完成中断的到货登记（断点恢复）：草稿收货单一键「继续送检」——服务端先按来源
     * 订货单权威修复表头币族（老草稿），再走同一审核链路；仓库不进采购/委外单据页。
     * 审核权限由各收货单 Service.approve 的 @PreAuthorize 收口。
     */
    @PostMapping("/arrivals/{receiptId}/complete")
    public WarehouseArrivalRegisterResult completeArrival(
            @PathVariable UUID receiptId) {
        return arrivalRegistration.complete(receiptId);
    }

    /**
     * 货品资料「学习」回写：仓库登记到货保存成功后，把本次填写的库位号/物料系列/物料编码
     * 回写货品主档，下次登记自动带出。code 仅补空防误改业务主键；空值跳过。返回 {updated, skipped}。
     */
    @PostMapping("/goods-profile-hints")
    public Map<String, Integer> goodsProfileHints(
            @Valid @RequestBody List<GoodsProfileHintRequest> hints) {
        return service.applyGoodsProfileHints(hints);
    }

    /**
     * 到货异常「一键入库」：财务已定案(RECEIPT_ADJUSTED)后，仓库无需再手动重开草稿收货单审核，
     * 直接按财务接受量入库+立应付。复用各收货单 Service.approve 的完整链路（库存/AP/recordApproval）。
     * V304：审核对明细的价格收窄会触发 receipt_item 守卫，统一走
     * {@link ProcurementArrivalControlService#stockInWithDecisionSession} 同事务打开决策会话开关。
     */
    @PostMapping("/arrival-exceptions/{id}/stock-in")
    @PreAuthorize("hasAuthority('warehouse_inbound:view') and hasAuthority('warehouse_inbound:stock_in')")
    public ArrivalExceptionTask stockInAccepted(@PathVariable UUID id) {
        return service.stockInWithDecisionSession(id, target -> {
            if (ProcurementArrivalControlPort.PURCHASE.equals(target.orderType())) {
                purchaseReceiptService.approveFromWarehouseDecision(target.receiptId());
            } else {
                subcontractReceiptService.approveFromWarehouseDecision(target.receiptId());
            }
        });
    }
}
