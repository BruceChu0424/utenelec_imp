// 报表列定义（共享）—— 对齐后端 ReportColumn record，取代各报表页 private _Col。
//
// type 取值：text / date / number / money / bool / int（后端权威返回）。
// 前端据此决定单元格格式化（formatReportCell）与是否可排序（isSortableReportType）。

/// 一列：[key]（与后端 query/排序参数对齐）、[label]（列头）、[type]、[width]（建议列宽）。
class ReportColumn {
  const ReportColumn({
    required this.key,
    required this.label,
    required this.type,
    this.width,
  });

  final String key;
  final String label;
  final String type;
  final double? width;

  factory ReportColumn.fromJson(Map<String, dynamic> j) => ReportColumn(
    key: (j['key'] ?? '').toString(),
    label: (j['label'] ?? '').toString(),
    type: (j['type'] ?? 'text').toString(),
    width: (j['width'] as num?)?.toDouble(),
  );
}
