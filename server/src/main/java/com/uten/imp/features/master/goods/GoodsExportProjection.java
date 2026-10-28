package com.uten.imp.features.master.goods;

import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.ArrayList;
import java.util.Map;
import java.util.Set;

/** Keeps the import schema when a screen projection omits the category context. */
public final class GoodsExportProjection {
    private static final Map<String, String> REQUIRED = Map.of(
            "name", "货品名称", "code", "编号", "categoryPath", "类别", "goodsId", "系统标识",
            "bomRef", "组装信息ID");

    /**
     * 组装信息ID 的值形态（2026-10-28）：货品编号 + 该后缀。导出列有组装信息才写值
     * （编号-BOM），无则空；导入有值即按编号反查源货品复制整棵组装信息。
     * 导出侧（GoodsService.export）与导入侧（GoodsImportService）共用此常量。
     */
    public static final String BOM_REF_SUFFIX = "-BOM";

    private GoodsExportProjection() { }

    public static TableColumnProjection forImportTemplate(TableColumnProjection projection) {
        if (projection == null) return null;
        // Leave malformed projections to the shared validator, including duplicates.
        if (projection.columns() == null || projection.columns().isEmpty()
                || projection.columns().stream().anyMatch(column -> column == null || column.key() == null)) {
            return projection;
        }
        var columns = new ArrayList<TableColumnProjection.Column>();
        Set<String> present = new java.util.HashSet<>();
        for (var column : projection.columns()) {
            present.add(column.key());
            String label = REQUIRED.get(column.key());
            columns.add(label == null ? column : new TableColumnProjection.Column(
                    column.key(), label, column.width(), column.type(), column.definition()));
        }
        // Use canonical headers even when the user renamed a visible required field.
        for (String key : new String[]{"name", "code", "categoryPath", "goodsId", "bomRef"}) {
            if (!present.contains(key)) columns.add(new TableColumnProjection.Column(
                    key, REQUIRED.get(key), null, null, null));
        }
        // Preserve the user's visible header order. Missing import identity/context
        // columns are appended above; they must never move existing table columns.
        // Sensitive columns are not in REQUIRED and remain subject to the server's
        // authorized available-column list in ExportTableProjectionService.
        if (columns.size() > 160) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "货品导出需保留货品名称、编号、类别和组装信息ID，请减少选中的导出列后重试");
        }
        return new TableColumnProjection(projection.tableKey(), projection.scope(), columns);
    }
}
