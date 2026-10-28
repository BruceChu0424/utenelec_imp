package com.uten.imp.audit;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import jakarta.servlet.http.HttpServletRequest;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Search only recorded, redacted evidence. Never search the raw protected snapshots. */
final class AuditEventHeaderQuery {
    private AuditEventHeaderQuery() { }
    static Map<String, String> from(HttpServletRequest request) {
        return validate(request == null ? Map.of() : ColumnKeywordSearch.requestValues(request));
    }
    static Map<String, String> validate(Map<String, String> values) {
        var safe = ColumnKeywordSearch.validate(values, Set.of("device", "change"));
        String change = safe.get("change");
        if (change != null && !Set.of("recorded", "unrecorded").contains(change)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "变化摘要筛选条件无效");
        }
        return Map.copyOf(safe);
    }
    static void append(Root<AuditLog> root, CriteriaBuilder cb, List<Predicate> result,
                       Map<String, String> values) {
        String device = values.get("device");
        if (device != null) {
            for (String word : KeywordSearch.terms(device)) {
                String pattern = KeywordSearch.containsPattern(word);
                List<Predicate> fields = new ArrayList<>();
                for (String field : List.of("deviceName", "deviceModel", "devicePlatform")) {
                    fields.add(cb.like(cb.lower(root.get(field)), pattern, '\\'));
                }
                result.add(cb.or(fields.toArray(new Predicate[0])));
            }
        }
        String change = values.get("change");
        if (change != null) {
            Predicate recorded = cb.and(
                    cb.equal(cb.function("jsonb_typeof", String.class, root.get("before")), "object"),
                    cb.equal(cb.function("jsonb_typeof", String.class, root.get("after")), "object"),
                    cb.notEqual(root.get("before"), root.get("after")));
            // SQL NOT(NULL) is unknown. Use CASE so missing evidence is an
            // explicit unrecorded choice rather than silently excluded.
            var flag = cb.<Integer>selectCase().when(recorded, 1).otherwise(0);
            result.add(cb.equal(flag, change.equals("recorded") ? 1 : 0));
        }
    }
}
