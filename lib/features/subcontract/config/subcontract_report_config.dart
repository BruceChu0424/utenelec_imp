// 委外报表配置（委外管理 → 委外报表：3 张卡，明细/汇总卡内切单据类型）。
//
// hub「委外报表」下 3 个入口：
//   · 委外明细报表（kind=detail）→ /subcontract/report/detail
//   · 委外汇总报表（kind=summary）→ /subcontract/report/summary
//   · 委外出入状况表（kind=inOutStatus）→ /subcontract/report/in-out-status（综合，无明细/汇总之分）
// 明细/汇总卡内用 ChoiceChip 切 4 类单据（进仓/退货/材料出/材料退）。
// 询价/申请/订货/损耗 无报表（用户要求删）。
//
// 后端：GET /api/subcontract/reports/{docType}/{detail|summary} 或 /api/subcontract/reports/in-out-status
//   返回 ReportTableResponse {columns, rows, facets, page, totalPages, total}。
//   rows 为"显示就绪"行（委外商/仓库/货品/颜色/单位/人员/结帐方式服务端 JOIN 出）。
//
// 布局镜像销售报表（sales_report_config.dart）。
// 明细表：一行=单里一样货品（同单号重复）；汇总表：一行=一整张单（单号唯一）。
import 'package:flutter/material.dart';

/// 报表大类：明细（一行一货品）/ 汇总（一行一整单）/ 出入状况（综合）。
enum SubcontractReportKind {
  detail('委外明细报表', '明细', Icons.list_alt_outlined),
  summary('委外汇总报表', '汇总', Icons.bar_chart_outlined),
  inOutStatus('委外出入状况表', '出入状况', Icons.swap_vert_outlined);

  const SubcontractReportKind(this.label, this.shortLabel, this.icon);
  final String label;
  final String shortLabel;
  final IconData icon;

  /// 后端端点路径段（拼到 /api/subcontract/reports/{docType}/ 之后；出入状况走独立端点）。
  String get endpoint => name; // 'detail' | 'summary'

  /// 路由路径段（/subcontract/report/detail | /summary | /in-out-status）。
  String get routeSegment => this == inOutStatus ? 'in-out-status' : name;

  /// 路由全路径。
  String get route => '/subcontract/report/$routeSegment';

  bool get isDetail => this == detail;
  bool get isInOut => this == inOutStatus;

  /// 按路由段反查（路由 :kind 用）。
  static SubcontractReportKind byRouteSegment(String seg) =>
      SubcontractReportKind.values.firstWhere((k) => k.routeSegment == seg);
}

/// 报表单据类型（4 类，无询价/申请/订货/损耗）。docType 决定查哪张表 + 列集。
enum SubcontractReportDocType {
  receipt('进仓', 'RECEIPT'),
  returnDoc('退货', 'RETURN'),
  materialIssue('材料出', 'MATERIAL_ISSUE'),
  materialReturn('材料退', 'MATERIAL_RETURN');

  const SubcontractReportDocType(this.label, this.code);
  final String label;
  final String code; // 后端 docType 路径段（大写，与 Controller switch 对齐）
}
