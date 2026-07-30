// 生产报表配置（生产管理 → 生产报表：2 张卡，明细/汇总）。
//
// hub「生产报表」下 2 个入口：
//   · 生产计划明细报表（kind=detail）→ /production/reports/plan-detail
//   · 生产计划汇总报表（kind=summary）→ /production/reports/plan-summary
//
// 后端：GET /api/production/reports/plan/{detail|summary}
//   返回 ReportTableResponse {columns, rows, facets, page, totalPages, total}。
//   rows 为"显示就绪"行（货品/颜色/类别/制单员/审核员名称服务端 JOIN 出）；
//   facets 供表头每列 autofilter。
//
// 明细表：一行=单里一样货品（同单号重复）；汇总表：一行=一整张单（单号唯一）。
// 生产计划只有一种单据（不像销售 4 类），无 DocType 枚举。
import 'package:flutter/material.dart';

/// 生产报表大类：明细（一行一货品）/ 汇总（一行一整单）。
enum ProductionReportKind {
  detail('生产计划明细报表', '明细', Icons.list_alt_outlined),
  summary('生产计划汇总报表', '汇总', Icons.bar_chart_outlined);

  const ProductionReportKind(this.label, this.shortLabel, this.icon);
  final String label;
  final String shortLabel;
  final IconData icon;

  /// 后端端点路径段（拼到 /api/production/reports/plan/ 之后）。
  String get endpoint => name; // 'detail' | 'summary'

  /// hub 路径段（/production/reports/plan-detail | plan-summary）。
  String get pathSegment => 'plan-$name';

  /// 路由路径。
  String get route => '/production/reports/$pathSegment';

  bool get isDetail => this == detail;

  static ProductionReportKind byName(String n) =>
      ProductionReportKind.values.firstWhere((k) => k.name == n);
}
