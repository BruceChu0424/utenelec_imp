package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.data.jpa.domain.Specification;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** The owning list predicate remains authoritative; selection only narrows it. */
public final class MasterExportSelection implements AutoCloseable {
    public static final int MAX_JSON_BYTES = ExportSelectionBudget.MAX_BYTES;
    private static final ThreadLocal<Set<UUID>> CURRENT = new ThreadLocal<>();
    private final Set<UUID> previous;
    private MasterExportSelection(List<UUID> ids) {
        previous = CURRENT.get();
        if (ids == null) CURRENT.remove(); else CURRENT.set(validate(ids));
    }
    public static MasterExportSelection open(List<UUID> ids) { return new MasterExportSelection(ids); }
    public static Set<UUID> current() { return CURRENT.get(); }
    public static List<UUID> parse(String raw, ObjectMapper json) {
        if (raw == null) return null;
        if (raw.getBytes(StandardCharsets.UTF_8).length > MAX_JSON_BYTES) throw invalid();
        try (var parser = json.getFactory().createParser(raw)) {
            if (parser.nextToken() != com.fasterxml.jackson.core.JsonToken.START_ARRAY) throw invalid();
            List<UUID> ids = new ArrayList<>();
            while (parser.nextToken() != com.fasterxml.jackson.core.JsonToken.END_ARRAY) {
                if (parser.currentToken() != com.fasterxml.jackson.core.JsonToken.VALUE_STRING) throw invalid();
                String value = parser.getText();
                UUID id = UUID.fromString(value);
                if (!id.toString().equals(value)) throw invalid();
                ids.add(id);
            }
            if (parser.nextToken() != null) throw invalid();
            validate(ids); return List.copyOf(ids);
        } catch (java.io.IOException | IllegalArgumentException failure) { throw invalid(); }
    }
    public static Set<UUID> validate(List<UUID> ids) {
        if (ids.isEmpty() || (long) ids.size() * 39 + 1 > MAX_JSON_BYTES || ids.stream().anyMatch(Objects::isNull)) throw invalid();
        Set<UUID> values = new LinkedHashSet<>(ids);
        if (values.size() != ids.size() || values.contains(new UUID(0, 0))) throw invalid();
        return Collections.unmodifiableSet(values);
    }
    public static <T> Specification<T> intersect(Specification<T> original) {
        var ids = CURRENT.get();
        if (ids == null) return original;
        Specification<T> selected = (root, query, cb) -> {
            if(ids.size()<=1024)return root.get("id").in(ids);
            // A single typed array parameter avoids PostgreSQL's scalar-bind
            // ceiling and IN-padding. The authorized list predicate and its
            // repeatable-read cursor still own ordering and completeness.
            return cb.isTrue(cb.function("array_contains", Boolean.class,
                    ((org.hibernate.query.criteria.HibernateCriteriaBuilder) cb).value(ids.toArray(UUID[]::new)), root.get("id")));
        };
        return original == null ? selected : original.and(selected);
    }
    public static void requireComplete(long count) {
        var ids = CURRENT.get();
        if (ids != null && count != ids.size())
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "已选资料已变化或不在当前筛选及权限范围内，请刷新并重新选择；本次未生成文件");
    }
    public static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "导出选中资料须为不重复的有效系统标识，且不超过请求空间预算");
    }
    @Override public void close() { if (previous == null) CURRENT.remove(); else CURRENT.set(previous); }
}
