// 报表数据 + 后端响应解析（共享）—— 取代各报表页 private _ReportData 与 _load 里的解析体。
//
// 后端 ReportTableResponse：{ columns:[{key,label,type,width}], rows:[{...显示就绪}],
//   facets:{colKey:[{value,label,count}]}, page, size, total, totalPages }。
// 名称（客户/仓库/货品/人员…）服务端 JOIN 出，前端直接展示。

import '../../basic_data/models/master_facet.dart';
import 'report_column.dart';

/// 一次报表查询的结果集：列 + 行 + facet 桶 + 分页。
class ReportData {
  const ReportData({
    required this.columns,
    required this.rows,
    required this.facets,
    required this.page,
    required this.totalPages,
    required this.total,
  });

  final List<ReportColumn> columns;
  final List<Map<String, dynamic>> rows;
  final Map<String, List<MasterFacetBucket>> facets;
  final int page;
  final int totalPages;
  final int total;
}

/// 解析后端 ReportTableResponse JSON 为 [ReportData]。
/// [fallbackPage]：当响应未带 page 时的回退（通常传当前请求页）。
ReportData parseReportResponse(Map<String, dynamic> json, int fallbackPage) {
  final cols = (json['columns'] as List? ?? const [])
      .map((c) => ReportColumn.fromJson(c as Map<String, dynamic>))
      .toList();
  final rows = (json['rows'] as List? ?? const []).cast<Map<String, dynamic>>();
  final facets = <String, List<MasterFacetBucket>>{};
  final fjson = json['facets'];
  if (fjson is Map) {
    fjson.forEach((k, v) {
      if (v is List) {
        facets[k.toString()] = v
            .map((b) => MasterFacetBucket.fromJson(b as Map<String, dynamic>))
            .toList();
      }
    });
  }
  return ReportData(
    columns: cols,
    rows: rows,
    facets: facets,
    page: (json['page'] as num?)?.toInt() ?? fallbackPage,
    totalPages: (json['totalPages'] as num?)?.toInt() ?? 1,
    total: (json['total'] as num?)?.toInt() ?? 0,
  );
}
