package com.uten.imp.features.master.goods.importing;

import java.util.Map;

/** File-owned context for correcting a problem row; no stored master values. */
public record GoodsImportProblemRow(int rowNum, String code, String name, String categoryPath, Map<String, String> cells) {
    public GoodsImportProblemRow(int rowNum, String code, String name, String categoryPath) {
        this(rowNum, code, name, categoryPath, Map.of());
    }
}
