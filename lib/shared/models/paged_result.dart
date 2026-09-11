// 分页结果（对应后端 PageResponse：{items,page,size,total,totalPages}）。
//
// [totals] 对应后端 TotaledPageResponse 多出来的 {totals}：只有声明了「表格下方合计」
// 的端点会下发，其余端点解析成空列表、合计条整条不渲染。合计一律由服务端在**整个结果集**
// 上算（见 features/report/shared/report_total.dart）——列表是服务端分页的，前端对当前页
// 求和会得出一个看着像总计、其实只覆盖一页的数，比不显示更糟。
import '../../features/report/shared/report_total.dart';

class PagedResult<T> {
  const PagedResult({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
    this.totals = const [],
  });

  final List<T> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  /// 服务端下发的合计项（按单位/币种分组，前端不做任何加法）；端点没声明时为空。
  final List<ReportTotal> totals;

  factory PagedResult.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final list = json['items'] as List<dynamic>? ?? const [];
    return PagedResult<T>(
      items: list.map((e) => fromJson(e as Map<String, dynamic>)).toList(),
      page: json['page'] as int? ?? 1,
      size: json['size'] as int? ?? list.length,
      total: (json['total'] as num?)?.toInt() ?? list.length,
      totalPages: json['totalPages'] as int? ?? 1,
      totals: (json['totals'] as List<dynamic>? ?? const [])
          .map((e) => ReportTotal.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
