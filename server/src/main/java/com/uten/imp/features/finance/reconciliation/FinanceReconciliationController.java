package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationListItem;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationQueryFilter;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.MediaType;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 账户流水 API（钱流管理 · 只读）。
 *
 * <ul>
 *   <li>GET /api/finance/reconciliations?keyword=&accountId=&sourceDocType=&sourceDocId=&checkNo=&dateFrom=&dateTo=&page=&size=</li>
 * </ul>
 *
 * <p>权限：{@code finance_reconciliation:view}（种子化，view 给所有部门）。
 * 流水由各 finance_*审核 Service 写入（用户不直接编辑）。
 */
@RestController
@RequestMapping("/api/finance/reconciliations")
@RequiredArgsConstructor
public class FinanceReconciliationController {

    private final FinanceReconciliationService service;

    @GetMapping(produces = MediaType.APPLICATION_JSON_VALUE)
    @PreAuthorize("hasAuthority('finance_reconciliation:view')")
    public PageResponse<FinanceReconciliationListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) String sourceDocType,
            @RequestParam(required = false) UUID sourceDocId,
            @RequestParam(required = false) String checkNo,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new FinanceReconciliationQueryFilter(
                keyword, accountId, sourceDocType, sourceDocId, checkNo, dateFrom, dateTo), page, size, sort, order);
    }
}
