package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.ApprovalDecisionRequest;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.RejectionDecisionRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.order.dto.OrderCostItemDto;
import com.uten.imp.features.subcontract.order.dto.OrderDetail;
import com.uten.imp.features.subcontract.order.dto.OrderListItem;
import com.uten.imp.features.subcontract.order.dto.OrderQueryFilter;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
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
import java.util.List;
import java.util.UUID;

/**
 * 委外订货单 API。委外部门从计划申请明细生成草稿并提交财务；只有当前精确
 * 财务负责人可批准/驳回。批准是唯一 0→1 生效点，会回写申请已订量并生成
 * 仓库预计到货任务；订货批准本身不入库存或应付。
 */
@RestController
@RequestMapping("/api/subcontract/orders")
@RequiredArgsConstructor
public class SubcontractOrderController {

    private final SubcontractOrderService service;
    private final ProcurementFinanceApprovalService financeApproval;
    private final SubcontractOrderFinanceDecisionCommandService financeDecision;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public PageResponse<OrderListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) Boolean closed,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new OrderQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, closed), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public OrderDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    /** BOM 成本子表只读（design doc 22 §五：本期不展开，仅查迁老库的原样数据）。 */
    @GetMapping("/{id}/cost-items")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public List<OrderCostItemDto> costItems(@PathVariable UUID id) {
        return service.listCostItems(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail create(@Valid @RequestBody OrderSaveRequest req) {
        return service.create(req);
    }

    /** 按明细级委外商自动拆单创建（一单一商归集不变），返回生成的多张订货单明细。 */
    @PostMapping("/batch")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public java.util.Map<String, Object> createBatch(@Valid @RequestBody OrderSaveRequest req) {
        return java.util.Map.of("items", service.createBatch(req));
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail update(@PathVariable UUID id, @Valid @RequestBody OrderSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/submit-finance")
    @PreAuthorize("hasAuthority('subcontract_order:submit_finance')")
    public OrderDetail submitFinance(@PathVariable UUID id) {
        financeApproval.submit("SUBCONTRACT", id);
        return service.detail(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_order_approval:review')")
    public OrderDetail approve(
            @PathVariable UUID id,
            @Valid @RequestBody ApprovalDecisionRequest request) {
        return financeDecision.approve(id, request.expectedVersion());
    }

    @PostMapping("/{id}/reject")
    @PreAuthorize("hasAuthority('finance_order_approval:review')")
    public OrderDetail reject(
            @PathVariable UUID id,
            @Valid @RequestBody RejectionDecisionRequest request) {
        return financeDecision.reject(
                id, request.expectedVersion(), request.reason());
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
