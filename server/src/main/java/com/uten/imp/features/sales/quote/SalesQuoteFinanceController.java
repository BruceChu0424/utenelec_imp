package com.uten.imp.features.sales.quote;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.quote.dto.QuoteActionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceDecisionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceEditRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceListItem;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceReviewDto;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * 销售报价财务核价 API(ADR-134)。
 *
 * <ul>
 *   <li>GET  /api/sales/quotes/finance-review?state=pending|confirmed|returned&keyword&page&size → 核价列表</li>
 *   <li>GET  /api/sales/quotes/finance-review/count → 工作台徽章「报价待核价」</li>
 *   <li>GET  /api/sales/quotes/{id}/finance-review → 核价详情(标价/文件单价/折合本币/成交单价/折扣/差额/修订)</li>
 *   <li>PUT  /api/sales/quotes/{id}/finance → 核价修改</li>
 *   <li>POST /api/sales/quotes/{id}/finance-return → 退回销售(必须写原因)</li>
 *   <li>POST /api/sales/quotes/{id}/finance-confirm → 确认报价</li>
 *   <li>POST /api/sales/quotes/{id}/finance-reopen → 撤销确认再修改</li>
 * </ul>
 * 认领用通用任务认领接口 /api/task-claims/SALES_QUOTE_FINANCE_REVIEW/{报价id}/claim。
 */
@RestController
@RequestMapping("/api/sales/quotes")
@RequiredArgsConstructor
public class SalesQuoteFinanceController {

    private final SalesQuoteFinanceService service;
    private final AuditDetailViewRecorder viewAudit;

    @GetMapping("/finance-review")
    @PreAuthorize("hasAuthority('sales_quote_finance:view')")
    public PageResponse<QuoteFinanceListItem> list(
            @RequestParam(required = false) String state,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(state, keyword, page, size);
    }

    @GetMapping("/finance-review/count")
    @PreAuthorize("hasAuthority('sales_quote_finance:view')")
    public Map<String, Long> pendingCount() {
        return service.pendingCount();
    }

    @GetMapping("/{id}/finance-review")
    @PreAuthorize("hasAuthority('sales_quote_finance:view')")
    public QuoteFinanceReviewDto review(@PathVariable UUID id) {
        QuoteFinanceReviewDto review = service.review(id);
        // 核价页同样是查看整张报价(含客户文件单价), 按报价详情查看留痕。
        viewAudit.record("view_sales_quote_detail", "sales_quotes", id,
                review.billNo(), null, "销售报价单");
        return review;
    }

    @PutMapping("/{id}/finance")
    @PreAuthorize("hasAuthority('sales_quote_finance:view') and hasAuthority('sales_quote_finance:confirm')")
    public QuoteFinanceReviewDto edit(@PathVariable UUID id, @Valid @RequestBody QuoteFinanceEditRequest req) {
        return service.edit(id, req);
    }

    @PostMapping("/{id}/finance-return")
    @PreAuthorize("hasAuthority('sales_quote_finance:view') and hasAuthority('sales_quote_finance:confirm')")
    public QuoteFinanceReviewDto returnToSales(
            @PathVariable UUID id, @Valid @RequestBody QuoteFinanceDecisionRequest req) {
        return service.returnToSales(id, req);
    }

    @PostMapping("/{id}/finance-confirm")
    @PreAuthorize("hasAuthority('sales_quote_finance:view') and hasAuthority('sales_quote_finance:confirm')")
    public QuoteFinanceReviewDto confirm(
            @PathVariable UUID id, @Valid @RequestBody QuoteFinanceDecisionRequest req) {
        return service.confirm(id, req);
    }

    @PostMapping("/{id}/finance-reopen")
    @PreAuthorize("hasAuthority('sales_quote_finance:view') and hasAuthority('sales_quote_finance:confirm')")
    public QuoteFinanceReviewDto reopen(@PathVariable UUID id, @Valid @RequestBody QuoteActionRequest req) {
        return service.reopen(id, req);
    }
}
