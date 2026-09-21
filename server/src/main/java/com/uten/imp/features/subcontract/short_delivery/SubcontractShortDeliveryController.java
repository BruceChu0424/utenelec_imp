package com.uten.imp.features.subcontract.short_delivery;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseDetail;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseRow;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.Counts;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.SupplierLossSummary;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

/**
 * ADR-098 委外回厂短交判定页 + 供应商损耗汇总。
 *
 * <ul>
 *   <li>GET  /api/subcontract/short-deliveries?segment=PENDING|WAITING|HISTORY 列表(对象级读范围)</li>
 *   <li>GET  /api/subcontract/short-deliveries/count 分段计数(hub 卡片同数展示)</li>
 *   <li>GET  /api/subcontract/short-deliveries/{id} 详情 + 事件</li>
 *   <li>POST /api/subcontract/short-deliveries/{id}/decide 判定(独立权限 subcontract_short_delivery:decide)</li>
 *   <li>GET  /api/subcontract/short-deliveries/supplier-summary?supplierId= 供应商损耗汇总</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/subcontract/short-deliveries")
@RequiredArgsConstructor
public class SubcontractShortDeliveryController {

    private final SubcontractShortDeliveryService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public PageResponse<CaseRow> list(
            @RequestParam(defaultValue = "PENDING") String segment,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID orderId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.list(segment, keyword, supplierId, orderId, dateFrom, dateTo, page, size);
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public Counts count() {
        return service.counts();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public CaseDetail detail(@PathVariable UUID id) {
        CaseDetail result = service.detail(id);
        auditViews.record(
                "view_subcontract_short_delivery_detail",
                "subcontract_short_delivery_cases",
                id,
                result.row() == null ? null : result.row().orderBillNo(),
                null,
                "委外回厂短交案件");
        return result;
    }

    @PostMapping("/{id}/decide")
    @PreAuthorize("hasAuthority('subcontract_order:view') and hasAuthority('subcontract_short_delivery:decide')")
    public CaseDetail decide(@PathVariable UUID id, @Valid @RequestBody DecisionRequest request) {
        return service.decide(id, request);
    }

    @GetMapping("/supplier-summary")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public SupplierLossSummary supplierSummary(@RequestParam UUID supplierId) {
        return service.supplierSummary(supplierId);
    }
}
