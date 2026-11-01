package com.uten.imp.features.sales;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.dto.SalesOrderFinanceReviewDto;
import com.uten.imp.features.sales.quote.SalesQuoteFinanceService;
import com.uten.imp.features.sales.quote.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/sales/manager-review")
@RequiredArgsConstructor
public class SalesManagerReviewController {
    private final SalesManagerReviewService service;
    private final SalesManagerReviewProjection projection;
    private final com.uten.imp.audit.AuditDetailViewRecorder viewAudit;
    private final SalesQuoteFinanceService quotes;
    private final SalesOrderFinanceConfirmService orders;

    @GetMapping @PreAuthorize("hasAnyAuthority('sales_quote_manager:view','sales_order_manager:view')")
    public PageResponse<SalesManagerReviewService.Task> list(@RequestParam String kind,
            @RequestParam(defaultValue="PENDING") String state,@RequestParam(required=false) String keyword,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="20") int size) {
        return service.list(kind,state,keyword,page,size);
    }
    @GetMapping("/count") @PreAuthorize("hasAnyAuthority('sales_quote_manager:view','sales_order_manager:view')")
    @com.uten.imp.security.BusinessTaskRead
    public Map<String,Long> count() { return service.counts(); }
    @GetMapping("/quotes/{id}") @PreAuthorize("hasAuthority('sales_quote_manager:view')")
    public Map<String,Object> quote(@PathVariable UUID id) {
        var review=quotes.managerReview(id);
        viewAudit.record("view_sales_quote_detail","sales_quotes",id,review.billNo(),null,"销售报价单");
        return projection.quote(review);
    }
    @PutMapping("/quotes/{id}") @PreAuthorize("hasAuthority('sales_quote_manager:view') and hasAuthority('sales_quote_manager:confirm')")
    public Map<String,Object> edit(@PathVariable UUID id,@Valid @RequestBody QuoteFinanceEditRequest request) { return projection.quote(quotes.editManager(id,request)); }
    @PostMapping("/quotes/{id}/confirm") @PreAuthorize("hasAuthority('sales_quote_manager:view') and hasAuthority('sales_quote_manager:confirm')")
    public Map<String,Object> confirmQuote(@PathVariable UUID id,@Valid @RequestBody QuoteFinanceDecisionRequest request) { return projection.quote(quotes.confirmManager(id,request)); }
    @PostMapping("/quotes/{id}/reject") @PreAuthorize("hasAuthority('sales_quote_manager:view') and hasAuthority('sales_quote_manager:reject')")
    public Map<String,Object> rejectQuote(@PathVariable UUID id,@Valid @RequestBody QuoteFinanceDecisionRequest request) { return projection.quote(quotes.rejectManager(id,request)); }
    @PostMapping("/quotes/{id}/reverse") @PreAuthorize("hasAuthority('sales_quote_manager:view') and hasAuthority('sales_quote_manager:reverse')")
    public Map<String,Object> reverseQuote(@PathVariable UUID id,@Valid @RequestBody QuoteActionRequest request) { return projection.quote(quotes.reopenManager(id,request)); }
    @GetMapping("/orders/{id}") @PreAuthorize("hasAuthority('sales_order_manager:view')")
    public Map<String,Object> order(@PathVariable UUID id) {
        var review=orders.managerReview(id);
        viewAudit.record("view_sales_order_detail","sales_orders",id,review.billNo(),null,"销售订货单");
        return projection.order(review);
    }
    @PostMapping("/orders/{id}/confirm") @PreAuthorize("hasAuthority('sales_order_manager:view') and hasAuthority('sales_order_manager:confirm')")
    public void confirmOrder(@PathVariable UUID id,@Valid @RequestBody SalesOrderFinanceConfirmService.FinanceConfirmRequest request) { service.confirmOrder(id,request); }
    @PostMapping("/orders/batch") @PreAuthorize("hasAuthority('sales_order_manager:view') and hasAuthority('sales_order_manager:confirm')")
    public SalesOrderFinanceConfirmService.FinanceBatchConfirmResult batch(@Valid @RequestBody SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest request) { return service.confirmOrders(request); }
    @PostMapping("/orders/{id}/reject") @PreAuthorize("hasAuthority('sales_order_manager:view') and hasAuthority('sales_order_manager:reject')")
    public void rejectOrder(@PathVariable UUID id,@Valid @RequestBody SalesOrderFinanceConfirmService.FinanceRejectRequest request) { service.rejectOrder(id,request); }
    @PostMapping("/orders/{id}/reverse") @PreAuthorize("hasAuthority('sales_order_manager:view') and hasAuthority('sales_order_manager:reverse')")
    public void reverseOrder(@PathVariable UUID id,@Valid @RequestBody SalesOrderFinanceConfirmService.FinanceRejectRequest request) { service.reverseOrder(id,request); }
}
