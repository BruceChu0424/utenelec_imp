package com.uten.imp.common.web;

import org.springframework.data.domain.Sort;

import java.util.Map;

/**
 * 表格列排序解析（主档 / 单据列表等 JPA 分页查询共用）。
 *
 * <p>把前端 {@code sort}(列 key) / {@code order}(asc|desc) 安全映射成 Spring Data {@link Sort}：
 * {@code sort} 必须命中 {@code allowed}（前端列 key → JPA 实体属性名，服务端权威白名单，非用户串），
 * 命中才按该实体属性排序；{@code order} 只认 {@code asc}/{@code desc}（其余一律按升序）。
 * 命中失败 / 为空 → 回落 {@code defaultSort}。绝不把用户原始串当属性名拼入。
 *
 * <p>与报表的 {@code com.uten.imp.common.report.ReportSort}（按 SQL 投影别名 ORDER BY）对应：
 * 本工具面向 JPA {@code Specification}+{@code Pageable} 查询，按实体属性名排序
 * （Spring Data 会校验属性是否存在于实体，双重防注入）。
 */
public final class TableSort {

    private TableSort() {}

    /**
     * @param sort        前端列 key（如 "billDate" / "total"）
     * @param order       "asc" / "desc"（其它按升序）
     * @param defaultSort 未命中白名单时的兜底排序
     * @param allowed     前端列 key → JPA 实体属性名（如 "total" → "totalLocal"）
     */
    public static Sort resolve(String sort, String order, Sort defaultSort, Map<String, String> allowed) {
        if (sort == null || sort.isBlank() || allowed == null || !allowed.containsKey(sort)) {
            return defaultSort;
        }
        String prop = allowed.get(sort);
        if (prop == null || prop.isBlank()) {
            return defaultSort;
        }
        Sort.Direction dir = "desc".equalsIgnoreCase(order) ? Sort.Direction.DESC : Sort.Direction.ASC;
        return Sort.by(dir, prop);
    }
}
