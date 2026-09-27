package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionRecordContracts.InspectionDecisionRecord;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionRecordContracts.InspectionDecisionRecordPage;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Read-only IQC decision-event records. Existing pending/disposition APIs remain separate. */
@RestController
@RequestMapping("/api/procurement/inspection/records")
@RequiredArgsConstructor
public class ProcurementInspectionRecordController {

    private final ProcurementInspectionRecordQueryService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public InspectionDecisionRecordPage list(
            @RequestParam(defaultValue = "ALL") String decision,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
            OffsetDateTime from,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
            OffsetDateTime to,
            @RequestParam(required = false) String sourceType,
            @RequestParam(required = false) String effective,
            @RequestParam(required = false) String disposition,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size,
            // 2026-09-25 单号列统一：来源/关联单号表头排序 + 值筛选（精确匹配）。
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String sourceNo,
            @RequestParam(required = false) String referenceNo) {
        return service.list(decision, keyword, from, to, sourceType,
                effective, disposition, page, size, sort, order,
                sourceNo, referenceNo);
    }

    /**
     * 单号列 facets（2026-09-25 单号列统一）：{sourceNo/referenceNo/sheetNo:[…]}，
     * 与列表同一过滤参数（不含单号列自身的值筛选）；IQC 无检查单号，sheetNo 恒为空表。
     */
    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public Map<String, List<Map<String, Object>>> facets(
            @RequestParam(defaultValue = "ALL") String decision,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
            OffsetDateTime from,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
            OffsetDateTime to,
            @RequestParam(required = false) String sourceType,
            @RequestParam(required = false) String effective,
            @RequestParam(required = false) String disposition) {
        return service.facets(decision, keyword, from, to, sourceType,
                effective, disposition);
    }

    @GetMapping("/{recordId}")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public InspectionDecisionRecord detail(@PathVariable UUID recordId) {
        InspectionDecisionRecord result = service.detail(recordId);
        auditViews.record(
                "view_procurement_inspection_record_detail",
                "procurement_inspection_events",
                result.recordId(),
                result.sourceNo(),
                null,
                "IQC检测决定记录");
        return result;
    }
}
