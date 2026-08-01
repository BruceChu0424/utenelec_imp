package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.PageResponse;
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
 * - POST   /api/sales/shipments               → 新建 sales_shipment:edit
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

    @GetMapping
    @PreAuthorize("hasAuthority('sales_shipment:view')")
    public PageResponse<ShipmentListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) Boolean arPosted,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new ShipmentQueryFilter(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_shipment:view')")
    public ShipmentDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail create(@Valid @RequestBody ShipmentSaveRequest req) {
        return service.create(req);
    }

    /** 批量发货开单（SOP §一9）：勾选可发行+本次数量，同客户且同归属人合并一张草稿。 */
    @PostMapping("/batch")
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public List<ShipmentDetail> batchCreate(
            @Valid @RequestBody com.uten.imp.features.sales.shipment.dto.BatchShipRequest req) {
        return service.batchCreate(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail update(@PathVariable UUID id, @Valid @RequestBody ShipmentSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /** 仓库驳回（备货异常）：释放预留 + 订单行回退待排产（V96）。 */
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

    /** C6 财务审核发货：现金结算客户须审后仓库才可审核出货；返回结算方式+未收余额辅助核对。 */
    @PostMapping("/{id}/finance-audit")
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public java.util.Map<String, Object> financeAudit(@PathVariable UUID id) {
        return service.financeAudit(id);
    }

    /** C6 财务反审（仅未审核出货的单据）。 */
    @PostMapping("/{id}/finance-audit-reverse")
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public java.util.Map<String, Object> financeAuditReverse(@PathVariable UUID id) {
        return service.financeAuditReverse(id);
    }
}
