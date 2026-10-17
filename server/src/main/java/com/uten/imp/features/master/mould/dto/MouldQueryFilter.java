package com.uten.imp.features.master.mould.dto;

import java.util.Set;
import java.util.UUID;

/**
 * 模具列表查询条件值对象（聚合多字段筛选 + keyword + 空值字段集合）。
 *
 * <p>与 {@code GoodsQueryFilter} 同构。{@code nullFields} 存放"筛空值"的字段名
 * （实体属性名），由 Service 端白名单校验后再生成 {@code is null} 谓词，避免任意属性路径。
 *
 * <p>仅含表格中"有数据"的 7 列（编号/名称/存放位置/制造日期/制造商/备注/状态）；模数/套数/
 * 模具类型无对应 DB 列，不参与筛选，故不在此 record。
 */
public record MouldQueryFilter(
        UUID categoryId,
        String keyword,
        Set<String> nullFields,
        String code,
        String name,
        String place,
        String mstatus,
        String remark,
        String status,
        String manufacturer,
        java.util.Map<String, String> columnSearch) {
    public MouldQueryFilter(UUID categoryId, String keyword, Set<String> nullFields, String code, String name,
            String place, String mstatus, String remark, String status, String manufacturer) {
        this(categoryId, keyword, nullFields, code, name, place, mstatus, remark, status, manufacturer, java.util.Map.of());
    }

    public MouldQueryFilter withColumnSearch(java.util.Map<String, String> search) {
        return new MouldQueryFilter(categoryId, keyword, nullFields, code, name, place, mstatus, remark,
                status, manufacturer, search);
    }
}
