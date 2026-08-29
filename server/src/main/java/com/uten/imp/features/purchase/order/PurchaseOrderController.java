package com.uten.imp.features.purchase.order;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.ApprovalDecisionRequest;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.RejectionDecisionRequest;
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
 * 采购订货单 API。采购从计划申请明细生成草稿并提交财务；只有财务审核组中
 * 持有对应动作权限的合格审核员可批准/驳回。批准是唯一 0→1 生效点，会回写申请已订量并生成
 * 仓库预计到货任务；订货批准本身不入库存。
 */
@RestController
@RequestMapping("/api/purchase/orders")
@RequiredArgsConstructor
public class PurchaseOrderController {

    private final PurchaseOrderService service;
    private final ProcurementFinanceApprovalService financeApproval;
    private final PurchaseOrderFinanceDecisionCommandService financeDecision;

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
        return service.detail(id);
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
    public OrderDetail approve(
            @PathVariable UUID id,
            @Valid @RequestBody ApprovalDecisionRequest request) {
        return financeDecision.approve(id, request.expectedVersion());
    }

    @PostMapping("/{id}/reject")
    @PreAuthorize("hasAuthority('finance_order_approval:reject')")
    public OrderDetail reject(
            @PathVariable UUID id,
            @Valid @RequestBody RejectionDecisionRequest request) {
        return financeDecision.reject(
                id, request.expectedVersion(), request.reason());
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('purchase_order:reverse')")
    public OrderDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
