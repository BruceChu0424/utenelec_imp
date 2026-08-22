package com.uten.imp.features.finance.receipt;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptDetail;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptListItem;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptQueryFilter;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
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
 * 销售收款单 API（钱流管理）。
 *
 * <ul>
 *   <li>GET    /api/finance/receipts?keyword=&clientId=&accountId=&status=&dateFrom=&dateTo=&page=&size= → 分页</li>
 *   <li>GET    /api/finance/receipts/{id}                 → 详情（主 + 明细）</li>
 *   <li>POST   /api/finance/receipts                      → 新建（草稿）finance_receipt:create</li>
 *   <li>PUT    /api/finance/receipts/{id}                 → 编辑（仅草稿）</li>
 *   <li>DELETE /api/finance/receipts/{id}                 → 删除（草稿/红冲可删）</li>
 *   <li>POST   /api/finance/receipts/{id}/approve         → 审核（核销 AR / 直接收款 / 账户累加 / 写流水）</li>
 *   <li>POST   /api/finance/receipts/{id}/reverse         → 红冲（反向冲销）</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/finance/receipts")
@RequiredArgsConstructor
public class FinanceReceiptController {

    private final FinanceReceiptService service;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    @PreAuthorize("hasAuthority('finance_receipt:view')")
    public PageResponse<FinanceReceiptListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new FinanceReceiptQueryFilter(keyword, clientId, accountId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_receipt:view')")
    public FinanceReceiptDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('finance_receipt:create')")
    public FinanceReceiptDetail create(@Valid @RequestBody FinanceReceiptSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_receipt:edit')")
    public FinanceReceiptDetail update(@PathVariable UUID id, @Valid @RequestBody FinanceReceiptSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('finance_receipt:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('finance_receipt:approve')")
    public FinanceReceiptDetail approve(@PathVariable UUID id) {
        FinanceReceiptDetail result = service.approve(id);
        // 审计：显式记录"谁审核了这张收款单"（触发器只记 update，业务语义在这里补）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_receipt_approve", "finance_receipt", String.valueOf(id), "success"));
        return result;
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_receipt:reverse')")
    public FinanceReceiptDetail reverse(@PathVariable UUID id) {
        FinanceReceiptDetail result = service.reverse(id);
        // 审计：显式记录"谁红冲了这张收款单"。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "finance_receipt_reverse", "finance_receipt", String.valueOf(id), "success"));
        return result;
    }
}
