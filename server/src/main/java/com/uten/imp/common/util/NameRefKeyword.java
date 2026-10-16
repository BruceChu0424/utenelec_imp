package com.uten.imp.common.util;

import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import jakarta.persistence.criteria.Subquery;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Path;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.Locale;
import java.util.function.Function;

/**
 * 关键词搜索的「按名称引用」子查询工具（2026-10-09「行里显示什么就能按什么搜」口径）。
 *
 * 单据表普遍只存 supplierId/clientId/warehouseId/accountId 等外键，列表页展示的却是
 * 名称列。这里把「名称 LIKE」翻译成「外键 IN (名称命中的主档 id 子查询)」，供各单据
 * 模块的 Specification 组 OR 使用——JPA Specification 的 count 由 Spring Data 从同一
 * 谓词派生，子查询对分页计数天然一致。
 *
 * 用法：
 * <pre>{@code
 * List<Predicate> kws = new ArrayList<>();
 * kws.add(cb.like(cb.lower(root.get("billNo")), kw));
 * NameRefKeyword.byName(kws, q, cb, root.get("supplierId"),
 *         com.uten.imp.features.master.supplier.Supplier.class, "name", kw);
 * ps.add(cb.or(kws.toArray(new Predicate[0])));
 * }</pre>
 */
public final class NameRefKeyword {

    private NameRefKeyword() {
    }

    /**
     * 追加一个「引用列 IN (主档名称 LIKE 的 id 子查询)」谓词。
     *
     * @param keywords    调用方累积的关键词谓词列表（直接追加，由调用方 cb.or 聚合）
     * @param entityClass 主档实体类（须有 id/name/deleted 字段）
     * @param nameField   名称字段名（主档按名称/编号两个字段都匹配时调用两次）
     */
    public static <X> void byName(
            List<Predicate> keywords,
            CriteriaQuery<?> query,
            CriteriaBuilder cb,
            jakarta.persistence.criteria.Expression<UUID> refId,
            Class<X> entityClass,
            String nameField,
            String likePattern) {
        Subquery<UUID> sub = query.subquery(UUID.class);
        Root<X> master = sub.from(entityClass);
        sub.select(master.<UUID>get("id")).where(
                cb.isFalse(master.get("deleted")),
                text(cb, master.get(nameField), likePattern));
        keywords.add(refId.in(sub));
    }

    /** 关键词 LIKE 模式（小写、两侧通配）；调用方与主档字段两侧保持同一模式。 */
    public static String like(String keyword) {
        return KeywordSearch.containsPattern(keyword.trim().toLowerCase(Locale.ROOT));
    }

    public static Predicate text(CriteriaBuilder cb, Expression<String> field, String pattern) {
        return cb.like(cb.lower(field), pattern, '\\');
    }

    /** The same field contract builds all term predicates and relevance tiers. */
    public static Predicate match(Root<?> root, CriteriaQuery<?> query, CriteriaBuilder cb,
                                  String keyword, Function<String, Predicate> fields) {
        List<String> terms = KeywordSearch.terms(keyword);
        if (terms.isEmpty()) return cb.conjunction();
        Predicate[] required = terms.stream().map(term -> fields.apply(like(term)))
                .toArray(Predicate[]::new);
        if (query != null && root.getJavaType() != null && root.getJavaType().equals(query.getResultType())) {
            String phrase = KeywordSearch.phrase(keyword);
            String exactPattern = KeywordSearch.containsPattern(phrase);
            exactPattern = exactPattern.substring(1, exactPattern.length() - 1);
            Predicate exact = fields.apply(exactPattern);
            Predicate prefix = fields.apply(exactPattern + "%");
            Predicate everyPrefix = cb.and(terms.stream().map(term -> {
                String pattern = like(term);
                return fields.apply(pattern.substring(1));
            }).toArray(Predicate[]::new));
            query.orderBy(cb.asc(cb.<Integer>selectCase().when(exact, 0)
                    .when(prefix, 1).when(everyPrefix, 2).otherwise(3)));
        }
        return cb.and(required);
    }

    public record SearchPage<T>(Specification<T> specification, Pageable pageable) {}

    /** Keep relevance before the approved column order, before pagination. */
    public static <T> SearchPage<T> page(Specification<T> filter, Pageable pageable, String keyword) {
        if (KeywordSearch.terms(keyword).isEmpty()) return new SearchPage<>(filter, pageable);
        Specification<T> ranked = (root, query, cb) -> {
            Predicate predicate = filter.toPredicate(root, query, cb);
            if (query != null && root.getJavaType() != null && root.getJavaType().equals(query.getResultType())) {
                var orders = new ArrayList<>(query.getOrderList());
                for (Sort.Order order : pageable.getSort()) {
                    Path<?> path = root;
                    for (String part : order.getProperty().split("\\.")) path = path.get(part);
                    orders.add(order.isAscending() ? cb.asc(path) : cb.desc(path));
                }
                // All consumers use scalar UUID ids; ties must stay stable across pages.
                if (pageable.getSort().getOrderFor("id") == null) orders.add(cb.asc(root.get("id")));
                query.orderBy(orders);
            }
            return predicate;
        };
        return new SearchPage<>(ranked, PageRequest.of(pageable.getPageNumber(), pageable.getPageSize()));
    }

    /** 便捷聚合：把已累积的关键词谓词合成一个 OR（空列表返回 null，由调用方跳过）。 */
    public static Predicate or(CriteriaBuilder cb, List<Predicate> keywords) {
        return keywords.isEmpty() ? null : cb.or(keywords.toArray(new Predicate[0]));
    }

    /** 新建一个关键词谓词累积列表（配合 {@link #byName} 使用）。 */
    public static List<Predicate> keywords() {
        return new ArrayList<>();
    }
}
