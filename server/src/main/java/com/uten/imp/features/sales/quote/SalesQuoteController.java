package com.uten.imp.features.sales.quote;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.sales.quote.dto.QuoteActionRequest;
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
 * - POST   /api/sales/quotes                  → 新建 sales_quote:create
 * - PUT    /api/sales/quotes/{id}             → 编辑（仅草稿）
 * - DELETE /api/sales/quotes/{id}             → 删除(仅草稿)
 * - POST   /api/sales/quotes/{id}/submit      → 提交财务核价(草稿 → 待核价)
 * - POST   /api/sales/quotes/{id}/withdraw    → 撤回核价(待核价 → 草稿, 财务没在核价时)
 * - POST   /api/sales/quotes/{id}/reopen      → 重新修改(已核价未转单 → 草稿)
 * - POST   /api/sales/quotes/{id}/reverse     → 作废(已核价未转单)
 * - POST   /api/sales/quotes/{id}/convert     → 转订货单(已核价)
 * - GET    /api/sales/quotes/counts           → 工作台徽章「报价已核价待转订货」
 *
 * <p>报价不再由销售审核(ADR-134): 财务核价端点见 {@link SalesQuoteFinanceController}。
 */
@RestController
@RequestMapping("/api/sales/quotes")
@RequiredArgsConstructor
public class SalesQuoteController {

    private final SalesQuoteService service;
    private final AuditDetailViewRecorder viewAudit;

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
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) String bucket,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted,
            @RequestParam(required = false) UUID currencyId,
            @RequestParam java.util.Map<String, String> headerParams) {
        return service.list(new QuoteQueryFilter(keyword, clientId, status, dateFrom, dateTo, billNo, bucket).withHistory(includeDeleted, onlyDeleted).withCurrency(currencyId).withHeaders(com.uten.imp.common.web.HeaderColumnFilter.from(headerParams)),
                page, size, sort, order);
    }

    /** 工作台徽章「报价已核价待转订货」(本人负责范围)。 */
    @GetMapping("/counts")
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public SalesQuoteService.QuoteCounts counts() {
        return service.counts();
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径分组计数。 */
    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> facets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String bucket,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted,
            @RequestParam(required = false) UUID currencyId,
            @RequestParam java.util.Map<String, String> headerParams) {
        return service.facets(new QuoteQueryFilter(keyword, clientId, status, dateFrom, dateTo, null, bucket).withHistory(includeDeleted, onlyDeleted).withCurrency(currencyId).withHeaders(com.uten.imp.common.web.HeaderColumnFilter.from(headerParams)));
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public QuoteDetail detail(@PathVariable UUID id) {
        QuoteDetail detail = service.detail(id);
        viewAudit.record(
                "view_sales_quote_detail", "sales_quotes", id,
                detail.getBillNo(), detail.getLegacyId(), "销售报价单");
        return detail;
    }

    @GetMapping("/{id}/history")
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public QuoteDetail history(@PathVariable UUID id) {
        QuoteDetail detail = service.detailHistory(id);
        viewAudit.recordHistory(
                "view_sales_quote_detail", "sales_quotes", id,
                detail.getBillNo(), detail.getLegacyId(), "销售报价单");
        return detail;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('sales_quote:create')")
    public QuoteDetail create(@Valid @RequestBody QuoteSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail update(@PathVariable UUID id, @Valid @RequestBody QuoteSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_quote:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    /** 提交财务核价; body 可选(带 expectedRevision 时校验)。 */
    @PostMapping("/{id}/submit")
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail submit(@PathVariable UUID id,
                              @Valid @RequestBody(required = false) QuoteActionRequest req) {
        return service.submit(id, req);
    }

    /** 撤回核价(必须带 expectedRevision)。 */
    @PostMapping("/{id}/withdraw")
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail withdraw(@PathVariable UUID id, @Valid @RequestBody QuoteActionRequest req) {
        return service.withdraw(id, req);
    }

    /** 重新修改已核价的报价(必须带 expectedRevision)。 */
    @PostMapping("/{id}/reopen")
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail reopen(@PathVariable UUID id, @Valid @RequestBody QuoteActionRequest req) {
        return service.reopen(id, req);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_quote:reverse')")
    public QuoteDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /** 报价转订货(SOP §三1)：财务已核价的报价一键生成订货草稿(表头+行+核定折扣带入，来源回联)。 */
    @PostMapping("/{id}/convert")
    @PreAuthorize("hasAuthority('sales_quote:convert') and hasAuthority('sales_order:create')")
    public com.uten.imp.features.sales.order.dto.OrderDetail convert(@PathVariable UUID id) {
        return service.convertToOrder(id);
    }

    @GetMapping("/{id}/history/rows")
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(
            @PathVariable UUID id, @RequestParam(required=false) Long beforeId,
            @RequestParam(defaultValue="50") int size) {
        var rows = service.historyRows(id,beforeId,size);
        viewAudit.recordHistory("view_sales_quote_detail", "sales_quotes", id, null, null, "单据历史明细");
        return rows;
    }
}
