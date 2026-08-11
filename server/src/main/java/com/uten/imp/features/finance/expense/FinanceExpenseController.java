package com.uten.imp.features.finance.expense;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseDetail;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseListItem;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseQueryFilter;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest;
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
 * 一般费用单 API（钱流管理）。
 *
 * <ul>
 *   <li>GET    /api/finance/expenses?keyword=&accountId=&status=&dateFrom=&dateTo=&page=&size=</li>
 *   <li>GET    /api/finance/expenses/{id}</li>
 *   <li>POST   /api/finance/expenses                          → finance_expense:edit</li>
 *   <li>PUT    /api/finance/expenses/{id}</li>
 *   <li>DELETE /api/finance/expenses/{id}</li>
 *   <li>POST   /api/finance/expenses/{id}/approve             → 账户扣减 + 写流水（不涉 AR/AP）</li>
 *   <li>POST   /api/finance/expenses/{id}/reverse</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/finance/expenses")
@RequiredArgsConstructor
public class FinanceExpenseController {

    private final FinanceExpenseService service;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    @PreAuthorize("hasAuthority('finance_expense:view')")
    public PageResponse<FinanceExpenseListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new FinanceExpenseQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_expense:view')")
    public FinanceExpenseDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('finance_expense:edit')")
    public FinanceExpenseDetail create(@Valid @RequestBody FinanceExpenseSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_expense:edit')")
    public FinanceExpenseDetail update(@PathVariable UUID id, @Valid @RequestBody FinanceExpenseSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_expense:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_expense:edit')")
    public FinanceExpenseDetail approve(@PathVariable UUID id) {
        FinanceExpenseDetail result = service.approve(id);
        // 审计：显式记录"谁审核了这张费用单"（触发器只记 update，业务语义在这里补）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_expense_approve", "finance_expense", String.valueOf(id), "success"));
        return result;
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_expense:edit')")
    public FinanceExpenseDetail reverse(@PathVariable UUID id) {
        FinanceExpenseDetail result = service.reverse(id);
        // 审计：显式记录"谁红冲了这张费用单"。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_expense_reverse", "finance_expense", String.valueOf(id), "success"));
        return result;
    }

    /** C6 财务确认：已过账的费用单确认入账（gl_status 1→2）。 */
    @PostMapping("/{id}/gl-confirm")
    @PreAuthorize("hasAuthority('finance_expense:edit')")
    public FinanceExpenseDetail glConfirm(@PathVariable UUID id) {
        FinanceExpenseDetail result = service.glConfirm(id);
        // 审计：显式记录"谁确认入账了这张费用单"（税务敏感：过账确认）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_expense_gl_confirm", "finance_expense", String.valueOf(id), "success"));
        return result;
    }
}
