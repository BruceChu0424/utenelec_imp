package com.uten.imp.features.master.learning;

import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 从服务端保存的识别结果(ai_jobs.result, SPEC §5.9 {@code lines[]})里取学习要用的几项。
 *
 * <p>学习只信这里的原文: 保存请求里的文件型号/品名只有和识别结果里同一行键({@code key})的原文
 * 规范化后一致, 才算「来自文件」, 才能学成全局对照或货品英文名称。结果结构不对时按「没有识别结果」处理,
 * 从不抛异常影响保存。
 */
final class IntakeJobLines {

    /** 识别结果里的一行(只取学习需要的字段)。 */
    record JobLine(String key, String partNo, String description, String descriptionAlt,
                   String contextNorm, String status, UUID selectedGoodsId, String nameEnText) {

        boolean matchedUnchanged(UUID savedGoodsId) {
            return "MATCHED".equals(status) && selectedGoodsId != null && selectedGoodsId.equals(savedGoodsId);
        }
    }

    private static final IntakeJobLines EMPTY = new IntakeJobLines(Map.of());

    private final Map<String, JobLine> byKey;

    private IntakeJobLines(Map<String, JobLine> byKey) {
        this.byKey = byKey;
    }

    static IntakeJobLines empty() {
        return EMPTY;
    }

    boolean isEmpty() {
        return byKey.isEmpty();
    }

    JobLine line(String key) {
        return key == null ? null : byKey.get(key);
    }

    /** 解析识别结果; 任何结构问题都退化为空(没有识别结果)。 */
    static IntakeJobLines parse(Map<String, Object> result) {
        if (result == null) return EMPTY;
        Object lines = result.get("lines");
        if (!(lines instanceof List<?> list) || list.isEmpty()) return EMPTY;
        Map<String, JobLine> out = new HashMap<>();
        for (Object item : list) {
            if (!(item instanceof Map<?, ?> line)) continue;
            String key = text(line.get("key"));
            if (key == null || key.isBlank()) continue;
            out.put(key, new JobLine(
                    key,
                    text(line.get("partNo")),
                    text(line.get("description")),
                    text(line.get("descriptionAlt")),
                    text(line.get("contextNorm")),
                    text(line.get("status")),
                    uuid(line.get("selectedGoodsId")),
                    text(line.get("nameEnText"))));
        }
        return out.isEmpty() ? EMPTY : new IntakeJobLines(Collections.unmodifiableMap(out));
    }

    /** Namespace per-file row keys before planning once for the whole document. */
    static IntakeJobLines combine(UUID primary, Map<UUID, Map<String, Object>> results) {
        Map<String, JobLine> combined = new HashMap<>();
        results.forEach((jobId, result) -> {
            IntakeJobLines parsed = parse(result);
            parsed.byKey.forEach((key, line) -> {
                combined.put(jobId + ":" + key, line);
                if (jobId.equals(primary)) combined.put(key, line); // Legacy single-file clients.
            });
        });
        return new IntakeJobLines(Collections.unmodifiableMap(combined));
    }

    private static String text(Object value) {
        if (value == null) return null;
        if (value instanceof String s) return s;
        if (value instanceof Number || value instanceof Boolean) return value.toString();
        return null;
    }

    private static UUID uuid(Object value) {
        if (value instanceof UUID id) return id;
        if (!(value instanceof String s) || s.isBlank()) return null;
        try {
            return UUID.fromString(s.trim());
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }
}
