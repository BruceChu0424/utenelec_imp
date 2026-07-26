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
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new ShipmentQueryFilter(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo), page, size);
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
}
