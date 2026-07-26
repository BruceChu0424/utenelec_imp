package com.uten.imp.features.finance.bank_transfer;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferDetail;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferListItem;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferQueryFilter;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest;
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
 *   <li>POST   /api/finance/bank-transfers                       → finance_bank_transfer:edit</li>
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

    @GetMapping
    @PreAuthorize("hasAuthority('finance_bank_transfer:view')")
    public PageResponse<FinanceBankTransferListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID outAccountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new FinanceBankTransferQueryFilter(keyword, outAccountId, status, dateFrom, dateTo), page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_bank_transfer:view')")
    public FinanceBankTransferDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('finance_bank_transfer:edit')")
    public FinanceBankTransferDetail create(@Valid @RequestBody FinanceBankTransferSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_bank_transfer:edit')")
    public FinanceBankTransferDetail update(@PathVariable UUID id, @Valid @RequestBody FinanceBankTransferSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_bank_transfer:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_bank_transfer:edit')")
    public FinanceBankTransferDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_bank_transfer:edit')")
    public FinanceBankTransferDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
