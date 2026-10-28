package com.uten.imp.features.companyfiles;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.JpaColumnSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** Apply only after the entry's complete ACL/password visibility decision. */
final class CompanyFileHeaderQuery {
    private final Map<String, String> terms;
    private final NumericColumnFilter size;
    private final JpaColumnSearch.DateBounds updated;

    CompanyFileHeaderQuery(Map<String, String> input) {
        terms = Map.copyOf(ColumnKeywordSearch.validate(input,
                Set.of("name", "kind", "type", "size", "updatedBy", "updated")));
        String kind = terms.get("kind");
        if (kind != null && !Set.of("folder", "file").contains(kind))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "文件类型筛选无效");
        size = terms.containsKey("size") ? NumericColumnFilter.parse(terms.get("size")) : null;
        updated = terms.containsKey("updated")
                ? JpaColumnSearch.businessDateBounds(terms.get("updated")) : null;
    }

    boolean isEmpty() { return terms.isEmpty(); }

    boolean matches(String kind, String name, Long knownSize, String updatedBy, Instant updatedAt) {
        boolean folder = "FOLDER".equals(kind);
        if (terms.containsKey("kind") && !terms.get("kind").equals(folder ? "folder" : "file")) return false;
        if (!KeywordSearch.matches(terms.get("name"), name)
                || !KeywordSearch.matches(terms.get("updatedBy"), updatedBy)) return false;
        int dot = name.lastIndexOf('.');
        String type = folder ? "文件夹 folder 폴더"
                : dot < 0 || dot == name.length() - 1 ? "文件 file 파일"
                : name.substring(dot + 1).toLowerCase(Locale.ROOT);
        if (!KeywordSearch.matches(terms.get("type"), type)) return false;
        if (size != null && !size.matches(knownSize == null ? null : BigDecimal.valueOf(knownSize))) return false;
        return updated == null || updatedAt != null
                && !updatedAt.isBefore(updated.from().toInstant())
                && updatedAt.isBefore(updated.toExclusive().toInstant());
    }
}
