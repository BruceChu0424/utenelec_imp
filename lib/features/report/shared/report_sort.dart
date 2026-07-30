// 报表列排序辅助（共享）。
//
// 可排序类型 = 日期 + 金额 + 数量（用户要求；编号等文本列暂不支持，可按需扩展）。
// sort/order 两个 query 参数与后端 *ReportService.execute() 的白名单 ORDER BY 对齐。

/// 该列类型是否允许点表头排序。
bool isSortableReportType(String type) =>
    type == 'date' || type == 'money' || type == 'number';

/// 生成排序 query 参数：[key]=null → 不排序（空 Map）；否则 {sort: key, order: asc|desc}。
Map<String, dynamic> sortQueryParams(String? key, bool ascending) {
  if (key == null) return const {};
  return {'sort': key, 'order': ascending ? 'asc' : 'desc'};
}
