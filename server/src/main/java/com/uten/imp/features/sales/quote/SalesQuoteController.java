package com.uten.imp.features.sales.quote;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.quote.dto.QuoteListItem;
import com.uten.imp.features.sales.quote.dto.QuoteQueryFilter;
import com.uten.imp.features.sales.quote.dto.QuoteSaveRequest;
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
 * 销售报价单 API（销售管理）。
 *
 * - GET    /api/sales/quotes                  → 分页
 * - GET    /api/sales/quotes/{id}             → 详情
 * - POST   /api/sales/quotes                  → 新建 sales_quote:edit
 * - PUT    /api/sales/quotes/{id}             → 编辑（仅草稿）
 * - DELETE /api/sales/quotes/{id}             → 删除（草稿/红冲可删）
 * - POST   /api/sales/quotes/{id}/approve     → 审核
 * - POST   /api/sales/quotes/{id}/reverse     → 红冲
 */
@RestController
@RequestMapping("/api/sales/quotes")
@RequiredArgsConstructor
public class SalesQuoteController {

    private final SalesQuoteService service;

    @GetMapping
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public PageResponse<QuoteListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new QuoteQueryFilter(keyword, clientId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public QuoteDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail create(@Valid @RequestBody QuoteSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail update(@PathVariable UUID id, @Valid @RequestBody QuoteSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /** 报价转订货（SOP §三1）：已审报价一键生成订货草稿（行带入+来源回联+价格留痕）。 */
    @PostMapping("/{id}/convert")
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public com.uten.imp.features.sales.order.dto.OrderDetail convert(@PathVariable UUID id) {
        return service.convertToOrder(id);
    }
}
