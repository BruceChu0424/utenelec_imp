package com.uten.imp.common.report;

import com.uten.imp.common.finance.ProcurementDeliveryDifference;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Explicit source expressions shared by the procurement document reports. */
public final class ProcurementReportColumnSearch {
    private ProcurementReportColumnSearch() {}
    // Every currently declared procurement-report date is an SQL DATE. The
    // return-detail combined bill number remains text and keeps text semantics.
    private static final Set<String> CALENDAR_DATES=Set.of("billDate","deliverDate");

    public static Map<String, String> expressions() {
        return Map.ofEntries(
                Map.entry("billNo", "o.bill_no"), Map.entry("billDate", "o.bill_date"),
                Map.entry("deliverDate", "o.deliver_date"), Map.entry("supplierName", "sup.name"),
                Map.entry("warehouseName", "wh.name"), Map.entry("applicantName", "em_app.full_name"),
                Map.entry("purchaserName", "em_pur.full_name"), Map.entry("receiverName", "em_rec.full_name"),
                Map.entry("operatorName", "COALESCE(em_op.full_name,o.operator_name)"),
                Map.entry("makerName", "COALESCE(em_mk.full_name,o.maker_name)"),
                Map.entry("approverName", "COALESCE(em_ap.full_name,o.approver_name)"),
                Map.entry("departmentName", "COALESCE(dept.name,legacy_dept.name)"),
                Map.entry("productionNo", "i.production_no"), Map.entry("series", "g.series"),
                Map.entry("goodsName", "i.goods_name_snapshot"), Map.entry("goodsCode", "i.goods_code_snapshot"),
                Map.entry("colorName", "col.name"), Map.entry("model", "g.model"),
                Map.entry("customerModel", "g.c_number"), Map.entry("categoryName", "mc.name"),
                Map.entry("material", "g.material"), Map.entry("spec", "g.spec"),
                Map.entry("unitName", "un.name"), Map.entry("weight", "i.weight"),
                Map.entry("qty", "i.qty"), Map.entry("price", "i.price"),
                Map.entry("amount", "i.amount_original"), Map.entry("totalAmount", "o.total_local"),
                Map.entry("orderedQty", "i.ordered_qty"), Map.entry("orderQty", "oi.qty"),
                Map.entry("giftQty", "i.gift_qty"), Map.entry("receivedQty", "i.received_qty"),
                Map.entry("returnedQty", "i.returned_qty"),
                Map.entry("differenceQty", ProcurementDeliveryDifference.sql("i.qty", "i.received_qty", "i.returned_qty")),
                Map.entry("sourceOrderDifferenceQty", "source_order_difference.qty"),
                Map.entry("stockQty", "COALESCE(sb.stock_qty,0)"), Map.entry("safeStock", "g.min_qty"),
                Map.entry("purchaseOrderNo", "i.purchase_order_no"), Map.entry("salesOrderNo", "i.sales_order_no"),
                Map.entry("productionPlanNo", "i.production_plan_no"), Map.entry("laborCost", "g.work_e"),
                Map.entry("purchaseReply", "i.purchase_reply"), Map.entry("returnNo", "i.return_no"),
                Map.entry("orderNo", "i.order_no"), Map.entry("issueNo", "i.issue_no"),
                Map.entry("receiptNo", "i.receipt_no"),
                Map.entry("boxQty", "i.box_qty"), Map.entry("girth", "i.girth_qty"),
                Map.entry("remark", "o.remark"));
    }

    /**
     * Only declared, authorized columns can supply conditions. Types determine
     * grammar; page-specific overrides describe genuine projection differences.
     * Window ordinals and constant placeholders deliberately have no expression.
     */
    public static Set<String> apply(ReportQueryKit.WhereBuilder where, Map<String, String> filters,
                                    Map<String, String> columnTypes, Map<String, String> overrides) {
        Map<String, String> expressions = new LinkedHashMap<>(expressions());
        expressions.putAll(overrides);
        return ReportColumnSearch.apply(where,filters,columnTypes,expressions,CALENDAR_DATES.stream()
                .collect(java.util.stream.Collectors.toUnmodifiableMap(key->key,key->com.uten.imp.common.util.JpaColumnSearch.Kind.DATE)));
    }
}
