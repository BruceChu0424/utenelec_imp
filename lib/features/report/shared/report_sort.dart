// 报表列排序辅助（共享）。
//
// 可排序类型 = 日期 + 金额 + 数量 + 重量 + 计数 + 文本 (2026-09-25 单号列统一：服务端
// *ReportService.execute() 本就按全部列 key 白名单接受 sort，文本单号列放开点表头排序；
// 重量按千克、计数按整数排序 (ADR-135)；bool 仍不可排序)。
// sort/order 两个 query 参数与后端 *ReportService.execute() 的白名单 ORDER BY 对齐。

/// 该列类型是否允许点表头排序。
bool isSortableReportType(String type) =>
    type == 'date' ||
    type == 'money' ||
    type == 'number' ||
    type == 'weight' ||
    type == 'count' ||
    type == 'text';

/// 生成排序 query 参数：[key]=null → 不排序（空 Map）；否则 {sort: key, order: asc|desc}。
Map<String, dynamic> sortQueryParams(String? key, bool ascending) {
  if (key == null) return const {};
  return {'sort': key, 'order': ascending ? 'asc' : 'desc'};
}
