package com.uten.imp.features.finance.expense;

import com.uten.imp.audit.AuditDetailViewRecorder;
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
 *   <li>POST   /api/finance/expenses                          → finance_expense:create</li>
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
    private final AuditDetailViewRecorder detailViewAudit;

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
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted) {
        return service.list(new FinanceExpenseQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo).withHistory(includeDeleted, onlyDeleted), page, size, sort, order);
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径分组计数。 */
    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('finance_expense:view')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> facets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted) {
        return service.facets(new FinanceExpenseQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo, null).withHistory(includeDeleted, onlyDeleted));
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_expense:view')")
    public FinanceExpenseDetail detail(@PathVariable UUID id) {
        FinanceExpenseDetail result = service.detail(id);
        detailViewAudit.record(
                "view_finance_expense_detail",
                "finance_expenses",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "一般费用单");
        return result;
    }

    @GetMapping("/{id}/history")
    @PreAuthorize("hasAuthority('finance_expense:view')")
    public FinanceExpenseDetail history(@PathVariable UUID id) {
        FinanceExpenseDetail result = service.detailHistory(id);
        detailViewAudit.recordHistory(
                "view_finance_expense_detail",
                "finance_expenses",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "一般费用单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('finance_expense:create')")
    public FinanceExpenseDetail create(@Valid @RequestBody FinanceExpenseSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_expense:edit')")
    public FinanceExpenseDetail update(@PathVariable UUID id, @Valid @RequestBody FinanceExpenseSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_expense:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_expense:approve')")
    public FinanceExpenseDetail approve(@PathVariable UUID id) {
        FinanceExpenseDetail result = service.approve(id);
        // 审计：显式记录"谁审核了这张费用单"（触发器只记 update，业务语义在这里补）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_expense_approve", "finance_expense", String.valueOf(id), "success"));
        return result;
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_expense:reverse')")
    public FinanceExpenseDetail reverse(@PathVariable UUID id) {
        FinanceExpenseDetail result = service.reverse(id);
        // 审计：显式记录"谁红冲了这张费用单"。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_expense_reverse", "finance_expense", String.valueOf(id), "success"));
        return result;
    }

    /** C6 财务确认：已过账的费用单确认入账（gl_status 1→2）。 */
    @PostMapping("/{id}/gl-confirm")
    @PreAuthorize("hasAuthority('finance_expense:gl_confirm')")
    public FinanceExpenseDetail glConfirm(@PathVariable UUID id) {
        FinanceExpenseDetail result = service.glConfirm(id);
        // 审计：显式记录"谁确认入账了这张费用单"（税务敏感：过账确认）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_expense_gl_confirm", "finance_expense", String.valueOf(id), "success"));
        return result;
    }

    @GetMapping("/{id}/history/rows")
    @PreAuthorize("hasAuthority('finance_expense:view')")
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(
            @PathVariable UUID id, @RequestParam(required=false) Long beforeId,
            @RequestParam(defaultValue="50") int size) {
        var rows = service.historyRows(id,beforeId,size);
        detailViewAudit.recordHistory("view_finance_expense_detail", "finance_expenses", id, null, null, "单据历史明细");
        return rows;
    }
}
