package com.uten.imp.common.web;

import jakarta.persistence.Query;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 原生 SQL facets 桶（2026-09-25 单号列统一）：把原生两列查询行 (单号, COUNT(*))
 * 映射成前端表头筛选拿的 {@code [{value, count, label}]}（label=value）。
 *
 * <p>与 {@link TableFacets} 配对：TableFacets 走 JPA {@code Specification} 分组计数，
 * 本工具面向 {@code em.createNativeQuery(...)} 的两列投影——各原生 SQL 服务
 * （列表 / 计数 / facets 同一过滤基座）共用的行映射，口径与 TableFacets 一致：
 * value 为 null 归空串，count 归 long；桶顺序即 SQL 的 ORDER BY。
 */
public final class NativeFacets {

    private NativeFacets() {}

    /** 单桶：{value, count, label=value}。 */
    public static Map<String, Object> bucket(String value, long count) {
        Map<String, Object> bucket = new LinkedHashMap<>();
        bucket.put("value", value);
        bucket.put("count", count);
        bucket.put("label", value);
        return bucket;
    }

    /** 原生查询行(value, count) → 桶列表；value null 归空串。 */
    public static List<Map<String, Object>> rows(List<Object[]> rows) {
        List<Map<String, Object>> buckets = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            String value = row[0] == null ? "" : row[0].toString();
            buckets.add(bucket(value, ((Number) row[1]).longValue()));
        }
        return buckets;
    }

    /** 便捷：执行查询并转换。 */
    @SuppressWarnings("unchecked")
    public static List<Map<String, Object>> rowsOf(Query query) {
        return rows((List<Object[]>) query.getResultList());
    }
}
