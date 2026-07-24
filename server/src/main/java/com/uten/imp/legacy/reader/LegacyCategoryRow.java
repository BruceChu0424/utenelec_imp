package com.uten.imp.legacy.reader;

/**
 * 老库 SystemItem 一行（物料分类）。
 *
 * @param legacyId       ItemID（主键，迁入新库 legacy_id）
 * @param parentLegacyId ParentID（0 或指向不存在 = 根 / 孤儿）
 * @param code           Number（编码，老库大量重复）
 * @param name           Name（中文名）
 */
public record LegacyCategoryRow(
        Integer legacyId,
        Integer parentLegacyId,
        String code,
        String name
) {}
