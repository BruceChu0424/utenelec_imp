package com.uten.imp.features.payroll;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.payroll.dto.PayrollBatchCreateRequest;
import com.uten.imp.features.payroll.dto.PayrollBatchDto;
import com.uten.imp.features.payroll.dto.PayrollPdf;
import com.uten.imp.features.payroll.dto.PayrollRejectRequest;
import com.uten.imp.features.payroll.dto.PayrollSlipDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** 工资接口（/api/payroll）：批次生成→提交→复核→通过/驳回→发布；员工自助查看/下载已发布工资条。 */
@RestController
@RequestMapping("/api/payroll")
@RequiredArgsConstructor
public class PayrollController {

    private final PayrollService service;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping("/slips")
    @PreAuthorize("hasAnyAuthority('payroll:view:self','payroll:view:all')")
    public PageResponse<PayrollSlipDto> listSlips(
            @RequestParam(required = false) String status,
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listSlips(status, year, month, departmentId, page, size);
    }

    @GetMapping("/slips/{id}")
    @PreAuthorize("hasAnyAuthority('payroll:view:self','payroll:view:all')")
    public PayrollSlipDto slip(@PathVariable UUID id) {
        PayrollSlipDto result = service.getSlip(id);
        String period = result.year() + "年" + result.month() + "月";
        String displayName = result.employeeCode() == null
                || result.employeeCode().isBlank()
                ? period
                : result.employeeCode() + " · " + period;
        detailViewAudit.record(
                "view_payroll_slip_detail",
                "payroll_slips",
                id,
                displayName,
                null,
                "工资条");
        return result;
    }

    @PostMapping("/slips/{id}/view")
    @PreAuthorize("hasAuthority('payroll:view:self')")
    public PayrollSlipDto markViewed(@PathVariable UUID id) {
        return service.markViewed(id);
    }

    @PostMapping("/slips/{id}/download")
    @PreAuthorize("hasAnyAuthority('payroll:view:self','payroll:export')")
    public ResponseEntity<byte[]> download(@PathVariable UUID id) {
        PayrollPdf pdf = service.downloadSlip(id);
        AuthUser actor = currentUser.get()
                .orElseThrow(() -> new IllegalStateException("未登录"));
        // Only the operation identity and slip UUID are recorded. PDF bytes,
        // password-equivalent data, filenames and payroll PII never enter audit.
        audit.logExplicit(
                actor.getId(),
                actor.getLoginAccount(),
                "download_payroll_slip",
                "payroll_slips",
                id.toString(),
                "success");
        return ResponseEntity.ok()
                .contentType(MediaType.APPLICATION_PDF)
                .header(
                        "Content-Disposition",
                        DownloadContentDisposition.attachment(pdf.filename()))
                .body(pdf.bytes());
    }

    @GetMapping("/batches")
    @PreAuthorize("""
            hasAnyAuthority(
                'payroll:generate','payroll:review','payroll:publish','payroll:view:all'
            )
            """)
    public PageResponse<PayrollBatchDto> listBatches(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listBatches(year, month, status, departmentId, page, size);
    }

    @GetMapping("/batches/{id}")
    @PreAuthorize("""
            hasAnyAuthority(
                'payroll:generate','payroll:review','payroll:publish','payroll:view:all'
            )
            """)
    public PayrollBatchDto batch(@PathVariable UUID id) {
        PayrollBatchDto result = service.getBatch(id);
        String period = result.year() + "年" + result.month() + "月";
        String displayName = result.departmentName() == null
                || result.departmentName().isBlank()
                ? period
                : result.departmentName() + " · " + period;
        detailViewAudit.record(
                "view_payroll_batch_detail",
                "payroll_batches",
                id,
                displayName,
                null,
                "工资批次");
        return result;
    }

    @PostMapping("/batches")
    @PreAuthorize("hasAuthority('payroll:generate')")
    public PayrollBatchDto createBatch(@Valid @RequestBody PayrollBatchCreateRequest request) {
        return service.createBatch(request);
    }

    @PostMapping("/batches/{id}/submit")
    @PreAuthorize("hasAuthority('payroll:generate')")
    public PayrollBatchDto submit(@PathVariable UUID id) {
        return service.submitBatch(id);
    }

    @PostMapping("/batches/{id}/approve")
    @PreAuthorize("hasAuthority('payroll:review')")
    public PayrollBatchDto approve(@PathVariable UUID id) {
        return service.approveBatch(id);
    }

    @PostMapping("/batches/{id}/reject")
    @PreAuthorize("hasAuthority('payroll:review')")
    public PayrollBatchDto reject(@PathVariable UUID id,
                                  @Valid @RequestBody PayrollRejectRequest request) {
        return service.rejectBatch(id, request.reason());
    }

    @PostMapping("/batches/{id}/publish")
    @PreAuthorize("hasAuthority('payroll:publish')")
    public PayrollBatchDto publish(@PathVariable UUID id) {
        return service.publishBatch(id);
    }
}
