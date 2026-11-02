package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.security.AuthUser;
import java.math.BigDecimal;
import java.util.Map;

/** One read projection for purchase/subcontract receipt and arrival-exception progress. */
public final class ProcurementReceiptProgress {
    private ProcurementReceiptProgress() { }

    public static String joins(String type, String receipt, String item) {
        return """
                LEFT JOIN LATERAL (
                    SELECT COUNT(*) AS inspection_count,
                           COUNT(*) FILTER(WHERE q.status IN('PENDING','PARTIAL')) AS open_inspection_count,
                           COUNT(*) FILTER(WHERE q.status IN('PENDING','PARTIAL') AND q.pre_stocked_at IS NOT NULL) AS pre_stocked_open_count,
                           SUM(q.warehouse_stocked_base_qty / NULLIF(q.unit_rate,0)) AS stocked_qty,
                           SUM(GREATEST(q.passed_base_qty-q.warehouse_stocked_base_qty,0) / NULLIF(q.unit_rate,0)) AS pending_stock_qty
                    FROM procurement_inspection_items q
                    WHERE q.receipt_type=%1$s AND q.receipt_id=%2$s AND q.receipt_item_id=%3$s
                      AND q.status<>'REVERSED' AND q.quantity_tranche='CHARGED'
                ) receipt_progress ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(task.qty),0) AS pending_qty,COUNT(*) AS task_count,
                           (array_agg(task.arrival_exception_id ORDER BY task.id))[1] AS exception_id,
                           (array_agg(task.owner_user_id ORDER BY task.id))[1] AS owner_user_id,
                           string_agg(DISTINCT employee.full_name,'、' ORDER BY employee.full_name) AS owner_name
                    FROM procurement_arrival_exceptions arrival
                    JOIN supplier_return_tasks task ON task.arrival_exception_id=arrival.id
                    LEFT JOIN employees employee ON employee.id=task.owner_employee_id
                    WHERE arrival.order_type=%1$s AND arrival.receipt_id=%2$s AND arrival.receipt_item_id=%3$s
                      AND task.status='PENDING_RETURN'
                ) surplus_return ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(rejection.failed_base_qty / NULLIF(q.unit_rate,0)),0) AS pending_qty
                    FROM procurement_iqc_rejection_cases rejection
                    JOIN procurement_inspection_items q ON q.id=rejection.inspection_item_id
                    WHERE q.receipt_type=%1$s AND q.receipt_id=%2$s AND q.receipt_item_id=%3$s
                      AND q.status<>'REVERSED' AND q.quantity_tranche='CHARGED'
                      AND NOT COALESCE(rejection.is_deleted,FALSE) AND rejection.status<>'REVERSED'
                      AND rejection.return_recorded_at IS NULL
                ) quality_return ON TRUE
                """.formatted(type,receipt,item);
    }

    // Decimal strings retain PostgreSQL precision through JSON and Dart. The unit is the receipt's own unit.
    public static String data(String unit) {
        return """
                jsonb_build_object('stockedQty',receipt_progress.stocked_qty::text,
                    'pendingStockInQty',receipt_progress.pending_stock_qty::text,
                    'pendingReturnQty',(surplus_return.pending_qty+quality_return.pending_qty)::text,
                    'surplusReturnQty',surplus_return.pending_qty::text,'qualityReturnQty',quality_return.pending_qty::text,'waitingInspection',receipt_progress.open_inspection_count>0,
                    'progressUnitName',%s,'returnOwnerName',surplus_return.owner_name,
                    'returnExceptionId',CASE WHEN surplus_return.task_count=1 THEN surplus_return.exception_id END,
                    'returnOwnerUserId',CASE WHEN surplus_return.task_count=1 THEN surplus_return.owner_user_id END)
                """.formatted(unit);
    }

    public static void describe(Map<String,Object> data, AuthUser actor, String status) {
        Object owner=data.remove("returnOwnerUserId");
        boolean canView=actor.getPermissions().contains("supplier_return_task:view")
                && (actor.getId().toString().equals(String.valueOf(owner))
                    || actor.getEmployeeId()!=null && actor.isAccountNonLocked() && !actor.isMustChangePassword()
                       && actor.getPermissions().contains("supplier_return_task:view:all"));
        data.put("canViewSupplierReturn",canView && data.containsKey("returnExceptionId"));
        String next;
        if (positive(data,"pendingStockInQty")) next="合格部分待仓库入库";
        else next="";
        if (Boolean.TRUE.equals(data.get("waitingInspection"))) next+=(next.isEmpty()?"":"；")+"等待品质检验";
        if (status.endsWith("_EXCEPTION_RECEIPT_ADJUSTED")) next="按批准量继续送检";
        if (positive(data,"surplusReturnQty")) {
            String name=String.valueOf(data.getOrDefault("returnOwnerName","采购/委外负责人"));
            next+=(next.isEmpty()?"":"；")+"由"+name+"退回供应商";
        }
        if (positive(data,"qualityReturnQty")) {
            next+=(next.isEmpty()?"":"；")+"不合格品在质检结果办理退回";
        }
        if (next.isEmpty() && status.endsWith("_STOCKED")) next="入库已完成";
        if (!next.isEmpty()) data.put("nextStep",next);
    }

    private static boolean positive(Map<String,Object> data,String key) {
        Object value=data.get(key);
        return value!=null && new BigDecimal(value.toString()).signum()>0;
    }
}
