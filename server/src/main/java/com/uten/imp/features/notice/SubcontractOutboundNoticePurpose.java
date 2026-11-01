package com.uten.imp.features.notice;

import java.util.regex.Pattern;

/** One existing outbox event has two information receipts and one warehouse action.
 * Derive authorization purpose only from the producer's exact structured shape. */
final class SubcontractOutboundNoticePurpose {
    static final String EVENT = "SUBCONTRACT_OUTBOUND_COMPLETED";
    private static final String UUID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
    private static final String ORDER_ROUTE = "^/subcontract/orders/" + UUID + "$";
    private static final String ANALYSIS_ROUTE = "^/production/material-analyses/" + UUID + "/summary$";
    private static final Pattern ORDER = Pattern.compile(ORDER_ROUTE);
    private static final Pattern ANALYSIS = Pattern.compile(ANALYSIS_ROUTE);
    static final String WAREHOUSE_ROUTE = "/warehouse/inbound/expectations";

    // Compile-time HQL constants are consumed by every repository read before
    // paging. The same regexes and metadata dimensions are used by classify().
    private static final String TARGETED_HQL = "n.kind='NORMAL' AND n.audienceUserId IS NOT NULL AND n.audienceScope='selected' AND n.audienceCount=1 AND n.sourceRevision IS NULL";
    static final String ORDINARY_HQL = "(" + TARGETED_HQL
            + " AND n.type='workflow' AND n.aggregateKind IS NULL AND n.aggregateId IS NULL AND ("
            + "(length(n.actionRoute)=56 AND cast(function('regexp_like',n.actionRoute,'" + ORDER_ROUTE + "') as Boolean)=true) OR "
            + "(length(n.actionRoute)=74 AND cast(function('regexp_like',n.actionRoute,'" + ANALYSIS_ROUTE + "') as Boolean)=true)))";
    private static final String WAREHOUSE_HQL = "(" + TARGETED_HQL
            + " AND n.type='task' AND n.aggregateKind='SUBCONTRACT_ORDER' AND n.aggregateId IS NOT NULL AND n.actionRoute='" + WAREHOUSE_ROUTE + "')";
    static final String SUPPORTED_HQL = "(n.sourceEvent IS NULL OR n.sourceEvent<>'" + EVENT + "' OR " + ORDINARY_HQL + " OR " + WAREHOUSE_HQL + ")";

    enum Purpose { ORDER_RECEIPT, ANALYSIS_RECEIPT, WAREHOUSE_ACTION, UNSUPPORTED }

    static Purpose classify(Notice n) {
        if (!EVENT.equals(n.getSourceEvent()) || !"NORMAL".equals(n.getKind())
                || n.getAudienceUserId() == null || !"selected".equals(n.getAudienceScope())
                || !Integer.valueOf(1).equals(n.getAudienceCount()) || n.getSourceRevision() != null)
            return Purpose.UNSUPPORTED;
        String route = n.getActionRoute();
        if ("workflow".equals(n.getType()) && n.getAggregateKind() == null && n.getAggregateId() == null && route != null) {
            if (route.length() == 56 && ORDER.matcher(route).matches()) return Purpose.ORDER_RECEIPT;
            if (route.length() == 74 && ANALYSIS.matcher(route).matches()) return Purpose.ANALYSIS_RECEIPT;
        }
        if ("task".equals(n.getType()) && "SUBCONTRACT_ORDER".equals(n.getAggregateKind())
                && n.getAggregateId() != null && WAREHOUSE_ROUTE.equals(route)) return Purpose.WAREHOUSE_ACTION;
        return Purpose.UNSUPPORTED;
    }

    static boolean ordinary(Notice n) {
        Purpose purpose = classify(n);
        return purpose == Purpose.ORDER_RECEIPT || purpose == Purpose.ANALYSIS_RECEIPT;
    }

    private SubcontractOutboundNoticePurpose() {}
}
