package com.uten.imp.features.subcontract.order;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.RequestUuidSets;
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
 * 委外订货单业务 API：委外从计划申请生成草稿并提交财务，本 Controller
 * 不再执行财务决定。正式批准/驳回只走财务任务中心的 case-bound batch 协议；
 * 历史单笔映射仅为旧客户端返回明确 fail-closed 错误。
 */
@RestController
@RequestMapping("/api/subcontract/orders")
@RequiredArgsConstructor
public class SubcontractOrderController {

    private final SubcontractOrderService service;
    private final ProcurementFinanceApprovalService financeApproval;
    private final SubcontractOrderProgressService progressService;
    private final AuditDetailViewRecorder auditViews;

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
    @PreAuthorize("hasAnyAuthority('subcontract_order:view','finance_order_approval:view')")
    public OrderDetail detail(@PathVariable UUID id) {
        OrderDetail result = service.detail(id);
        auditViews.record(
                "view_subcontract_order_detail",
                "subcontract_orders",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "委外订货单");
        return result;
    }

    /** BOM 成本子表只读（design doc 22 §五：本期不展开，仅查迁老库的原样数据）。 */
    @GetMapping("/{id}/cost-items")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public List<OrderCostItemDto> costItems(@PathVariable UUID id) {
        return service.listCostItems(id);
    }

    /** 全链路进度（V304）：财务审批 → 发料计划/出仓单 → 进仓/IQC → 退货/损耗 → 应付摘要。 */
    @GetMapping("/{id}/progress")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.OrderProgress progress(
            @PathVariable UUID id) {
        return progressService.progress(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_order:create')")
    public OrderDetail create(@Valid @RequestBody OrderSaveRequest req) {
        return service.create(req);
    }

    /** 按明细级委外商自动拆单创建（一单一商归集不变），返回生成的多张订货单明细。 */
    @PostMapping("/batch")
    @PreAuthorize("hasAuthority('subcontract_order:create')")
    public java.util.Map<String, Object> createBatch(@Valid @RequestBody OrderSaveRequest req) {
        return java.util.Map.of("items", service.createBatch(req));
    }

    /**
     * 货品 → 最近一次委外订货供应商（订货编辑页行级委外商「学习预填」：选货品后自动
     * 带出上次该货品的委外供应商）。goodsIds 为逗号分隔的货品 UUID，返回 {goodsId: supplierId}。
     */
    @GetMapping("/last-suppliers")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public java.util.Map<String, UUID> lastSuppliers(@RequestParam String goodsIds) {
        java.util.Set<UUID> ids = RequestUuidSets.commaSeparated(goodsIds, "货品 ID");
        java.util.Map<String, UUID> result = new java.util.LinkedHashMap<>();
        service.lastSuppliersPerGoods(ids).forEach((k, v) -> result.put(k.toString(), v));
        return result;
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail update(@PathVariable UUID id, @Valid @RequestBody OrderSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:delete')")
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
    @PreAuthorize("hasAuthority('subcontract_order:reverse')")
    public OrderDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    private static ApiException legacySingleDecisionDisabled() {
        return new ApiException(
                ErrorCode.CONFLICT,
                "单笔订货审批入口已停用，请到财务→订货审批任务中心处理");
    }
}
