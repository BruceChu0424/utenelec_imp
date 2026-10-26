package com.uten.imp.common.report;

import java.util.*;

/** Exact read-only candidate routes; no wildcard permission or SQL field selection. */
public final class NativeFacetRoutes {
    private NativeFacetRoutes() { }
    public record Route(String profile, Set<String> fields) { }
    private static final Map<String, Route> ROUTES = routes();
    public static Route find(String path) { return ROUTES.get(path); }
    public static Set<String> paths() { return ROUTES.keySet(); }
    private static Map<String,Route> routes() {
        Map<String,Route> routes = new LinkedHashMap<>();
        add(routes,"/api/finance/reports/account/statement/facets","native_feature","billNo");
        add(routes,"/api/finance/payables/facets","native_feature","sourceDocNo");
        add(routes,"/api/finance/subcontract-loss-claims/facets","native_feature","wasteBillNo");
        add(routes,"/api/warehouse/quality-results/facets","native_warehouse_tasks","billNo");
        add(routes,"/api/procurement/inspection/records/facets","native_feature","sourceNo","referenceNo");
        add(routes,"/api/subcontract/short-deliveries/facets","native_subcontract_owner","orderBillNo");
        add(routes,"/api/warehouse/document-history/purchase-receipts/facets","native_warehouse_tasks","billNo","sourceDocNo");
        add(routes,"/api/warehouse/document-history/subcontract-receipts/facets","native_warehouse_tasks","billNo","sourceDocNo");
        add(routes,"/api/warehouse/document-history/subcontract-material-issues/facets","native_warehouse_tasks","billNo","sourceDocNo");
        add(routes,"/api/warehouse/document-history/subcontract-returns/facets","native_warehouse_tasks","billNo","sourceDocNo");
        add(routes,"/api/warehouse/document-history/subcontract-material-returns/facets","native_warehouse_tasks","billNo","sourceDocNo");
        add(routes,"/api/warehouse/document-history/subcontract-wastes/facets","native_warehouse_tasks","billNo","sourceDocNo");
        add(routes,"/api/warehouse/production-finished-in/tasks/facets","native_warehouse_tasks","taskNo","planNo");
        add(routes,"/api/production/schedule/pending/facets","native_feature","orderBillNo");
        add(routes,"/api/production/quality-inspections/records/facets","native_fqc_records","sourceNo","referenceNo","sheetNo");
        add(routes,"/api/sales/orders/progress/facets","native_sales_owner","billNo");
        add(routes,"/api/sales/orders/finance-confirmation/pending/facets","native_feature","billNo");
        add(routes,"/api/production/material-analyses/sales-candidates/facets","native_feature","orderNo");
        add(routes,"/api/production/execution-workbench/facets","native_production_owner","orders");
        add(routes,"/api/production/workshop-tasks/facets","native_workshop_tasks","sourcePlan","segment");
        add(routes,"/api/production/overproduction-rate/requests/facets","native_feature","plan","segment");
        return Collections.unmodifiableMap(routes);
    }
    private static void add(Map<String,Route> routes,String path,String profile,String... fields) {
        routes.put(path,new Route(profile,Set.of(fields)));
    }
}
