package com.uten.imp.features.production.analysis;

/** Source coverage not yet represented by the sales line's planned/reserved quantities. */
public final class MaterialAnalysisSourceCoverageSql {
    private MaterialAnalysisSourceCoverageSql() { }

    /**
     * Approved plans and root fulfillment already occupy the order's quantity buckets.
     * Submitted plans still belong to the analysis: they have not written planned_qty.
     * An analysis can remain in fulfillment after an individual source's coverage is zero.
     */
    public static String coveredQty(String sourceAlias) {
        return "GREATEST(" + sourceAlias + ".requested_qty - " + sourceAlias
                + ".approved_qty - " + sourceAlias + ".root_fulfilled_qty, 0)";
    }
}
