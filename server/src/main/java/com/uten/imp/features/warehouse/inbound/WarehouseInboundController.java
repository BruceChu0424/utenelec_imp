package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.GoodsProfileHintRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalExceptionBatchStockInResult;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalBatchCompleteRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalBatchCompleteResult;
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

import com.uten.imp.application.port.WarehouseTaskScopePort;

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
    private final WarehouseArrivalExceptionStockInBatchService batchStockIn;
    private final WarehouseTaskScopePort warehouseScopes;

    @GetMapping("/expectations")
    public PageResponse<InboundExpectationTask> expectations(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "") String orderType,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID scopeWarehouseId,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo) {
        // 仓库数据范围(ADR-149)：服务端按本人范围强制过滤；scopeWarehouseId = 在可选范围内挑一个仓(含下级), 越界 403。
        // 2026-09-25 单号列统一：sort/order 表头排序 + billNo 订货单号表头值筛选。
        return service.expectations(page, size, orderType, keyword, supplierId,
                warehouseScopes.current(scopeWarehouseId), sort, order, billNo);
    }

    /** 预计到货 facets（2026-09-25 单号列统一）：{billNo:[各订货单号]}——
     *  同列表过滤口径（不含 billNo 自身值筛选）。 */
    @GetMapping("/expectations/facets")
    public Map<String, List<Map<String, Object>>> expectationFacets(
            @RequestParam(defaultValue = "") String orderType,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.expectationFacets(orderType, keyword, supplierId,
                warehouseScopes.current(scopeWarehouseId));
    }

    /**
     * 预计到货待办数(徽章来源 warehouseInboundExpectation): count = 合计, PURCHASE / SUBCONTRACT = 分来源
     * (入库任务中心「采购入库 / 委外入库」分段与列表里的类型筛选卡都读这两个事实数)。与列表同一过滤基座
     * 与仓库范围(ADR-149), 一条 SQL 按订货类型分组, 合计 = 两类之和; 不再另开 type-counts 端点。
     */
    @GetMapping("/expectations/count")
    public Map<String, Long> expectationCount(@RequestParam(required = false) UUID scopeWarehouseId) {
        Map<String, Long> byType = service.countExpectationsByType(warehouseScopes.current(scopeWarehouseId));
        long purchase = byType.getOrDefault(ProcurementArrivalControlPort.PURCHASE, 0L);
        long subcontract = byType.getOrDefault(ProcurementArrivalControlPort.SUBCONTRACT, 0L);
        Map<String, Long> counts = new java.util.LinkedHashMap<>();
        counts.put("count", purchase + subcontract);
        counts.put(ProcurementArrivalControlPort.PURCHASE, purchase);
        counts.put(ProcurementArrivalControlPort.SUBCONTRACT, subcontract);
        return counts;
    }

    @GetMapping("/arrival-exceptions")
    public PageResponse<ArrivalExceptionTask> arrivalExceptions(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String keyword,
            @RequestParam(name = "history", defaultValue = "false") boolean includeHistory,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) UUID scopeWarehouseId,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String receiptBillNo,
            @RequestParam(required = false) String orderBillNo) {
        // 2026-09-25 单号列统一：sort/order 表头排序 + 收货单号/订货单号表头值筛选。
        return service.warehouseExceptions(page, size, keyword, includeHistory,
                supplierId, warehouseId, status,
                warehouseScopes.current(scopeWarehouseId),
                sort, order, receiptBillNo, orderBillNo);
    }

    /** 到货异常 facets（2026-09-25 单号列统一）：{receiptBillNo/orderBillNo:[各单号]}——
     *  同列表过滤口径（不含单号列自身值筛选）。 */
    @GetMapping("/arrival-exceptions/facets")
    public Map<String, List<Map<String, Object>>> arrivalExceptionFacets(
            @RequestParam(required = false) String keyword,
            @RequestParam(name = "history", defaultValue = "false") boolean includeHistory,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.warehouseExceptionFacets(keyword, includeHistory,
                supplierId, warehouseId, status,
                warehouseScopes.current(scopeWarehouseId));
    }

    /** 到货异常待办数(徽章来源 warehouseArrivalException): 与列表同一仓库范围(ADR-149)。 */
    @GetMapping("/arrival-exceptions/count")
    public Map<String, Long> arrivalExceptionCount(@RequestParam(required = false) UUID scopeWarehouseId) {
        return Map.of("count", service.countWarehouseExceptions(warehouseScopes.current(scopeWarehouseId)));
    }

    /**
     * 登记实际到货的唯一页面命令(ADR-151 §5)：单张 = 1 个来源、多选 = N 个来源，一个事务；
     * 服务端按「订货单 x 入库仓库」分组建收货单(登记 + 送检审核一步完成)，逐组结果含超量隔离
     * (EXCESS_QUARANTINED：草稿已建、未入库未立应付，等待财务定案)。币种/汇率/结算方式由服务端按
     * 来源订货单权威回填，仓库只登记数量与库位；建单/审核统一通过收货单 Service 的仓库专用网关，
     * 以 {@code warehouse_inbound:stock_in} 精确收口。原单张端点 POST /arrivals 已删除。
     */
    @PostMapping("/arrivals/batch")
    @PreAuthorize("hasAuthority('warehouse_inbound:view') and hasAuthority('warehouse_inbound:stock_in')")
    public ProcurementArrivalContracts.WarehouseArrivalBatchRegisterResult registerArrivalBatch(
            @Valid @RequestBody ProcurementArrivalContracts.WarehouseArrivalBatchRegisterRequest request) {
        return arrivalRegistration.registerBatch(request);
    }

    /**
     * 登记页按来源身份读取预计到货(?ids=)：页面路由只带身份，刷新/草稿恢复都能重新拿到同一批任务，
     * 不再依赖页面跳转时塞进去的内存对象；与列表同一投影、同一可见范围。
     */
    @GetMapping("/expectations/by-ids")
    public List<InboundExpectationTask> expectationsByIds(@RequestParam List<UUID> ids) {
        return service.expectationsByIds(ids);
    }

    /**
     * 完成中断的到货登记（断点恢复）：草稿收货单一键「继续送检」——服务端先按来源
     * 订货单权威修复表头币族（老草稿），再走同一审核链路；仓库不进采购/委外单据页。
     * 审核统一通过收货单 Service 的仓库专用网关，以
     * {@code warehouse_inbound:stock_in} 精确收口。
     */
    @PostMapping("/arrivals/{receiptId}/complete")
    @PreAuthorize("hasAuthority('warehouse_inbound:view') and hasAuthority('warehouse_inbound:stock_in')")
    public WarehouseArrivalRegisterResult completeArrival(
            @PathVariable UUID receiptId) {
        return arrivalRegistration.complete(receiptId);
    }

    /**
     * 预计到货「批量继续送检」：一个事务逐张完成中断的送检步骤（采购/委外草稿
     * 收货单混批均可）。单张超量隔离不回滚其他单；权限与单册「继续送检」一致。
     */
    @PostMapping("/arrivals/batch-complete")
    @PreAuthorize("hasAuthority('warehouse_inbound:view') and hasAuthority('warehouse_inbound:stock_in')")
    public WarehouseArrivalBatchCompleteResult completeArrivalBatch(
            @Valid @RequestBody WarehouseArrivalBatchCompleteRequest request) {
        return arrivalRegistration.completeBatch(request);
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
    @PostMapping("/arrival-exceptions/batch-stock-in")
    @PreAuthorize("hasAuthority('warehouse_inbound:view') and hasAuthority('warehouse_inbound:stock_in')")
    public WarehouseArrivalExceptionBatchStockInResult stockInAcceptedBatch(
            @Valid @RequestBody WarehouseArrivalExceptionBatchStockInRequest request) {
        return batchStockIn.stockInBatch(request);
    }

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
