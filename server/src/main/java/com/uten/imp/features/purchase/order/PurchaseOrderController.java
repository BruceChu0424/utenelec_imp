package com.uten.imp.features.purchase.order;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.RequestUuidSets;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts;
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
            @RequestParam(required = false) String financeApproval,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new OrderQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, financeApproval), page, size, sort, order);
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
     * 货品 → 主档默认条款 (新建单行级预填)。路径沿用 /last-terms (前端在用), 语义自
     * V593 起已是主档默认值: goods.default_supplier_id → 供应商主档条款 → 货品默认采购单价,
     * 不再按最近一张订货单推导。goodsIds 为逗号分隔的货品 UUID, 返回
     * {goodsId: {supplierId, settlementMethodId, currencyId, exchangeRate, taxRate, purchasePrice}}。
     */
    @GetMapping("/last-terms")
    @PreAuthorize("hasAuthority('purchase_order:view')")
    public java.util.Map<String, PurchaseOrderService.MasterDefaultTermsPerGoods> masterDefaultTerms(
            @RequestParam String goodsIds) {
        java.util.Set<UUID> ids = RequestUuidSets.commaSeparated(goodsIds, "货品 ID");
        java.util.Map<String, PurchaseOrderService.MasterDefaultTermsPerGoods> result =
                new java.util.LinkedHashMap<>();
        service.masterDefaultTermsPerGoods(ids).forEach((k, v) -> result.put(k.toString(), v));
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

    /** 取消草稿订货单（含在审：同步撤回财务审批任务与弹卡）。 */
    @PostMapping("/{id}/cancel")
    @PreAuthorize("hasAuthority('purchase_order:cancel')")
    public OrderDetail cancel(@PathVariable UUID id) {
        return service.cancel(id);
    }

    @PostMapping("/{id}/submit-finance")
    @PreAuthorize("hasAuthority('purchase_order:submit_finance')")
    public OrderDetail submitFinance(@PathVariable UUID id) {
        financeApproval.submit("PURCHASE", id);
        return service.detail(id);
    }

    /**
     * V486 财务批准后受控改量：立即生效并自动开财务复核 case（对齐销售 V482）。
     */
    @PostMapping("/{id}/change-qty")
    @PreAuthorize("hasAuthority('purchase_order:change_qty')")
    public OrderDetail changeQty(
            @PathVariable UUID id,
            @Valid @RequestBody
            ProcurementApprovalContracts.OrderQtyChangeRequest request) {
        return service.changeQty(id, request);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('purchase_order:reverse')")
    public OrderDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    // 单笔审批入口已停用（批量任务中心是唯一权威通道），但**路由必须留着且继续
    // 按动作权限把门**：已发版的旧客户端仍会打到这两个路径，去掉路由等于让它们
    // 落到 404/405 而不是「请到任务中心处理」的明确冲突；权限注解也必须留，
    // DocumentActionPermissionContractTest#legacySingleRoutesStayActionGated...
    // 逐条断言它们的 @PreAuthorize 仍是 finance_order_approval 的精确动作权限。
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

    private static ApiException legacySingleDecisionDisabled() {
        return new ApiException(
                ErrorCode.CONFLICT,
                "单笔订货审批入口已停用，请到财务→订货审批任务中心处理");
    }
}
