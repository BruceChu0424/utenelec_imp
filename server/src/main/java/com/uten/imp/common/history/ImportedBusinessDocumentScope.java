package com.uten.imp.common.history;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.HeaderColumnFilter;
import jakarta.persistence.Table;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import java.lang.reflect.RecordComponent;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Set;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/** One origin contract for business lists; master records and physical stock are not documents. */
public final class ImportedBusinessDocumentScope {
    public enum Origin { CURRENT, LEGACY, ALL }
    private static final Set<String> LIFECYCLE_FILTERS = Set.of(
            "status", "sourceStatus", "closed", "stopped", "financeApproval", "financeStatus", "lifecycle",
            "issueStatus", "standaloneDrafts", "productionReturnRequests", "financeConfirmed", "financeRejected");
    private ImportedBusinessDocumentScope() { }

    public static Origin origin() {
        var attributes = RequestContextHolder.getRequestAttributes();
        String value = attributes instanceof ServletRequestAttributes request
                ? request.getRequest().getParameter("originScope") : null;
        if (value == null || value.isBlank()) return Origin.CURRENT;
        try { return Origin.valueOf(value.strip().toUpperCase(Locale.ROOT)); }
        catch (IllegalArgumentException invalid) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "单据来源筛选须为 CURRENT、LEGACY 或 ALL");
        }
    }

    public static boolean legacyOnly() { return origin() == Origin.LEGACY; }

    /** The database function also recognizes provenance-only imports and imported parent ownership. */
    public static Predicate predicate(Root<?> root, CriteriaBuilder cb) {
        Origin origin = origin();
        if (origin == Origin.ALL) return cb.conjunction();
        var imported = imported(root, cb);
        return origin == Origin.LEGACY ? cb.isTrue(imported) : cb.isFalse(imported);
    }

    /** Action queues and source selectors never inherit a caller's historical-list scope. */
    public static Predicate nativeOnly(Root<?> root, CriteriaBuilder cb) { return cb.isFalse(imported(root, cb)); }

    /** Existing native-history segments must not hide source 0/-1 imports. */
    public static Predicate lifecycle(Root<?> root, CriteriaBuilder cb, Predicate nativeLifecycle) {
        return switch (origin()) {
            case CURRENT -> nativeLifecycle;
            case LEGACY -> cb.conjunction();
            case ALL -> cb.or(cb.isTrue(imported(root, cb)), nativeLifecycle);
        };
    }

    private static jakarta.persistence.criteria.Expression<Boolean> imported(Root<?> root, CriteriaBuilder cb) {
        Table table = root.getJavaType().getAnnotation(Table.class);
        if (table == null) throw new IllegalArgumentException("Business origin requires a mapped table");
        return cb.function("fn_imported_business_document", Boolean.class, cb.literal(table.name()), root.get("id"));
    }

    public static String importedSql(String alias) {
        if (!alias.matches("[a-zA-Z_][a-zA-Z0-9_]*")) throw new IllegalArgumentException("Invalid internal SQL alias");
        return "(NULLIF(to_jsonb(" + alias + ")->>'legacy_id','') IS NOT NULL"
                + " OR NULLIF(to_jsonb(" + alias + ")->>'legacy_import_run_id','') IS NOT NULL)";
    }

    public static String currentSql(String alias) { return "NOT " + importedSql(alias); }

    public static String predicateSql(String alias) {
        return switch (origin()) {
            case CURRENT -> currentSql(alias);
            case LEGACY -> importedSql(alias);
            case ALL -> "TRUE";
        };
    }

    /** Ignore automatic lifecycle segments in legacy history; explicit dates/search/ownership remain. */
    @SuppressWarnings("unchecked")
    public static <T> T historyFilter(T input) {
        if (input == null || origin() == Origin.CURRENT) return input;
        Class<?> type = input.getClass();
        if (!type.isRecord()) throw new IllegalArgumentException("Business history filter must be an immutable record");
        RecordComponent[] components = type.getRecordComponents();
        Object[] values = new Object[components.length];
        try {
            for (int index = 0; index < components.length; index++) {
                var component = components[index];
                Object value = component.getAccessor().invoke(input);
                if (LIFECYCLE_FILTERS.contains(component.getName())) {
                    value = component.getType() == boolean.class ? false : null;
                } else if (value instanceof HeaderColumnFilter headers) {
                    var retained = new LinkedHashMap<>(headers.values());
                    retained.remove("apPosted");
                    value = new HeaderColumnFilter(retained);
                }
                values[index] = value;
            }
            return (T) type.getDeclaredConstructor(Arrays.stream(components).map(RecordComponent::getType)
                    .toArray(Class<?>[]::new)).newInstance(values);
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException("Cannot preserve business history filter contract", failure);
        }
    }
}
