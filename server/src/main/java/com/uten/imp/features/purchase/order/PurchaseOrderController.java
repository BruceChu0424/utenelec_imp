package com.uten.imp.features.purchase.order;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.RequestUuidSets;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderListItem;
import com.uten.imp.features.purchase.order.dto.OrderQueryFilter;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 采购订货单业务 API：采购从计划申请生成草稿并提交财务，本 Controller
 * 不再执行财务决定。正式批准/驳回只走财务任务中心的 case-bound batch 协议；
 * 历史单笔映射仅为旧客户端返回明确 fail-closed 错误。
 */
@RestController
@RequestMapping("/api/purchase/orders")
@RequiredArgsConstructor
public class PurchaseOrderController {

    private final PurchaseOrderService service;
    private final ProcurementFinanceApprovalService financeApproval;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('purchase_order:view')")
    public PageResponse<OrderListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new OrderQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('purchase_order:view','finance_order_approval:view')")
    public OrderDetail detail(@PathVariable UUID id) {
        OrderDetail result = service.detail(id);
        auditViews.record(
                "view_purchase_order_detail",
                "purchase_orders",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "采购订货单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('purchase_order:create') and hasAuthority('purchase_order:decompose')")
    public OrderDetail create(@Valid @RequestBody OrderSaveRequest req) {
        return service.create(req);
    }

    /** 按明细级供应商自动拆单创建（一单一商归集不变），返回生成的多张订货单明细。 */
    @PostMapping("/batch")
    @PreAuthorize("hasAuthority('purchase_order:create') and hasAuthority('purchase_order:decompose')")
    public java.util.Map<String, Object> createBatch(@Valid @RequestBody OrderSaveRequest req) {
        return java.util.Map.of("items", service.createBatch(req));
    }

    /**
     * 货品 → 最近一次订货供应商（订货编辑页行级供应商「学习预填」：选货品后自动带出
     * 上次该货品的订货供应商）。goodsIds 为逗号分隔的货品 UUID，返回 {goodsId: supplierId}。
     *
     * @deprecated 2026-09 行级商业条款改造起由 /last-terms 取代（同一次查询带回整套条款）；
     *     保留一个发布周期兼容已发版的旧客户端。
     */
    @Deprecated(since = "2026-09-03")
    @GetMapping("/last-suppliers")
    @PreAuthorize("hasAuthority('purchase_order:view')")
    public java.util.Map<String, UUID> lastSuppliers(@RequestParam String goodsIds) {
        java.util.Set<UUID> ids = RequestUuidSets.commaSeparated(goodsIds, "货品 ID");
        java.util.Map<String, UUID> result = new java.util.LinkedHashMap<>();
        service.lastSuppliersPerGoods(ids).forEach((k, v) -> result.put(k.toString(), v));
        return result;
    }

    /**
     * 货品 → 最近一次订货商业条款（行级条款「学习预填」：同一货品下次建单自动带出
     * 上次的供应商/结账方式/币种/汇率/税率）。goodsIds 为逗号分隔的货品 UUID，
     * 返回 {goodsId: {supplierId, settlementMethodId, currencyId, exchangeRate, taxRate}}。
     */
    @GetMapping("/last-terms")
    @PreAuthorize("hasAuthority('purchase_order:view')")
    public java.util.Map<String, PurchaseOrderService.LastTermsPerGoods> lastTerms(
            @RequestParam String goodsIds) {
        java.util.Set<UUID> ids = RequestUuidSets.commaSeparated(goodsIds, "货品 ID");
        java.util.Map<String, PurchaseOrderService.LastTermsPerGoods> result =
                new java.util.LinkedHashMap<>();
        service.lastTermsPerGoods(ids).forEach((k, v) -> result.put(k.toString(), v));
        return result;
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('purchase_order:edit')")
    public OrderDetail update(@PathVariable UUID id, @Valid @RequestBody OrderSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('purchase_order:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/submit-finance")
    @PreAuthorize("hasAuthority('purchase_order:submit_finance')")
    public OrderDetail submitFinance(@PathVariable UUID id) {
        financeApproval.submit("PURCHASE", id);
        return service.detail(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_order_approval:approve')")
    @Deprecated(since = "2026-08-30", forRemoval = true)
    public void approve(@PathVariable("id") UUID ignoredId) {
        throw legacySingleDecisionDisabled();
    }

    @PostMapping("/{id}/reject")
    @PreAuthorize("hasAuthority('finance_order_approval:reject')")
    @Deprecated(since = "2026-08-30", forRemoval = true)
    public void reject(@PathVariable("id") UUID ignoredId) {
        throw legacySingleDecisionDisabled();
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('purchase_order:reverse')")
    public OrderDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    private static ApiException legacySingleDecisionDisabled() {
        return new ApiException(
                ErrorCode.CONFLICT,
                "单笔订货审批入口已停用，请到财务→订货审批任务中心处理");
    }
}
