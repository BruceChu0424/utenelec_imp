package com.uten.imp.features.master.goods.importing;

import java.util.Map;
import java.util.List;

/** File-owned row input for preview and correction; no stored master values. */
public record GoodsImportProblemRow(int rowNum, String code, String name, String categoryPath,
                                    Map<String, String> cells, List<String> categorySegments) {
    public GoodsImportProblemRow {
        categorySegments = categorySegments == null ? List.of() : List.copyOf(categorySegments);
    }

    public GoodsImportProblemRow(int rowNum, String code, String name, String categoryPath, Map<String, String> cells) {
        this(rowNum, code, name, categoryPath, cells, List.of());
    }
    public GoodsImportProblemRow(int rowNum, String code, String name, String categoryPath) {
        this(rowNum, code, name, categoryPath, Map.of());
    }
}
