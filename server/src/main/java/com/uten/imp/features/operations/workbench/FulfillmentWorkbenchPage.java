package com.uten.imp.features.operations.workbench;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

/**
 * One workbench page. {@code readScopeVersion/readSnapshotRevision/readDataVersion}
 * are the complete-read proofs stamped by {@link FulfillmentWorkbenchQueryService#queryVersioned}:
 * continuation batches of the same query may be fetched concurrently only when every
 * batch carries the same revision. Internal/export callers leave them null.
 */
public record FulfillmentWorkbenchPage(
        List<FulfillmentTaskRow> items,
        int page,
        int size,
        long total,
        int totalPages,
        Summary summary,
        Capabilities capabilities,
        Map<String, List<Facet>> facets,
        Map<String, Long> nullCounts,
        boolean metadataIncluded,
        String readScopeVersion,
        String readSnapshotRevision,
        String readDataVersion) {

    public FulfillmentWorkbenchPage(List<FulfillmentTaskRow> items,int page,int size,long total,int totalPages,
            Summary summary,Capabilities capabilities,Map<String,List<Facet>> facets,Map<String,Long> nullCounts) {
        this(items,page,size,total,totalPages,summary,capabilities,facets,nullCounts,true);
    }

    public FulfillmentWorkbenchPage(List<FulfillmentTaskRow> items,int page,int size,long total,int totalPages,
            Summary summary,Capabilities capabilities,Map<String,List<Facet>> facets,Map<String,Long> nullCounts,
            boolean metadataIncluded) {
        this(items,page,size,total,totalPages,summary,capabilities,facets,nullCounts,metadataIncluded,null,null,null);
    }

    public FulfillmentWorkbenchPage {
        if (!metadataIncluded && (summary!=null || facets!=null || nullCounts!=null))
            throw new IllegalArgumentException("Omitted task metadata must be null, never invented zero buckets");
    }

    FulfillmentWorkbenchPage withReadProof(String scope, String revision, String dataVersion) {
        return new FulfillmentWorkbenchPage(items,page,size,total,totalPages,summary,capabilities,facets,nullCounts,
                metadataIncluded,scope,revision,dataVersion);
    }

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
