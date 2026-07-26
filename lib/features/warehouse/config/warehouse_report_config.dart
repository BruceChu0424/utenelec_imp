// 仓库报表配置（仓库管理 → 仓库报表：2 张卡，卡内切换单据类型）。
//
// hub「仓库报表」下 2 个入口：
//   · 仓库明细报表（kind=detail）→ /warehouse/report/detail
//   · 仓库汇总报表（kind=summary）→ /warehouse/report/summary
// 卡内用 ChoiceChip 切 7 类单据（调拨/其它入库/生产领料/生产退料/产成品进仓/产成品出仓/盘点）。
// **无其它出库 / 生产损耗**（用户指定删除：其它出库无内容、生产损耗老库 0 行）。
//
// 后端：GET /api/stock/reports/{docType}/{detail|summary}
//   返回 ReportTableResponse {columns, rows, facets, page, totalPages, total}。
//   rows 为"显示就绪"行（仓库/货品/颜色/单位/人员名服务端 JOIN 出）；facets 供表头每列 autofilter。
//
// 明细表：一行=单里一样货品（同单号重复）；汇总表：一行=一整张单（单号唯一）。
// 人员列 worker 在不同单据类型标签不同：调拨/其它入库=经办人、领料=领料人、退料=退料人、
// 产成品进/出仓/盘点=跟单员（后端按 docType 给列标签）。
import 'package:flutter/material.dart';

/// 报表大类：明细（一行一货品）/ 汇总（一行一整单）。
enum WarehouseReportKind {
  detail('仓库明细报表', '明细', Icons.list_alt_outlined),
  summary('仓库汇总报表', '汇总', Icons.bar_chart_outlined);

  const WarehouseReportKind(this.label, this.shortLabel, this.icon);
  final String label;
  final String shortLabel;
  final IconData icon;

  /// 后端端点路径段（拼到 /api/stock/reports/{docType}/ 之后）。
  String get endpoint => name; // 'detail' | 'summary'

  /// 路由路径（/warehouse/report/detail | /warehouse/report/summary）。
  String get route => '/warehouse/report/$name';

  bool get isDetail => this == detail;

  static WarehouseReportKind byName(String n) =>
      WarehouseReportKind.values.firstWhere((k) => k.name == n);
}

/// 报表单据类型（7 类，无其它出库/损耗）。docType 决定列集 + 人员标签。
enum WarehouseReportDocType {
  transfer('调拨', 'TRANSFER'),
  otherIn('其它入库', 'OTHER_IN'),
  draw('生产领料', 'DRAW'),
  wdraw('生产退料', 'WDRAW'),
  finishedIn('产成品进仓', 'FINISHED_IN'),
  finishedOut('产成品出仓', 'FINISHED_OUT'),
  check('盘点', 'CHECK');

  const WarehouseReportDocType(this.label, this.code);
  final String label;
  final String code; // 后端 docType 路径段
}
