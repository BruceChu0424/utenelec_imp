package com.uten.imp.features.stock.ledger.dto;

import com.uten.imp.common.web.FacetBucket;
import com.uten.imp.common.web.PageResponse;

import java.util.List;
import java.util.Map;

/**
 * 流水分页 + 汇总 + 筛选桶。JSON: {items, page, size, total, totalPages, summary, facets}。
 *
 * <p>facets: movementType (value = 类型代码或 'W' 重量调整), warehouse (value = 仓库 id),
 * color (value = 颜色 id, 无颜色为 '__null__'); 每个桶 {value, label, count}, 只计日期范围内的行,
 * 且不受自身维度的筛选影响。
 */
public class StockLedgerPage extends PageResponse<StockLedgerRow> {

    private final StockLedgerSummary summary;
    private final Map<String, List<FacetBucket>> facets;

    public StockLedgerPage(List<StockLedgerRow> items, int page, int size, long total, int totalPages,
                           StockLedgerSummary summary, Map<String, List<FacetBucket>> facets) {
        super(items, page, size, total, totalPages);
        this.summary = summary;
        this.facets = facets == null ? Map.of() : Map.copyOf(facets);
    }

    public StockLedgerSummary getSummary() {
        return summary;
    }

    public Map<String, List<FacetBucket>> getFacets() {
        return facets;
    }
}
