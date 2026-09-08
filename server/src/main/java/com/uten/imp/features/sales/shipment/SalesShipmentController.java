package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentListItem;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
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
 * 销售出货单 API（销售管理）。
 *
 * - GET    /api/sales/shipments               → 分页
 * - GET    /api/sales/shipments/{id}          → 详情
 * - POST   /api/sales/shipments               → 新建 sales_shipment:create
 * - PUT    /api/sales/shipments/{id}          → 编辑（仅草稿）
 * - DELETE /api/sales/shipments/{id}          → 删除
 * - POST   /api/sales/shipments/{id}/approve  → 审核（库存出库 + 回写订货 + 立应收 + 结案）
 * - POST   /api/sales/shipments/{id}/reverse  → 红冲（先校验收款核销 → 反向）
 */
@RestController
@RequestMapping("/api/sales/shipments")
@RequiredArgsConstructor
public class SalesShipmentController {

    private final SalesShipmentService service;
    private final AuditDetailViewRecorder viewAudit;

    @GetMapping("/pending-finance-count")
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public java.util.Map<String,Long> pendingFinanceCount() { return java.util.Map.of("count",service.countPendingFinanceAudit()); }

    @GetMapping
    @PreAuthorize("hasAnyAuthority('sales_shipment:view','sales_other_shipment:view','finance_shipment_audit','sales_shipment:warehouse-work')")
    public PageResponse<ShipmentListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) Boolean arPosted,
            @RequestParam(required = false) Short financeAudit,
            @RequestParam(required = false) String warehouseWorkStatus,
            @RequestParam(required = false) String shipmentKind,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new ShipmentQueryFilter(
                keyword, clientId, warehouseId, status, arPosted, financeAudit,
                warehouseWorkStatus,
                dateFrom, dateTo,shipmentKind), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('sales_shipment:view','sales_other_shipment:view','finance_shipment_audit','sales_shipment:warehouse-work')")
    public ShipmentDetail detail(@PathVariable UUID id) {
        ShipmentDetail detail = service.detail(id);
        viewAudit.record(
                "view_sales_shipment_detail", "sales_shipments", id,
                detail.getBillNo(), detail.getLegacyId(), "销售出货单");
        return detail;
    }

    @PostMapping
    @PreAuthorize("hasAnyAuthority('sales_shipment:create','sales_other_shipment:create')")
    public ShipmentDetail create(@Valid @RequestBody ShipmentSaveRequest req) {
        return service.create(req);
    }

    /** 批量发货开单（SOP §一9）：勾选可发行+本次数量，同客户且同归属人合并一张草稿。 */
    @PostMapping("/batch")
    @PreAuthorize("hasAuthority('sales_shipment:create')")
    public List<ShipmentDetail> batchCreate(
            @Valid @RequestBody com.uten.imp.features.sales.shipment.dto.BatchShipRequest req) {
        return service.batchCreate(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('sales_shipment:edit','sales_other_shipment:edit')")
    public ShipmentDetail update(@PathVariable UUID id, @Valid @RequestBody ShipmentSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('sales_shipment:delete','sales_other_shipment:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/confirm-sales")
    @PreAuthorize("hasAnyAuthority('sales_shipment:approve','sales_other_shipment:approve')")
    public ShipmentDetail confirmSales(@PathVariable UUID id,@RequestParam Long expectedRevision) {
        return service.confirmSales(id,expectedRevision);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('sales_shipment:approve')")
    public ShipmentDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_shipment:reverse')")
    public ShipmentDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /** 仓库驳回（备货异常）：释放预留 + 订单行回退待排产。 */
    @PostMapping("/{id}/reject")
    @PreAuthorize("hasAuthority('sales_shipment:reject')")
    public ShipmentDetail reject(@PathVariable UUID id, @RequestParam(required = false) String reason) {
        return service.reject(id, reason);
    }

    @PostMapping("/{id}/warehouse-work")
    @PreAuthorize("hasAuthority('sales_shipment:warehouse-work')")
    public ShipmentDetail transitionWarehouseWork(
            @PathVariable UUID id,
            @Valid @RequestBody
            com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest req) {
        return service.transitionWarehouseWork(id, req);
    }

    /** 财务审核前只读核对：客户货款类型、结算方式、应收、铺底和超出铺底额。 */
    @GetMapping("/{id}/finance-audit-info")
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public java.util.Map<String, Object> financeAuditInfo(@PathVariable UUID id) {
        return service.financeAuditInfo(id);
    }

    /** 所有客户出货均须先财务放行，之后仓库才收到待拣货通知。 */
    @PostMapping("/{id}/finance-audit")
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public java.util.Map<String, Object> financeAudit(@PathVariable UUID id,
            @Valid @RequestBody(required=false) com.uten.imp.features.sales.shipment.dto.ShipmentFinanceDecisionRequest request) {
        return service.financeAudit(id,request);
    }

    @PostMapping("/{id}/finance-audit-reject")
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public java.util.Map<String,Object> financeAuditReject(@PathVariable UUID id,
            @Valid @RequestBody com.uten.imp.features.sales.shipment.dto.ShipmentFinanceDecisionRequest request) {
        return service.financeAuditReject(id,request);
    }

    /** 财务反审（仅仓库开始拣货前且当前已财审的单据）。 */
    @PostMapping("/{id}/finance-audit-reverse")
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public java.util.Map<String, Object> financeAuditReverse(@PathVariable UUID id) {
        return service.financeAuditReverse(id);
    }
}
