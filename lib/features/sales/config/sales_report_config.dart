// 销售报表配置（销售管理 → 销售报表：2 张卡，卡内切换单据类型）。
//
// hub「销售报表」下 2 个入口：
//   · 销售明细报表（kind=detail）→ /sales/report/detail
//   · 销售汇总报表（kind=summary）→ /sales/report/summary
// 卡内用 ChoiceChip 切 4 类单据（订货/出货/退货/其它出货），**无报价**（报价无报表）。
//
// 后端：GET /api/sales/reports/{docType}/{detail|summary}
//   返回 ReportTableResponse {columns, rows, facets, page, totalPages, total}。
//   rows 为"显示就绪"行（名称/人员/总监服务端 JOIN 出）；facets 供表头每列 autofilter。
//
// 明细表：一行=单里一样货品（同单号重复）；汇总表：一行=一整张单（单号唯一）。
import 'package:flutter/material.dart';

/// 报表大类：明细（一行一货品）/ 汇总（一行一整单）。
enum SalesReportKind {
  detail('销售明细报表', '明细', Icons.list_alt_outlined),
  summary('销售汇总报表', '汇总', Icons.bar_chart_outlined);

  const SalesReportKind(this.label, this.shortLabel, this.icon);
  final String label;
  final String shortLabel;
  final IconData icon;

  /// 后端端点路径段（拼到 /api/sales/reports/{docType}/ 之后）。
  String get endpoint => name; // 'detail' | 'summary'

  /// 路由路径（/sales/report/detail | /sales/report/summary）。
  String get route => '/sales/report/$name';

  bool get isDetail => this == detail;

  static SalesReportKind byName(String n) =>
      SalesReportKind.values.firstWhere((k) => k.name == n);
}

/// 报表单据类型（4 类，无报价）。docType 决定查哪张表 + 列集。
enum SalesReportDocType {
  order('订货', 'ORDER'),
  shipment('出货', 'SHIPMENT'),
  returnDoc('退货', 'RETURN'),
  otherShipment('其它出货', 'OTHER_SHIPMENT');

  const SalesReportDocType(this.label, this.code);
  final String label;
  final String code; // 后端 docType 路径段
}
