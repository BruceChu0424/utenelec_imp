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
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size) {
        return service.list(decision, keyword, from, to, page, size);
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
