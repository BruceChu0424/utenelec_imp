package com.uten.imp.features.sales.other_shipment;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentDetail;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentListItem;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentQueryFilter;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentSaveRequest;
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
 * 历史其它出货查询与受控反向。旧写端点明确拒绝；新客户零星发货走统一 shipments 工作流。
 */
@RestController
@RequestMapping("/api/sales/other-shipments")
@RequiredArgsConstructor
public class SalesOtherShipmentController {

    private final SalesOtherShipmentService service;
    private final AuditDetailViewRecorder viewAudit;

    @GetMapping
    @PreAuthorize("hasAuthority('sales_other_shipment:view')")
    public PageResponse<OtherShipmentListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) String outType,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new OtherShipmentQueryFilter(keyword, clientId, warehouseId, outType, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_other_shipment:view')")
    public OtherShipmentDetail detail(@PathVariable UUID id) {
        OtherShipmentDetail detail = service.detail(id);
        viewAudit.record(
                "view_sales_other_shipment_detail", "sales_other_shipments", id,
                detail.getBillNo(), detail.getLegacyId(), "其它出货单");
        return detail;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('sales_other_shipment:create')")
    public OtherShipmentDetail create(@Valid @RequestBody OtherShipmentSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_other_shipment:edit')")
    public OtherShipmentDetail update(@PathVariable UUID id, @Valid @RequestBody OtherShipmentSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_other_shipment:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('sales_other_shipment:approve')")
    public OtherShipmentDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_other_shipment:reverse')")
    public OtherShipmentDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
