package com.uten.imp.features.sales.quote.history;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/sales/quotes/goods")
@RequiredArgsConstructor
public class GoodsQuoteHistoryController {
    private final GoodsQuoteHistoryService service;

    @GetMapping("/{goodsId}/history")
    @PreAuthorize("hasAuthority('goods:view') and hasAuthority('sales_quote_finance:view')")
    public PageResponse<GoodsQuoteHistoryService.Row> list(@PathVariable UUID goodsId,
            @RequestParam(defaultValue = "1") int page, @RequestParam(defaultValue = "20") int size) {
        return service.list(goodsId, page, size);
    }
}
