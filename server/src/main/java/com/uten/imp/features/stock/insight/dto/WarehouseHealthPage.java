package com.uten.imp.features.stock.insight.dto;

import com.uten.imp.common.report.ReportTotal;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.TotaledPageResponse;

import java.util.List;

/** 呆滞与库龄: {overview, items, page, size, total, totalPages, totals}。合计覆盖筛选后的全部行。 */
public class WarehouseHealthPage extends TotaledPageResponse<HealthRow> {

    private final HealthOverview overview;

    public WarehouseHealthPage(PageResponse<HealthRow> page, List<ReportTotal> totals, HealthOverview overview) {
        super(page, totals);
        this.overview = overview;
    }

    public HealthOverview getOverview() {
        return overview;
    }
}
