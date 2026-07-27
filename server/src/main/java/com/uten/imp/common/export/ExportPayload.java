package com.uten.imp.common.export;

import java.util.List;
import java.util.Map;

/**
 * 导出载荷：列（已映射为 {@link ExportColumn}，剥离报表专属 width）+ 全量行 + 行数。
 * 各报表 {@code export(...)} 循环分页累积后返回，供 {@link XlsxExportService} 生成 .xlsx。
 */
public record ExportPayload(List<ExportColumn> columns, List<Map<String, Object>> rows, int total) {
}
