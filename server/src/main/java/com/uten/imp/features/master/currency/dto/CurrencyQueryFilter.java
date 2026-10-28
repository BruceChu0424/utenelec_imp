package com.uten.imp.features.master.currency.dto;

import java.util.Set;

/**
 * 币种列表查询条件值对象（keyword + 字段精确筛选 + 空值字段集合）。
 *
 * <p>扁平主档无 categoryId。{@code nullFields} 存放"筛空值"的字段名（实体属性名），
 * 由 Service 端白名单校验后再生成 {@code is null} 谓词，避免任意属性路径。
 */
public record CurrencyQueryFilter(
        String keyword,
        Set<String> nullFields,
        String code,
        String name,
        String status,
        java.util.Map<String, String> columnSearch) {
    public CurrencyQueryFilter(String keyword, Set<String> nullFields, String code, String name, String status) {
        this(keyword, nullFields, code, name, status, java.util.Map.of());
    }
    public CurrencyQueryFilter withColumnSearch(java.util.Map<String, String> searches) {
        return new CurrencyQueryFilter(keyword, nullFields, code, name, status,
                searches == null ? java.util.Map.of() : java.util.Collections.unmodifiableMap(new java.util.LinkedHashMap<>(searches)));
    }
}
