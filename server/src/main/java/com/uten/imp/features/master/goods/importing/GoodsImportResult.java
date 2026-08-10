package com.uten.imp.features.master.goods.importing;

import java.util.List;
import java.util.UUID;

/**
 * 导入「提交」阶段结果（原子事务：建缺失分类/颜色/单位 + 批量建货品 + 登记批次）。
 *
 * @param batchId           本批次 id（撤回用）。
 * @param importedCount     实际导入货品行数。
 * @param createdCategories 本次新建分类数。
 * @param createdColors     本次新建颜色数。
 * @param createdUnits      本次新建单位数。
 * @param createdCategoryPaths 新建分类的完整路径（展示用）。
 */
public record GoodsImportResult(
        UUID batchId,
        int importedCount,
        int createdCategories,
        int createdColors,
        int createdUnits,
        List<String> createdCategoryPaths) {}
