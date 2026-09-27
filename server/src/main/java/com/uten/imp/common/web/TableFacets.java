package com.uten.imp.common.web;

import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.springframework.data.jpa.domain.Specification;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 表格列值筛选 facets（2026-09-25 单号列统一）：按实体字符串属性分组计数，
 * 与列表查询共用同一份 {@link Specification} 谓词——桶的口径与列表行永远同源。
 *
 * <p>与 {@link TableSort} 配对：TableSort 管列排序白名单，本工具管列值桶。
 * 返回 {@code [{value, count, label}]}（label=value），value 升序；下拉超过
 * 6 项前端自动出搜索框。[limit] 上限防大表全量单号撑爆响应（默认 500）。
 */
public final class TableFacets {

    private TableFacets() {}

    public static final int DEFAULT_LIMIT = 500;

    public static <T> List<Map<String, Object>> groupCount(
            EntityManager em, Class<T> entity, Specification<T> spec, String property) {
        return groupCount(em, entity, spec, property, DEFAULT_LIMIT);
    }

    public static <T> List<Map<String, Object>> groupCount(
            EntityManager em, Class<T> entity, Specification<T> spec,
            String property, int limit) {
        CriteriaBuilder cb = em.getCriteriaBuilder();
        CriteriaQuery<Object[]> query = cb.createQuery(Object[].class);
        Root<T> root = query.from(entity);
        Predicate predicate = spec == null
                ? cb.conjunction() : spec.toPredicate(root, query, cb);
        query.multiselect(root.get(property), cb.count(root))
                .where(predicate)
                .groupBy(root.get(property))
                .orderBy(cb.asc(root.get(property)));
        List<Object[]> rows = em.createQuery(query)
                .setMaxResults(Math.max(1, limit))
                .getResultList();
        List<Map<String, Object>> buckets = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            String value = row[0] == null ? "" : row[0].toString();
            Map<String, Object> bucket = new LinkedHashMap<>();
            bucket.put("value", value);
            bucket.put("count", ((Number) row[1]).longValue());
            bucket.put("label", value);
            buckets.add(bucket);
        }
        return buckets;
    }
}
