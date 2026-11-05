package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.data.jpa.domain.Specification;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** The owning list predicate remains authoritative; selection only narrows it. */
public final class MasterExportSelection implements AutoCloseable {
    public static final int MAX_IDS = 50_000;
    public static final int MAX_JSON_BYTES = 2_000_002;
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
        try {
            var value = json.readTree(raw);
            if (value == null || !value.isArray() || value.isEmpty() || value.size() > MAX_IDS) throw invalid();
            List<UUID> ids = new ArrayList<>(value.size());
            for (var node : value) {
                if (!node.isTextual()) throw invalid();
                UUID id = UUID.fromString(node.textValue());
                if (!id.toString().equals(node.textValue())) throw invalid();
                ids.add(id);
            }
            validate(ids); return List.copyOf(ids);
        } catch (java.io.IOException | IllegalArgumentException failure) { throw invalid(); }
    }
    public static Set<UUID> validate(List<UUID> ids) {
        if (ids.isEmpty() || ids.size() > MAX_IDS || ids.stream().anyMatch(Objects::isNull)) throw invalid();
        Set<UUID> values = new LinkedHashSet<>(ids);
        if (values.size() != ids.size() || values.contains(new UUID(0, 0))) throw invalid();
        return Collections.unmodifiableSet(values);
    }
    public static <T> Specification<T> intersect(Specification<T> original) {
        var ids = CURRENT.get();
        if (ids == null) return original;
        Specification<T> selected = (root, query, cb) -> {
            if(ids.size()<=1024)return root.get("id").in(ids);
            // Hibernate's enabled IN-padding must not expand 50,000 UUIDs to
            // 65,536 binds (beyond PostgreSQL's 65,535 statement parameter cap).
            // Power-of-two chunks retain one original snapshot and predicate.
            List<UUID> values=new ArrayList<>(ids);
            List<jakarta.persistence.criteria.Predicate> parts=new ArrayList<>();
            for(int start=0;start<values.size();start+=1024)
                parts.add(root.get("id").in(values.subList(start,Math.min(values.size(),start+1024))));
            return cb.or(parts.toArray(jakarta.persistence.criteria.Predicate[]::new));
        };
        return original == null ? selected : original.and(selected);
    }
    public static void requireComplete(long count) {
        var ids = CURRENT.get();
        if (ids != null && count != ids.size())
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "已选资料已变化或不在当前筛选及权限范围内，请刷新并重新选择；本次未生成文件");
    }
    public static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "导出选中资料须为1至50000个不重复的有效系统标识");
    }
    @Override public void close() { if (previous == null) CURRENT.remove(); else CURRENT.set(previous); }
}
