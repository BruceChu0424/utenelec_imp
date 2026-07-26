package com.uten.imp.features.master.account.dto;

import java.util.Set;
import java.util.UUID;

/**
 * 账户列表查询条件值对象（keyword + 字段精确筛选 + 空值字段集合）。
 *
 * <p>扁平主档。{@code nullFields} 存放"筛空值"的字段名（实体属性名），
 * 由 Service 端白名单校验后再生成 {@code is null} 谓词，避免任意属性路径。
 */
public record AccountQueryFilter(
        String keyword,
        Set<String> nullFields,
        String code,
        String name,
        String accountType,
        UUID currencyId,
        String status) {
}
