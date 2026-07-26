// 采购报表配置（采购管理 → 采购报表：2 张卡 + 1 张独立催料，卡内切换单据类型）。
//
// 镜像销售报表（sales_report_config）。hub「采购报表」下入口：
//   · 采购明细报表（kind=detail）→ /purchase/report/detail
//   · 采购汇总报表（kind=summary）→ /purchase/report/summary
//   · 采购催料单  （kind=expediting，**独立**，无单据类型切换）→ /purchase/report/expediting
// 明细/汇总 卡内用 ChoiceChip 切 4 类单据（申请/订货/收货/退货）。
//
// 后端：GET /api/purchase/reports/{docType}/{detail|summary} 或 /api/purchase/reports/expediting
//   返回 ReportTableResponse {columns, rows, facets, page, totalPages, total}。
//   rows 为"显示就绪"行（供应商/仓库/货品/颜色/单位/类别/人员 服务端 JOIN 出）；facets 供表头每列 autofilter。
//
// 明细表：一行=单里一样货品（同单号重复）；汇总表：一行=一整张单（单号唯一）。
import 'package:flutter/material.dart';

/// 报表大类：明细（一行一货品）/ 汇总（一行一整单）/ 催料（独立，订货未收+库存）。
enum PurchaseReportKind {
  detail('采购明细报表', '明细', Icons.list_alt_outlined),
  summary('采购汇总报表', '汇总', Icons.bar_chart_outlined),
  expediting('采购催料单', '催料', Icons.notifications_active_outlined);

  const PurchaseReportKind(this.label, this.shortLabel, this.icon);

  /// 卡片标题 / 页面标题（独立报表）。
  final String label;

  /// 页面标题里的短词（拼 "订货${shortLabel}报表"）。
  final String shortLabel;

  /// 卡片图标。
  final IconData icon;

  /// 后端端点路径段（拼到 /api/purchase/reports/{docType}/ 之后；催料拼到 /api/purchase/reports/ 之后）。
  String get endpoint => name; // 'detail' | 'summary' | 'expediting'

  /// 路由路径（/purchase/report/detail | /summary | /expediting）。
  String get route => '/purchase/report/$name';

  bool get isDetail => this == detail;

  /// 独立报表（无单据类型切换，直接查固定端点）。
  bool get isStandalone => this == expediting;

  static PurchaseReportKind byName(String n) =>
      PurchaseReportKind.values.firstWhere((k) => k.name == n);
}

/// 报表单据类型（4 类）。docType 决定查哪张表 + 列集。
enum PurchaseReportDocType {
  request('申请', 'request'),
  order('订货', 'order'),
  receipt('收货', 'receipt'),
  returnDoc('退货', 'return');

  const PurchaseReportDocType(this.label, this.code);
  final String label;
  final String code; // 后端 docType 路径段
}
