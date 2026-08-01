package com.uten.imp.features.production.report;

import java.util.UUID;

/**
 * 物料反查专用候选项。
 *
 * <p>该模型由 {@code production_where_used:view} 保护，不依赖货品主档的
 * {@code goods:view}。历史停用、软删除和迁移占位货品仍可作为只读追溯入口，
 * 调用方必须根据状态标记提示用户，不能把它们当作当前运营货品。
 */
public record WhereUsedMaterialOption(
        UUID id,
        String code,
        String name,
        String model,
        String spec,
        String status,
        String sourceType,
        String categoryName,
        boolean autoCreated,
        boolean deleted,
        boolean currentBom,
        boolean bomIssue,
        boolean productionHistory,
        boolean subcontractHistory) {
}
