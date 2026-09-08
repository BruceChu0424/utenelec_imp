package com.uten.imp.features.purchase.request;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.purchase.request.dto.DecompositionPreviewItem;
import com.uten.imp.features.purchase.request.dto.DecompositionPreviewRequest;
import com.uten.imp.features.purchase.request.dto.RequestDetail;
import com.uten.imp.features.purchase.request.dto.RequestListItem;
import com.uten.imp.features.purchase.request.dto.RequestQueryFilter;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 采购申请只读 API：计划下达需求，采购仅查看并分解为订货单。 */
@RestController
@RequestMapping("/api/purchase/requests")
@RequiredArgsConstructor
public class PurchaseRequestController {

    private final PurchaseRequestService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('purchase_request:view')")
    public PageResponse<RequestListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new RequestQueryFilter(keyword, warehouseId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('purchase_request:view')")
    public RequestDetail detail(@PathVariable UUID id) {
        RequestDetail result = service.detail(id);
        auditViews.record(
                "view_purchase_request_detail",
                "purchase_requests",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "采购申请单");
        return result;
    }

    @PostMapping("/decomposition-preview")
    @PreAuthorize("hasAuthority('purchase_request:view') and hasAuthority('purchase_order:decompose')")
    public List<DecompositionPreviewItem> decompositionPreview(
            @Valid @RequestBody DecompositionPreviewRequest req) {
        return service.decompositionPreview(req.itemIds());
    }

    /**
     * V477：分解前的明细数量修正（计划来源申请唯一 sanctioned 写入口；
     * 已订货/待财务审核占用的明细拒绝修改，见 Service 注释）。
     */
    @PutMapping("/{id}/items/{itemId}/qty")
    @PreAuthorize("hasAuthority('purchase_request:view') and hasAuthority('purchase_order:decompose')")
    public RequestDetail adjustItemQty(
            @PathVariable UUID id,
            @PathVariable UUID itemId,
            @Valid @RequestBody ItemQtyAdjustRequest req) {
        return service.adjustItemQty(id, itemId, req.qty());
    }

    /** 数量修正请求体。 */
    public record ItemQtyAdjustRequest(java.math.BigDecimal qty) {
    }
}
