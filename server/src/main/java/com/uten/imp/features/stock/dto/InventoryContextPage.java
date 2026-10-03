package com.uten.imp.features.stock.dto;

import com.uten.imp.common.report.ReportTotal;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.TotaledPageResponse;

import java.util.List;

/** Existing paged inventory JSON plus the explicit scope used for the authorized stock projection. */
public class InventoryContextPage extends TotaledPageResponse<InstantInventoryRow> {
    private final StockInventoryScope scope;

    public InventoryContextPage(PageResponse<InstantInventoryRow> page, List<ReportTotal> totals,
                                StockInventoryScope scope) {
        super(page, totals);
        this.scope = scope;
    }

    public StockInventoryScope getScope() { return scope; }
}
