package com.uten.imp.features.finance.other_income;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeDetail;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeListItem;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeQueryFilter;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest;
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
 * 其它收入单 API（钱流管理）。与 FinanceExpenseController 对称。
 *
 * <ul>
 *   <li>GET    /api/finance/incomes?keyword=&accountId=&status=&dateFrom=&dateTo=&page=&size=</li>
 *   <li>GET    /api/finance/incomes/{id}</li>
 *   <li>POST   /api/finance/incomes                          → finance_other_income:edit</li>
 *   <li>PUT    /api/finance/incomes/{id}</li>
 *   <li>DELETE /api/finance/incomes/{id}</li>
 *   <li>POST   /api/finance/incomes/{id}/approve             → 账户累加 + 写流水（不涉 AR/AP）</li>
 *   <li>POST   /api/finance/incomes/{id}/reverse</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/finance/incomes")
@RequiredArgsConstructor
public class FinanceOtherIncomeController {

    private final FinanceOtherIncomeService service;

    @GetMapping
    @PreAuthorize("hasAuthority('finance_other_income:view')")
    public PageResponse<FinanceOtherIncomeListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new FinanceOtherIncomeQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo), page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_other_income:view')")
    public FinanceOtherIncomeDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('finance_other_income:edit')")
    public FinanceOtherIncomeDetail create(@Valid @RequestBody FinanceOtherIncomeSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_other_income:edit')")
    public FinanceOtherIncomeDetail update(@PathVariable UUID id, @Valid @RequestBody FinanceOtherIncomeSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_other_income:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_other_income:edit')")
    public FinanceOtherIncomeDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_other_income:edit')")
    public FinanceOtherIncomeDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
