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
        Set<UUID> categoryRootIds,
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
        String mouldCode,       // 模具编号精确筛选（goods.mould.code 等值）
        String rearInsertCode,  // 后模镶件编号精确筛选（V457）
        String paper,           // 备注精确筛选（老库 Paper）
        Integer colorLegacyId,
        Integer unitLegacyId,
        String sourceType,
        Boolean excludeDisabled,
        // stub/禁用隔离（货品资料页集合行 + 滑窗隐藏 stub）
        Boolean excludeStub,    // 滑窗用：排除 auto_created=true 的兜底货品
        Boolean disabledOnly,   // 货品页"禁用货品集合"用：只看 status='禁用'
        Boolean stubOnly,       // 货品页"不明货品集合"用：只看 auto_created=true
        // V587/V590 归属筛选（表头下拉，值为 UUID；空值走 nullFields 的
        // owningWarehouse/owningWorkshop 两个键，与表头筛选键同名）
        UUID owningWarehouse,
        UUID owningWorkshop,
        Boolean includeRelated, // Explicitly include descriptive-only/mixed descriptive matches after primary goods.
        java.util.Map<String, String> columnSearch,
        String colorRef,
        String unitRef
) {
    /** Compatibility constructor for callers predating UUID-aware header references. */
    public GoodsQueryFilter(UUID categoryId, Set<UUID> categoryRootIds, String keyword, Set<String> nullFields,
                            String series, String model, String material, String code, String name, String spec,
                            String cNumber, String requireRemark, String mouldCode, String rearInsertCode, String paper,
                            Integer colorLegacyId, Integer unitLegacyId, String sourceType, Boolean excludeDisabled,
                            Boolean excludeStub, Boolean disabledOnly, Boolean stubOnly, UUID owningWarehouse,
                            UUID owningWorkshop, Boolean includeRelated, java.util.Map<String, String> columnSearch) {
        this(categoryId, categoryRootIds, keyword, nullFields, series, model, material, code, name, spec, cNumber,
                requireRemark, mouldCode, rearInsertCode, paper, colorLegacyId, unitLegacyId, sourceType, excludeDisabled,
                excludeStub, disabledOnly, stubOnly, owningWarehouse, owningWorkshop, includeRelated, columnSearch, null, null);
    }

    public GoodsQueryFilter withReferences(String color, String unit) {
        return new GoodsQueryFilter(categoryId, categoryRootIds, keyword, nullFields, series, model, material, code,
                name, spec, cNumber, requireRemark, mouldCode, rearInsertCode, paper, colorLegacyId, unitLegacyId,
                sourceType, excludeDisabled, excludeStub, disabledOnly, stubOnly, owningWarehouse, owningWorkshop,
                includeRelated, columnSearch, color, unit);
    }
    public GoodsQueryFilter(UUID categoryId, Set<UUID> categoryRootIds, String keyword, Set<String> nullFields,
                            String series, String model, String material, String code, String name, String spec,
                            String cNumber, String requireRemark, String mouldCode, String rearInsertCode, String paper,
                            Integer colorLegacyId, Integer unitLegacyId, String sourceType, Boolean excludeDisabled,
                            Boolean excludeStub, Boolean disabledOnly, Boolean stubOnly, UUID owningWarehouse,
                            UUID owningWorkshop, Boolean includeRelated) {
        this(categoryId, categoryRootIds, keyword, nullFields, series, model, material, code, name, spec, cNumber,
                requireRemark, mouldCode, rearInsertCode, paper, colorLegacyId, unitLegacyId, sourceType, excludeDisabled,
                excludeStub, disabledOnly, stubOnly, owningWarehouse, owningWorkshop, includeRelated, java.util.Map.of());
    }

    public GoodsQueryFilter withColumnSearch(java.util.Map<String, String> search) {
        return new GoodsQueryFilter(categoryId, categoryRootIds, keyword, nullFields, series, model, material, code,
                name, spec, cNumber, requireRemark, mouldCode, rearInsertCode, paper, colorLegacyId, unitLegacyId,
                sourceType, excludeDisabled, excludeStub, disabledOnly, stubOnly, owningWarehouse, owningWorkshop,
                includeRelated, search, colorRef, unitRef);
    }
    /** Existing callers retain the default identity/category-only candidate set. */
    public GoodsQueryFilter(UUID categoryId, Set<UUID> categoryRootIds, String keyword, Set<String> nullFields,
                            String series, String model, String material, String code, String name, String spec,
                            String cNumber, String requireRemark, String mouldCode, String rearInsertCode, String paper,
                            Integer colorLegacyId, Integer unitLegacyId, String sourceType, Boolean excludeDisabled,
                            Boolean excludeStub, Boolean disabledOnly, Boolean stubOnly, UUID owningWarehouse, UUID owningWorkshop) {
        this(categoryId, categoryRootIds, keyword, nullFields, series, model, material, code, name, spec, cNumber,
                requireRemark, mouldCode, rearInsertCode, paper, colorLegacyId, unitLegacyId, sourceType, excludeDisabled,
                excludeStub, disabledOnly, stubOnly, owningWarehouse, owningWorkshop, false);
    }

    /** A facet retains every other filter while allowing its own value/null bucket to be changed. */
    public GoodsQueryFilter forFacet(String field) {
        Set<String> remainingNulls = nullFields == null ? null : new java.util.LinkedHashSet<>(nullFields);
        if (remainingNulls != null) remainingNulls.remove(field);
        return new GoodsQueryFilter(categoryId, categoryRootIds, keyword, remainingNulls,
                "series".equals(field) ? null : series, "model".equals(field) ? null : model,
                "material".equals(field) ? null : material, "code".equals(field) ? null : code,
                "name".equals(field) ? null : name, "spec".equals(field) ? null : spec,
                "cNumber".equals(field) ? null : cNumber, "requireRemark".equals(field) ? null : requireRemark,
                "mouldCode".equals(field) ? null : mouldCode, "rearInsertCode".equals(field) ? null : rearInsertCode,
                "paper".equals(field) ? null : paper, "colorLegacyId".equals(field) ? null : colorLegacyId,
                "unitLegacyId".equals(field) ? null : unitLegacyId, "sourceType".equals(field) ? null : sourceType,
                excludeDisabled, excludeStub, disabledOnly, stubOnly,
                "owningWarehouse".equals(field) ? null : owningWarehouse,
                "owningWorkshop".equals(field) ? null : owningWorkshop, includeRelated, columnSearch,
                "colorRef".equals(field) ? null : colorRef, "unitRef".equals(field) ? null : unitRef);
    }
}
