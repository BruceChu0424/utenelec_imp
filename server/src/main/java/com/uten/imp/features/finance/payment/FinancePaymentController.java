package com.uten.imp.features.finance.payment;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.payment.dto.FinancePaymentDetail;
import com.uten.imp.features.finance.payment.dto.FinancePaymentListItem;
import com.uten.imp.features.finance.payment.dto.FinancePaymentQueryFilter;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
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
 * 采购付款单 API（钱流管理）。与 FinanceReceiptController 对称（Client↔Supplier）。
 *
 * <ul>
 *   <li>GET    /api/finance/payments?keyword=&supplierId=&accountId=&status=&dateFrom=&dateTo=&page=&size=</li>
 *   <li>GET    /api/finance/payments/{id}</li>
 *   <li>POST   /api/finance/payments                          → finance_payment:create</li>
 *   <li>PUT    /api/finance/payments/{id}                     → finance_payment:edit</li>
 *   <li>DELETE /api/finance/payments/{id}</li>
 *   <li>POST   /api/finance/payments/{id}/approve             → 核销 AP / 直接付款 / 账户扣减</li>
 *   <li>POST   /api/finance/payments/{id}/reverse</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/finance/payments")
@RequiredArgsConstructor
public class FinancePaymentController {

    private final FinancePaymentService service;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;
    private final AuditDetailViewRecorder detailViewAudit;
    @org.springframework.beans.factory.annotation.Autowired private com.uten.imp.features.finance.FinanceDocumentActions documentActions;

    @GetMapping("/{id}/review-operations/{requestId}")
    @PreAuthorize("hasAuthority('finance_payment:view')")
    public java.util.Map<String,Object> reviewReceipt(@PathVariable UUID id,@PathVariable UUID requestId){return documentActions.receipt("financePayment",id,requestId);}
    @PostMapping("/{id}/review-operations/{requestId}/cancel")
    @PreAuthorize("hasAuthority('finance_payment:view')")
    public java.util.Map<String,Object> cancelReview(@PathVariable UUID id,@PathVariable UUID requestId,@RequestBody com.uten.imp.features.finance.FinanceOperationJournal.Cancellation request){return documentActions.cancel("financePayment",id,requestId,request);}

    @GetMapping
    @PreAuthorize("hasAuthority('finance_payment:view')")
    public PageResponse<FinancePaymentListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted,
            @RequestParam java.util.Map<String, String> headerParams) {
        return service.list(new FinancePaymentQueryFilter(keyword, supplierId, accountId, status, dateFrom, dateTo, billNo).withHistory(includeDeleted, onlyDeleted).withHeaders(com.uten.imp.common.web.HeaderColumnFilter.from(headerParams)), page, size, sort, order);
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径分组计数。 */
    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('finance_payment:view')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> facets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted,
            @RequestParam java.util.Map<String, String> headerParams) {
        return service.facets(new FinancePaymentQueryFilter(keyword, supplierId, accountId, status, dateFrom, dateTo, null).withHistory(includeDeleted, onlyDeleted).withHeaders(com.uten.imp.common.web.HeaderColumnFilter.from(headerParams)));
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_payment:view')")
    public FinancePaymentDetail detail(@PathVariable UUID id) {
        FinancePaymentDetail result = documentActions.reviewedDetail("financePayment",id,false);
        detailViewAudit.record(
                "view_finance_payment_detail",
                "finance_payments",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "采购付款单");
        return result;
    }

    @GetMapping("/{id}/history")
    @PreAuthorize("hasAuthority('finance_payment:view')")
    public FinancePaymentDetail history(@PathVariable UUID id) {
        FinancePaymentDetail result = documentActions.reviewedDetail("financePayment",id,true);
        detailViewAudit.recordHistory(
                "view_finance_payment_detail",
                "finance_payments",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "采购付款单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('finance_payment:create')")
    public FinancePaymentDetail create(@Valid @RequestBody FinancePaymentSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_payment:edit')")
    public java.util.Map<String,Object> update(@PathVariable UUID id, @Valid @RequestBody com.uten.imp.features.finance.FinanceDocumentActions.UpdateCommand req) {
        return documentActions.update("financePayment",id,req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_payment:delete')")
    public java.util.Map<String,Object> delete(@PathVariable UUID id,@RequestBody com.uten.imp.features.finance.FinanceDocumentActions.ApprovalCommand command) {
        return documentActions.delete("financePayment",id,command);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_payment:approve')")
    public java.util.Map<String,Object> approve(@PathVariable UUID id,@RequestBody com.uten.imp.features.finance.FinanceDocumentActions.ApprovalCommand command) {
        return documentActions.approve("financePayment",id,command);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_payment:reverse')")
    public java.util.Map<String,Object> reverse(@PathVariable UUID id,@RequestBody com.uten.imp.application.port.FinancialDocumentUnapprovalCommandPort.Command command) {
        return documentActions.unapprove("financePayment",id,command);
    }

    @GetMapping("/{id}/history/rows")
    @PreAuthorize("hasAuthority('finance_payment:view')")
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(
            @PathVariable UUID id, @RequestParam(required=false) Long beforeId,
            @RequestParam(defaultValue="50") int size) {
        var rows = service.historyRows(id,beforeId,size);
        detailViewAudit.recordHistory("view_finance_payment_detail", "finance_payments", id, null, null, "单据历史明细");
        return rows;
    }
}
