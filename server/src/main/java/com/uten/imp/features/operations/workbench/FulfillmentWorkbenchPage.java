package com.uten.imp.features.operations.workbench;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

public record FulfillmentWorkbenchPage(
        List<FulfillmentTaskRow> items,
        int page,
        int size,
        long total,
        int totalPages,
        Summary summary,
        Capabilities capabilities,
        Map<String, List<Facet>> facets,
        Map<String, Long> nullCounts) {

    public record Facet(String value, String label, long count) {}

    public record Summary(
            long totalTasks,
            long overdueTasks,
            long openTasks,
            BigDecimal openQty,
            Map<String, Long> statusCounts,
            Map<String, Long> exceptionCounts,
            long pendingTasks) {
    }

    public record Capabilities(
            boolean canCreatePurchaseOrder, boolean canCreateSubcontractOrder) {
    }
}
