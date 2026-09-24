package com.uten.imp.features.production.dailyreport;

import com.uten.imp.audit.AuditDetailViewRecorder;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;
import static com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.*;

@RestController
@RequestMapping("/api/production/actual-output-supplements")
@RequiredArgsConstructor
public class ActualOutputSupplementController {
    private final ActualOutputSupplementService service;
    private final AuditDetailViewRecorder auditViews;
    @PostMapping("/preview")
    @PreAuthorize("hasAuthority('production_execution:view') and (hasAuthority('production_daily_report:create') or hasAuthority('production_plan:create'))")
    public Preview preview(@Valid @RequestBody PreviewRequest request){return service.preview(request);}
    @PostMapping("/preview-report")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_daily_report:create')")
    public ReportPreview previewReport(@Valid @RequestBody ReportPreviewRequest request){return service.previewReport(request);}
    @PostMapping
    @PreAuthorize("hasAuthority('production_execution:view') and (hasAuthority('production_plan:create') or (hasAuthority('production_execution:request_supplement_plan') and hasAuthority('production_daily_report:create')))")
    public View create(@Valid @RequestBody CreateRequest request){return service.create(request);}
    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_execution:view') or hasAuthority('production_plan:approve')")
    public View detail(@PathVariable UUID id){
        View result=service.detail(id);
        auditViews.record(
                "view_production_actual_output_supplement_detail",
                "production_actual_output_supplement_requests",
                id,
                result.planNo(),
                null,
                "实际产出追加计划");
        return result;
    }
    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public View approve(@PathVariable UUID id,@Valid @RequestBody ApproveRequest request){return service.approve(id,request);}
    @PostMapping("/{id}/cancel")
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public View cancel(@PathVariable UUID id,@Valid @RequestBody CancelRequest request){return service.cancel(id,request);}
}
