package com.uten.imp.features.stock.insight.dto;

import com.uten.imp.common.web.PageResponse;

import java.util.List;

/** 称重异常: {items, page, size, total, totalPages, supplierSummary, workshopSummary}。 */
public class WeightAlertPage extends PageResponse<WeightAlertRow> {

    private final List<WeightPartySummary> supplierSummary;
    private final List<WeightPartySummary> workshopSummary;

    public WeightAlertPage(PageResponse<WeightAlertRow> page, List<WeightPartySummary> supplierSummary,
                           List<WeightPartySummary> workshopSummary) {
        super(page.getItems(), page.getPage(), page.getSize(), page.getTotal(), page.getTotalPages());
        this.supplierSummary = List.copyOf(supplierSummary);
        this.workshopSummary = List.copyOf(workshopSummary);
    }

    /** 供应商来料少数排名 (异常次数、少的千克数倒序)。 */
    public List<WeightPartySummary> getSupplierSummary() {
        return supplierSummary;
    }

    /** 车间领料超发排名 (异常次数、多发千克数倒序)。 */
    public List<WeightPartySummary> getWorkshopSummary() {
        return workshopSummary;
    }
}
