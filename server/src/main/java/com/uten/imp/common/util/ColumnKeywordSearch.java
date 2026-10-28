package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.servlet.http.HttpServletRequest;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Column terms are ANDed before pagination; field resolution is always server-owned. */
public final class ColumnKeywordSearch {
    public static final Set<String> CONTACT_SENSITIVE = Set.of("mobile", "phone", "phone2", "bankAccount", "bankAccountNo");
    private ColumnKeywordSearch() { }

    /** Direct Java/security-test calls have no servlet request; HTTP calls use the bound request. */
    public static HttpServletRequest currentRequest() {
        var attributes=org.springframework.web.context.request.RequestContextHolder.getRequestAttributes();
        return attributes instanceof org.springframework.web.context.request.ServletRequestAttributes servlet?servlet.getRequest():null;
    }

    public static Map<String, String> requestValues(HttpServletRequest request) {
        return requestValues(request, null, false);
    }

    public static Map<String, String> contactRequestValues(HttpServletRequest request, Map<String, String> body) {
        return requestValues(request, body, true);
    }

    private static Map<String, String> requestValues(HttpServletRequest request, Map<String, String> body, boolean contact) {
        Map<String, String> result = new LinkedHashMap<>();
        if (request != null) request.getParameterMap().forEach((key, values) -> {
            if (!key.startsWith("search.")) return;
            String field = key.substring(7);
            if (contact && CONTACT_SENSITIVE.contains(field))
                throw invalid("手机、电话和银行账号的列搜索须通过请求体提交");
            if (values.length != 1) throw invalid("同一列只能提交一个搜索关键词");
            result.put(field, values[0]);
        });
        if (body != null) result.putAll(body);
        return result;
    }

    public static Map<String, String> validate(Map<String, String> searches, Set<String> allowed) {
        if (searches == null || searches.isEmpty()) return Map.of();
        if (searches.size() > 160) throw invalid("列搜索条件过多");
        Map<String, String> result = new LinkedHashMap<>();
        searches.forEach((key, value) -> {
            // Keep the server's declared key, not the equal request String: callers
            // may use this key in fixed SQL parameter namespaces and projections.
            String declared = allowed.stream().filter(candidate -> candidate.equals(key)).findFirst()
                    .orElseThrow(() -> invalid("此列不支持搜索：" + key));
            if (value == null || value.isBlank()) return;
            if (value.length() > 200) throw invalid("每列搜索关键词不能超过 200 个字符");
            if (!KeywordSearch.terms(value).isEmpty()) result.put(declared, value.strip());
        });
        return result;
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
