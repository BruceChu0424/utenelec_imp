package com.uten.imp.features.notice;

import java.util.Map;
import java.util.Set;

/** Ordinary business action reminders. Registration adds live authorization/state checks, never a popup or claim. */
public final class BusinessNoticeActionCatalog {
    private static final Map<String,String> KINDS = Map.ofEntries(
            Map.entry("PRODUCTION_FINISHED_INBOUND_PENDING", "STOCK_DOCUMENT"),
            Map.entry("PRODUCTION_FINISHED_ARRIVAL_PENDING", "PRODUCTION_DAILY_REPORT"),
            Map.entry("PROCUREMENT_IQC_PRE_STOCKED", "IQC_INSPECTION"),
            Map.entry("PREPLAN_SUPPLY_ACTION_CREATED", "SUPPLY_APPLICATION"),
            Map.entry("PREPLAN_SUPPLY_DOCUMENT_CREATED", "SUPPLY_APPLICATION"),
            Map.entry("SUBCONTRACT_OUTBOUND_COMPLETED", "SUBCONTRACT_ORDER"),
            Map.entry("PROCUREMENT_SUPPLIER_RETURN_REQUIRED", "PROCUREMENT_ARRIVAL_EXCEPTION"),
            Map.entry("PROCUREMENT_ARRIVAL_RECEIPT_POSTED", "PROCUREMENT_ARRIVAL_EXCEPTION"),
            Map.entry("PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED", "PROCUREMENT_ARRIVAL_EXCEPTION"),
            Map.entry("PROCUREMENT_ARRIVAL_EXCEPTION_DETECTED", "PROCUREMENT_ARRIVAL_EXCEPTION"),
            Map.entry("SUBCONTRACT_LOSS_CLAIM_OPENED", "SUBCONTRACT_LOSS_CASE"),
            Map.entry("RD_TASK_FORWARDED", "RD_TASK"),
            Map.entry("SALES_QUOTE_FINANCE_RETURNED", "SALES_QUOTE_ACTION"),
            Map.entry("SALES_QUOTE_FINANCE_CONFIRMED", "SALES_QUOTE_ACTION"),
            Map.entry("SALES_ORDER_FINANCE_REJECTED", "SALES_ORDER"),
            Map.entry("PROCUREMENT_FINANCE_REJECTED", "PROCUREMENT_ORDER_REWORK"));

    private BusinessNoticeActionCatalog() {}
    public static Set<String> events() { return KINDS.keySet(); }
    static boolean contains(String event) { return event != null && KINDS.containsKey(event); }
    public static String kind(String event) { return event == null ? null : KINDS.get(event); }
    static boolean eligible(String event,Set<String> permissions) {
        if (!permissions.contains("notice:read")) return false;
        return switch(event) {
            case "PRODUCTION_FINISHED_INBOUND_PENDING", "PRODUCTION_FINISHED_ARRIVAL_PENDING" ->
                    permissions.containsAll(Set.of("stock_doc:view","stock_doc:approve"));
            case "PROCUREMENT_IQC_PRE_STOCKED" -> permissions.containsAll(Set.of("procurement_inspection:view","procurement_inspection:handle"));
            case "PREPLAN_SUPPLY_ACTION_CREATED", "PREPLAN_SUPPLY_DOCUMENT_CREATED" ->
                    canDecompose(permissions,"purchase","purchase_request:view")
                    || canDecompose(permissions,"subcontract","subcontract_application:view");
            case "SUBCONTRACT_OUTBOUND_COMPLETED", "PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED" ->
                    permissions.containsAll(Set.of("warehouse_inbound:view","warehouse_inbound:stock_in"));
            case "PROCUREMENT_ARRIVAL_EXCEPTION_DETECTED" -> permissions.contains("finance_order_approval:view")
                    && (permissions.contains("finance_order_approval:approve") || permissions.contains("finance_order_approval:reject"));
            case "SUBCONTRACT_LOSS_CLAIM_OPENED" -> permissions.containsAll(Set.of("subcontract_loss_claim:view","subcontract_loss_claim:review"));
            case "PROCUREMENT_SUPPLIER_RETURN_REQUIRED", "PROCUREMENT_ARRIVAL_RECEIPT_POSTED" ->
                    permissions.containsAll(Set.of("supplier_return_task:view","supplier_return_task:complete"));
            case "RD_TASK_FORWARDED" -> permissions.containsAll(Set.of("rd_task:view","goods:view"))
                    && (permissions.contains("goods:bom:create") || permissions.contains("goods:bom:edit"));
            case "SALES_QUOTE_FINANCE_RETURNED" ->
                    permissions.containsAll(Set.of("sales_quote:view","sales_quote:edit"));
            case "SALES_QUOTE_FINANCE_CONFIRMED" -> permissions.contains("sales_quote:view")
                    && (permissions.contains("sales_quote:edit") || permissions.containsAll(Set.of("sales_quote:convert","sales_order:create")));
            case "SALES_ORDER_FINANCE_REJECTED" -> permissions.containsAll(Set.of("sales_order:view","sales_order:edit"));
            case "PROCUREMENT_FINANCE_REJECTED" -> permissions.containsAll(Set.of("purchase_order:view","purchase_order:edit"))
                    || permissions.containsAll(Set.of("subcontract_order:view","subcontract_order:edit"));
            default -> false;
        };
    }
    private static boolean canDecompose(Set<String> permissions,String module,String sourceView) {
        return permissions.containsAll(Set.of(sourceView,module+"_order:create",module+"_order:decompose"));
    }
}
