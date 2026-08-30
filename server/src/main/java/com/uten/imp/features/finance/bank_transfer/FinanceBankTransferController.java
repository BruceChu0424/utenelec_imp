package com.uten.imp.features.finance.bank_transfer;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferDetail;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferListItem;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferQueryFilter;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest;
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
 * 银行存取款单 API（钱流管理 · 保结构，审核暂未联动账户）。
 *
 * <ul>
 *   <li>GET    /api/finance/bank-transfers?keyword=&outAccountId=&status=&dateFrom=&dateTo=&page=&size=</li>
 *   <li>GET    /api/finance/bank-transfers/{id}</li>
 *   <li>POST   /api/finance/bank-transfers                       → finance_bank_transfer:create</li>
 *   <li>PUT    /api/finance/bank-transfers/{id}</li>
 *   <li>DELETE /api/finance/bank-transfers/{id}</li>
 *   <li>POST   /api/finance/bank-transfers/{id}/approve          → 占位（不动账户；启用时补跨币种核销）</li>
 *   <li>POST   /api/finance/bank-transfers/{id}/reverse</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/finance/bank-transfers")
@RequiredArgsConstructor
public class FinanceBankTransferController {

    private final FinanceBankTransferService service;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping
    @PreAuthorize("hasAuthority('finance_bank_transfer:view')")
    public PageResponse<FinanceBankTransferListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID outAccountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new FinanceBankTransferQueryFilter(keyword, outAccountId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_bank_transfer:view')")
    public FinanceBankTransferDetail detail(@PathVariable UUID id) {
        FinanceBankTransferDetail result = service.detail(id);
        detailViewAudit.record(
                "view_finance_bank_transfer_detail",
                "finance_bank_transfers",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "银行存取款单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('finance_bank_transfer:create')")
    public FinanceBankTransferDetail create(@Valid @RequestBody FinanceBankTransferSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_bank_transfer:edit')")
    public FinanceBankTransferDetail update(@PathVariable UUID id, @Valid @RequestBody FinanceBankTransferSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_bank_transfer:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_bank_transfer:approve')")
    public FinanceBankTransferDetail approve(@PathVariable UUID id) {
        FinanceBankTransferDetail result = service.approve(id);
        // 审计：显式记录"谁审核了这张银行存取款单"（触发器只记 update，业务语义在这里补）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_bank_transfer_approve", "finance_bank_transfer", String.valueOf(id), "success"));
        return result;
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_bank_transfer:reverse')")
    public FinanceBankTransferDetail reverse(@PathVariable UUID id) {
        FinanceBankTransferDetail result = service.reverse(id);
        // 审计：显式记录"谁红冲了这张银行存取款单"。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_bank_transfer_reverse", "finance_bank_transfer", String.valueOf(id), "success"));
        return result;
    }
}
