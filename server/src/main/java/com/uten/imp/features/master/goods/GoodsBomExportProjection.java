package com.uten.imp.features.master.goods;

import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 配件清单导出的投影收口（2026-10-20，内部测试反馈「导出组件」报
 * 「列不存在或不在可导出范围：treeIdentity」）。
 *
 * <p>前端组装信息表格的树形身份列(treeIdentity)与审计模式的已审列(audited)是纯展示列，
 * 前端已不送进投影；但表格因此也没有独立的名称列——名称长在身份格里。序号/物料编号/
 * 设计使用数量是 BOM 导入的最小回环表头（导出改完可直接导回），物料名称是文件可读性的底线。
 * 四列缺失时按导出列集的标准表头补齐、排在最前（与身份列在表格首位对应），用户改过的
 * 其余列保持自己的顺序与表头文字。与货品主档导出 {@link GoodsExportProjection} 同一模式。</p>
 */
final class GoodsBomExportProjection {
    /** 导入回环 + 可读性的必含列：导出列 key -> 标准表头。 */
    private static final Map<String, String> REQUIRED = orderedRequired();

    private GoodsBomExportProjection() { }

    static TableColumnProjection forImportTemplate(TableColumnProjection projection) {
        if (projection == null) return null;
        // 结构性问题(重复/空列)交给共享校验，这里只补缺。
        if (projection.columns() == null || projection.columns().isEmpty()
                || projection.columns().stream().anyMatch(column -> column == null || column.key() == null)) {
            return projection;
        }
        var present = new java.util.HashSet<String>();
        for (var column : projection.columns()) present.add(column.key());
        var columns = new ArrayList<TableColumnProjection.Column>();
        for (var required : REQUIRED.entrySet()) {
            if (!present.contains(required.getKey())) columns.add(new TableColumnProjection.Column(
                    required.getKey(), required.getValue(), null, null, null));
        }
        columns.addAll(projection.columns());
        if (columns.size() > 160) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "配件清单导出需保留序号、编号、名称和设计使用数量，请减少选中的导出列后重试");
        }
        return new TableColumnProjection(projection.tableKey(), projection.scope(), columns);
    }

    private static Map<String, String> orderedRequired() {
        var required = new LinkedHashMap<String, String>();
        required.put("seq", "序号");
        required.put("code", "物料编号");
        required.put("name", "物料名称");
        required.put("qty", "设计使用数量");
        return java.util.Collections.unmodifiableMap(required);
    }
}
