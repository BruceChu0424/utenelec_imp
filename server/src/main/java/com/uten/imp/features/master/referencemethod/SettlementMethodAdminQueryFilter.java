package com.uten.imp.features.master.referencemethod;

import java.util.Set;

/**
 * 结算方式管理页列表查询条件值对象（表头字段精确筛选 + 空值字段集合）。
 *
 * <p>管理页是全量小字典，不分页；{@code nullFields} 存放"筛空值"的字段名（实体属性名），
 * 由 Service 端白名单校验后再生成 {@code is null} 谓词，避免任意属性路径。
 */
public record SettlementMethodAdminQueryFilter(
        String status,
        String systemRole,
        String termsBase,
        String dueRule,
        Set<String> nullFields) {
}
