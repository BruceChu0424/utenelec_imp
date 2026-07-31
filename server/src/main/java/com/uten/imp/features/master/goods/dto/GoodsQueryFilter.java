package com.uten.imp.features.master.goods.dto;

import java.util.Set;
import java.util.UUID;

/**
 * 货品列表查询条件值对象（聚合多字段筛选 + keyword + 空值字段集合）。
 *
 * <p>{@code nullFields} 存放"筛空值"的字段名（实体属性名），由 Service 端白名单校验后再生成
 * {@code is null} 谓词，避免任意属性路径。
 */
public record GoodsQueryFilter(
        UUID categoryId,
        String keyword,
        Set<String> nullFields,
        String series,
        String model,
        String material,
        String code,
        String name,
        String spec,
        String cNumber,
        String requireRemark,
        Integer colorLegacyId,
        Integer unitLegacyId,
        String sourceType,
        Boolean excludeDisabled,
        // V177：stub/禁用隔离（货品资料页集合行 + 滑窗隐藏 stub）
        Boolean excludeStub,    // 滑窗用：排除 auto_created=true 的兜底货品
        Boolean disabledOnly,   // 货品页"禁用货品集合"用：只看 status='禁用'
        Boolean stubOnly        // 货品页"不明货品集合"用：只看 auto_created=true
) {
}
