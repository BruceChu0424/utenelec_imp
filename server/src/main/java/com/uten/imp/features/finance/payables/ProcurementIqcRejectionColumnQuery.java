package com.uten.imp.features.finance.payables;

import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Header criteria use the same visible case facts and never infer unavailable prices. */
final class ProcurementIqcRejectionColumnQuery {
    private ProcurementIqcRejectionColumnQuery() {}
    private static final String OPEN_HOLD = "IQC不合格实物退回及供应商贷项尚未闭环";
    private static final String UNKNOWN = "状态未知，请刷新或联系管理员";
    private static final Map<String, String> NEXT_STEPS = Map.of(
            "PENDING_RETURN", "下一步：登记真实退回凭证",
            "RETURN_RECORDED", "下一步：财务确认贷项或零金额结案",
            "FINANCE_EXCEPTION", "下一步：修复后重试财务投影",
            "CREDIT_CONFIRMED", "供应商贷项已闭环",
            "CLOSED_NO_CREDIT", "零金额无需贷项，已结案",
            "REVERSED", "下游已反向");
    private static final List<Map.Entry<String,String>> REASONS=List.copyOf(NEXT_STEPS.entrySet());

    /** Business labels remain data even when they participate in a filter or ordering. */
    private static String nextStepSql() {
        StringBuilder sql = new StringBuilder("CASE rejection.status");
        for(int index=0;index<REASONS.size();index++) {
            sql.append(" WHEN :iqc_reason_status_").append(index)
                    .append(" THEN :iqc_reason_label_").append(index);
        }
        return sql.append(" ELSE '").append(UNKNOWN).append("' END").toString();
    }
    static final String DISPLAY_REASON_SQL = "COALESCE(NULLIF(regexp_replace(rejection.finance_exception_message,"
            + "'^[[:space:]]+|[[:space:]]+$','','g'),''),"
            + "CASE WHEN rejection.status IN ('PENDING_RETURN','RETURN_RECORDED') THEN '" + OPEN_HOLD
            + "' ELSE " + nextStepSql() + " END)";

    static String displayReason(String status, String financeMessage, String holdReason) {
        if (financeMessage != null && !financeMessage.isBlank()) return financeMessage.strip();
        if (holdReason != null && !holdReason.isBlank()) return holdReason.strip();
        return status == null ? UNKNOWN : NEXT_STEPS.getOrDefault(status, UNKNOWN);
    }

    record Read(SqlColumnSearch.Criteria criteria, String orderBy, boolean explicitOrder,
                Map<String,Object> orderParameters) {
        void bindOrder(jakarta.persistence.Query query) { orderParameters.forEach(query::setParameter); }
    }
    static Read read(Map<String, String> parameters, boolean amountVisible) {
        Map<String, String> request = parameters == null ? Map.of() : parameters;
        String sort = request.get("sort");
        if (sort != null) sort = sort.strip();
        String amount = request.get("search.amount");
        if (!amountVisible && ((amount != null && !amount.isBlank()) || "amount".equals(sort))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "没有金额查看权限，不能按不合格金额筛选或排序");
        }
        Map<String, SqlColumnSearch.Field> fields = new LinkedHashMap<>(Map.of(
                "receiptBillNo", SqlColumnSearch.Field.text("rejection.receipt_bill_no"),
                "orderBillNo", SqlColumnSearch.Field.text("rejection.order_bill_no"),
                "supplierName", SqlColumnSearch.Field.text("supplier.name"),
                "goodsName", SqlColumnSearch.Field.text("goods.name"),
                "goodsCode", SqlColumnSearch.Field.text("goods.code"),
                "colorName", SqlColumnSearch.Field.text("color.name"),
                "failedQty", SqlColumnSearch.Field.decimal("rejection.failed_qty"),
                "holdReason", SqlColumnSearch.Field.text(DISPLAY_REASON_SQL)));
        if (amountVisible) fields.put("amount", SqlColumnSearch.Field.decimal("rejection.failed_amount_local"));
        Map<String, String> searches = new LinkedHashMap<>();
        request.forEach((key, value) -> { if (key.startsWith("search.")) searches.put(key.substring(7), value); });
        var criteria = SqlColumnSearch.criteria(searches, fields);
        String ordering = "rejection.created_at DESC,rejection.id";
        boolean explicit = sort != null && !sort.isEmpty();
        if (explicit) {
            var field = fields.get(sort);
            String direction = request.getOrDefault("order", "asc");
            if (field == null || !Set.of("asc", "desc").contains(direction.toLowerCase(java.util.Locale.ROOT))) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "IQC不合格任务排序字段或方向无效");
            }
            ordering = field.expression() + ("desc".equalsIgnoreCase(direction) ? " DESC" : " ASC")
                    + " NULLS LAST,rejection.created_at DESC,rejection.id";
        }
        Map<String,Object> labels=new LinkedHashMap<>();
        if(criteria.predicate().contains(":iqc_reason_")||ordering.contains(":iqc_reason_")) {
            for(int index=0;index<REASONS.size();index++) {
                labels.put("iqc_reason_status_"+index,REASONS.get(index).getKey());
                labels.put("iqc_reason_label_"+index,REASONS.get(index).getValue());
            }
        }
        if(criteria.predicate().contains(":iqc_reason_")) {
            Map<String,Object> bindings=new LinkedHashMap<>(criteria.parameters());
            bindings.putAll(labels);
            criteria=new SqlColumnSearch.Criteria(criteria.predicate(),Map.copyOf(bindings));
        }
        return new Read(criteria, ordering, explicit,
                ordering.contains(":iqc_reason_")?Map.copyOf(labels):Map.of());
    }
}
