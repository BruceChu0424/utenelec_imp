package com.uten.imp.features.finance.report;

import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.ContactSensitiveFilter;
import java.util.*;

/** Preserve old controller signatures while enforcing body-only contact values. */
final class FinanceReportHeaderRequest {
    private FinanceReportHeaderRequest() { }
    static Map<String, String> current() {
        var request = ColumnKeywordSearch.currentRequest();
        Map<String, String> values = new LinkedHashMap<>();
        if (request != null) request.getParameterMap().forEach((key, items) -> {
            if (items.length != 1) throw invalid("同一查询条件只能提交一次");
            values.put(key, items[0]);
        });
        return values;
    }
    static Map<String, String> filters(Map<String, String> parameters) {
        Map<String, String> result = ReportQueryKit.facetsOf(parameters);
        if (parameters == null) return result;
        parameters.forEach((key,value) -> { if (key.startsWith("search.")) result.put(key,value); });
        return result;
    }
    static void requireBodyOnly(Map<String, String> parameters) {
        if (parameters == null) return;
        for (String key : parameters.keySet()) {
            String field = key.startsWith("f.search.") ? key.substring(9)
                    : key.startsWith("search.") ? key.substring(7)
                    : key.startsWith("f.") ? key.substring(2) : key;
            if (ColumnKeywordSearch.CONTACT_SENSITIVE.contains(field))
                throw invalid("联系方式筛选须通过请求体提交");
        }
    }
    static Map<String, String> withContactBody(Map<String, String> parameters, ContactSensitiveFilter body) {
        requireBodyOnly(parameters);
        Map<String, String> result = new LinkedHashMap<>(parameters == null ? Map.of() : parameters);
        if (body == null) return result;
        ContactSensitiveFilter.requireBoundedReadValues(body.keyword(),body.mobile(),body.phone(),body.phone2(),body.bankAccount());
        if (body.mobile() != null || body.phone2() != null || body.bankAccount() != null)
            throw invalid("此报表不支持该联系方式条件");
        if (body.keyword() != null && !body.keyword().isBlank()) result.put("keyword",body.keyword());
        if (body.phone() != null && !body.phone().isBlank()) result.put("f.search.phone",body.phone());
        if (body.columnSearch() != null) body.columnSearch().forEach((key,value) -> {
            if (!key.equals("phone")) throw invalid("此报表不支持该联系方式条件");
            if (value != null && !value.isBlank()) result.put("f.search."+key,value);
        });
        return result;
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
