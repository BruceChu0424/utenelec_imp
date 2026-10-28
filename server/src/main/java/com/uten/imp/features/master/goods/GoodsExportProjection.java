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
    private static final String[] IDENTITY_PREFIX = {"goodsId", "bomRef", "code"};
    private static final Set<String> IDENTITY_KEYS = Set.of(IDENTITY_PREFIX);

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
        var requested = new java.util.LinkedHashMap<String, TableColumnProjection.Column>();
        for (var column : projection.columns()) {
            // Never normalize an invalid duplicate away before shared validation.
            if (requested.containsKey(column.key())) return projection;
            String label = REQUIRED.get(column.key());
            requested.put(column.key(), label == null ? column : new TableColumnProjection.Column(
                    column.key(), label, column.width(), column.type(), column.definition()));
        }
        var columns = new ArrayList<TableColumnProjection.Column>();
        // Stable import identities precede the captured current screen projection.
        for (String key : IDENTITY_PREFIX) {
            columns.add(requested.getOrDefault(key, new TableColumnProjection.Column(
                    key, REQUIRED.get(key), null, null, null)));
        }
        requested.forEach((key, column) -> { if (!IDENTITY_KEYS.contains(key)) columns.add(column); });
        // Use canonical headers even when the user renamed a visible required field.
        for (String key : new String[]{"name", "categoryPath"}) {
            if (!requested.containsKey(key)) columns.add(new TableColumnProjection.Column(
                    key, REQUIRED.get(key), null, null, null));
        }
        // All remaining visible columns retain their current order. Only missing
        // required import context is appended; permissions remain server-owned.
        // Sensitive columns are not in REQUIRED and remain subject to the server's
        // authorized available-column list in ExportTableProjectionService.
        if (columns.size() > 160) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "货品导出需保留系统标识、组装信息ID、编号、货品名称和类别，请减少选中的导出列后重试");
        }
        return new TableColumnProjection(projection.tableKey(), projection.scope(), columns);
    }
}
