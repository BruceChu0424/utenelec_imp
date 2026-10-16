package com.uten.imp.features.production.report;

import java.util.List;

/** Read-only picker projection; the historical fallback ID is a view key, never a business UUID. */
public record WhereUsedMaterialCategory(
        String id,
        String code,
        String name,
        int level,
        String parentId,
        int sortOrder,
        List<WhereUsedMaterialCategory> children) {
}
