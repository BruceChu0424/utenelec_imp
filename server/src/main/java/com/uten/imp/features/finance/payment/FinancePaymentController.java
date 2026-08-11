package com.uten.imp.features.finance.payment;

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
 *   <li>POST   /api/finance/payments                          → finance_payment:edit</li>
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
            @RequestParam(required = false) String order) {
        return service.list(new FinancePaymentQueryFilter(keyword, supplierId, accountId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_payment:view')")
    public FinancePaymentDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('finance_payment:edit')")
    public FinancePaymentDetail create(@Valid @RequestBody FinancePaymentSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_payment:edit')")
    public FinancePaymentDetail update(@PathVariable UUID id, @Valid @RequestBody FinancePaymentSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_payment:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_payment:edit')")
    public FinancePaymentDetail approve(@PathVariable UUID id) {
        FinancePaymentDetail result = service.approve(id);
        // 审计：显式记录"谁审核了这张付款单"（触发器只记 update，业务语义在这里补）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_payment_approve", "finance_payment", String.valueOf(id), "success"));
        return result;
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_payment:edit')")
    public FinancePaymentDetail reverse(@PathVariable UUID id) {
        FinancePaymentDetail result = service.reverse(id);
        // 审计：显式记录"谁红冲了这张付款单"。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_payment_reverse", "finance_payment", String.valueOf(id), "success"));
        return result;
    }
}
