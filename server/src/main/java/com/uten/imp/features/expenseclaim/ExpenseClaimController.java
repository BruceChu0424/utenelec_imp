package com.uten.imp.features.expenseclaim;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimBatchRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimBatchResultDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimCreateRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceCheckDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceInput;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimPaymentRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimRejectRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimSummaryDto;
import com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto;
import com.uten.imp.features.expenseclaim.ocr.InvoiceRecognitionService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.MediaType;
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
import org.springframework.web.multipart.MultipartFile;

import java.util.UUID;

/** 费用报销单接口（/api/expense-claims）。 */
@RestController
@RequestMapping("/api/expense-claims")
@RequiredArgsConstructor
public class ExpenseClaimController {

    private final ExpenseClaimService service;
    private final ExpenseClaimSettingsService settings;
    private final InvoiceRecognitionService recognition;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping("/mine")
    @PreAuthorize("hasAuthority('expense:apply')")
    public PageResponse<ExpenseClaimDto> mine(
            @RequestParam(required = false) String status,
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) String category,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listMine(status, year, month, departmentId, category, page, size);
    }

    @GetMapping("/pending")
    @PreAuthorize("hasAuthority('expense:approve')")
    public PageResponse<ExpenseClaimDto> pending(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) String category,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listPending(year, month, departmentId, category, page, size);
    }

    @GetMapping("/payable")
    @PreAuthorize("hasAuthority('expense:pay')")
    public PageResponse<ExpenseClaimDto> payable(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) String category,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listPayable(year, month, departmentId, category, page, size);
    }

    /**
     * 审批/打款队列表头筛选桶（部门/年月）。queue=pending|payable，权限与对应列表一致
     *（服务层按队列再校验 expense:approve / expense:pay）。
     */
    @GetMapping("/facets")
    @PreAuthorize("hasAnyAuthority('expense:approve','expense:pay')")
    public ExpenseClaimFacetsDto facets(@RequestParam String queue) {
        return service.facets(queue);
    }

    /** 队列汇总（V608 审批页统计卡）：两队列单数/金额 + 本月提交 + 本月打款。 */
    @GetMapping("/summary")
    @PreAuthorize("hasAnyAuthority('expense:approve','expense:pay')")
    public ExpenseClaimSummaryDto summary() {
        return service.summary();
    }

    /** 发票查重预检（登记表单即时提示）。 */
    @GetMapping("/invoices/check")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimInvoiceCheckDto checkInvoice(
            @RequestParam String invoiceNo,
            @RequestParam(required = false) String invoiceCode,
            @RequestParam(required = false) UUID excludeClaimId,
            @RequestParam(required=false) String invoiceType,@RequestParam(required=false) String sellerName) {
        return service.checkInvoiceDuplicate(invoiceNo, invoiceCode, excludeClaimId,invoiceType,sellerName);
    }

    /** 发票图片识别（OCR 预填；本地开源识别服务部署后 provider=paddle 启用，不接付费 AI API）。 */
    @PostMapping(value = "/invoices/recognize", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @PreAuthorize("hasAuthority('expense:apply')")
    public RecognizedInvoiceDto recognizeInvoice(
            @RequestParam("file") MultipartFile file) {
        return recognition.recognize(file);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('expense:apply','expense:approve','expense:pay')")
    public ExpenseClaimDto detail(@PathVariable UUID id) {
        ExpenseClaimDto result = service.detail(id);
        detailViewAudit.record(
                "view_expense_claim_detail",
                "expense_claims",
                id,
                result.title(),
                null,
                "费用报销单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto create(@Valid @RequestBody ExpenseClaimCreateRequest request) {
        return service.create(request);
    }

    /** 编辑（V608）：DRAFT/REJECTED 且本人；明细整组替换。 */
    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto edit(
            @PathVariable UUID id,
            @Valid @RequestBody ExpenseClaimCreateRequest request) {
        return service.editVersioned(id, request);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('expense:apply')")
    public void delete(@PathVariable UUID id, @RequestParam Long expectedVersion) {
        service.delete(id,expectedVersion);
    }

    @PostMapping("/{id}/submit")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto submit(@PathVariable UUID id, @Valid @RequestBody com.uten.imp.features.expenseclaim.dto.ExpenseClaimVersionRequest request) {
        return service.submit(id,request.expectedVersion());
    }

    @PostMapping("/{id}/withdraw")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto withdraw(@PathVariable UUID id, @Valid @RequestBody com.uten.imp.features.expenseclaim.dto.ExpenseClaimVersionRequest request) {
        return service.withdraw(id,request.expectedVersion());
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('expense:approve')")
    public ExpenseClaimDto approve(@PathVariable UUID id, @Valid @RequestBody com.uten.imp.features.expenseclaim.dto.ExpenseClaimVersionRequest request) {
        return service.approve(id,request.expectedVersion());
    }

    @PostMapping("/{id}/reject")
    @PreAuthorize("hasAuthority('expense:approve')")
    public ExpenseClaimDto reject(@PathVariable UUID id,
                                  @Valid @RequestBody ExpenseClaimRejectRequest request) {
        return service.reject(id, request.reason(), request.expectedVersion());
    }

    /** 批量通过（V608）：单事务全成全败（上限 50），替代前端逐单循环。 */
    @PostMapping("/approve-batch")
    @PreAuthorize("hasAuthority('expense:approve')")
    public ExpenseClaimBatchResultDto approveBatch(
            @Valid @RequestBody ExpenseClaimBatchRequest request) {
        return service.batchVersioned(request,true);
    }

    /** 批量驳回（V608）：统一原因必填，单事务全成全败。 */
    @PostMapping("/reject-batch")
    @PreAuthorize("hasAuthority('expense:approve')")
    public ExpenseClaimBatchResultDto rejectBatch(
            @Valid @RequestBody ExpenseClaimBatchRequest request) {
        return service.batchVersioned(request,false);
    }

    @PostMapping("/{id}/pay")
    @PreAuthorize("hasAuthority('expense:pay')")
    public ExpenseClaimDto pay(@PathVariable UUID id,
                               @Valid @RequestBody ExpenseClaimPaymentRequest request) {
        return service.payVersioned(id, request);
    }

    // ---- 发票登记（V608：DRAFT/REJECTED 本人维护，审批/打款侧只读） -----------------

    @PostMapping("/{id}/invoices")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto addInvoice(
            @PathVariable UUID id,
            @Valid @RequestBody ExpenseClaimInvoiceInput input) {
        return service.addInvoiceVersioned(id, input);
    }

    @PutMapping("/{id}/invoices/{invoiceId}")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto updateInvoice(
            @PathVariable UUID id,
            @PathVariable UUID invoiceId,
            @Valid @RequestBody ExpenseClaimInvoiceInput input) {
        return service.updateInvoiceVersioned(id, invoiceId, input);
    }

    @DeleteMapping("/{id}/invoices/{invoiceId}")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto deleteInvoice(
            @PathVariable UUID id,
            @PathVariable UUID invoiceId, @RequestParam Long expectedVersion) {
        return service.deleteInvoice(id, invoiceId, expectedVersion);
    }

    @GetMapping("/history")
    @PreAuthorize("hasAnyAuthority('expense:approve','expense:pay')")
    public PageResponse<ExpenseClaimDto> history(@RequestParam(required=false) Integer year,@RequestParam(required=false) Integer month,
            @RequestParam(required=false) UUID departmentId,@RequestParam(required=false) String category,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="20") int size) {
        return service.listHistory(year,month,departmentId,category,page,size);
    }
    @GetMapping("/counts")
    @PreAuthorize("hasAnyAuthority('expense:apply','expense:approve','expense:pay')")
    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimCountsDto counts() { return service.counts(); }
    @GetMapping("/settings")
    @PreAuthorize("hasAnyAuthority('expense:apply','expense:approve','expense:pay','expense:settings')")
    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimSettingsDto settings() { return settings.get(); }
    @PutMapping("/settings")
    @PreAuthorize("hasAuthority('expense:settings')")
    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimSettingsDto settings(@Valid @RequestBody com.uten.imp.features.expenseclaim.dto.ExpenseClaimSettingsDto input) { return settings.update(input); }
    @PostMapping("/{id}/invoices/{invoiceId}/verify")
    @PreAuthorize("hasAuthority('expense:approve')")
    public ExpenseClaimDto verifyInvoice(@PathVariable UUID id,@PathVariable UUID invoiceId,
            @Valid @RequestBody com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceVerifyRequest input) {
        return service.verifyInvoice(id,invoiceId,input);
    }
}
