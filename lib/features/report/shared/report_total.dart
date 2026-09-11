// 报表「表格下方合计」的模型（共享）—— 对齐后端 common.report.ReportTotal record。
//
// 为什么合计必须来自服务端：报表表格一律服务端分页（一页 50 行），前端对「当前页」求和
// 会得出一个看着像总计、其实只覆盖一页的数——比不显示合计更糟。后端用与列表完全相同的
// 过滤条件（含对象级授权谓词）在整个结果集上聚合，与翻到第几页无关。
//
// 为什么是 groups 而不是单个数：数量不得跨单位相加、金额不得跨币种相加。服务端按分组列
// （单位名/币种名）分好组下发，前端只负责拼成「12 个 · 3 箱」，本文件不做任何加法。

import 'package:flutter/widgets.dart';

import '../../../core/formatters/china_number_format.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../shared/measurement/measurement_totals.dart';

/// 一个合计项的一组值（一个单位 / 一个币种）。
class ReportTotalGroup {
  const ReportTotalGroup({required this.unit, required this.value});

  /// 分组名（单位名或币种名）；报表无分组维度时为 null。
  final String? unit;
  final double value;

  factory ReportTotalGroup.fromJson(Map<String, dynamic> j) => ReportTotalGroup(
    unit: (j['unit'] as Object?)?.toString(),
    value: (j['value'] as num?)?.toDouble() ?? 0,
  );
}

/// 一个合计项（对应一列）。
class ReportTotal {
  const ReportTotal({
    required this.key,
    required this.label,
    required this.type,
    required this.groupKey,
    required this.groups,
  });

  final String key;
  final String label;

  /// number / money —— 决定数值格式化口径（金额固定两位小数，数量去掉多余的 0）。
  final String type;

  /// 分组列 key；null = 该报表无分组维度，[groups] 只有一组且 unit 为 null。
  final String? groupKey;

  final List<ReportTotalGroup> groups;

  bool get grouped => groupKey != null && groupKey!.isNotEmpty;

  factory ReportTotal.fromJson(Map<String, dynamic> j) => ReportTotal(
    key: (j['key'] ?? '').toString(),
    label: (j['label'] ?? '').toString(),
    type: (j['type'] ?? 'number').toString(),
    groupKey: (j['groupKey'] as Object?)?.toString(),
    groups: (j['groups'] as List? ?? const [])
        .map((g) => ReportTotalGroup.fromJson(g as Map<String, dynamic>))
        .toList(),
  );
}

/// 把服务端合计项转成合计条的一项。
///
/// 多分组一律走 [measurementTotalsText]（全站唯一的「不跨单位相加」口径），拼成
/// 「12 个 · 3 箱」；**本函数不做任何跨组加法**，跨单位/跨币种相加在结构上就不可能发生。
///
/// - 无分组维度（[ReportTotal.grouped] 为 false）：渲染纯数值，不带「单位未维护」后缀；
/// - 有分组维度但某组的分组值为空：那是「该行单位/币种没维护」，照常渲染「单位未维护」；
/// - 无任何分组（服务端聚合结果全为 NULL，即没有数据）：返回值为空串，由合计条整体隐藏该项，
///   **不伪造 0**。
UtenTotalEntry reportTotalEntry(ReportTotal total, {bool danger = false}) {
  String fmt(double v) =>
      total.type == 'money' ? formatChinaNumber(v) : formatMeasurementValue(v);

  if (total.groups.isEmpty) {
    // 服务端聚合无数据：值留空，由合计条整体隐藏该项，不伪造 0。
    return UtenTotalEntry(total.label, '', danger: danger);
  }

  if (!total.grouped) {
    // 无分组维度：服务端只会给一组，直接渲染数值。
    return UtenTotalEntry(
      total.label,
      fmt(total.groups.first.value),
      danger: danger,
    );
  }

  return UtenTotalEntry(
    total.label,
    measurementTotalsText(
      [
        for (final g in total.groups)
          MeasuredAmount(value: g.value, unitId: g.unit, unitName: g.unit),
      ],
      formatValue: fmt,
      emptyLabel: '',
    ),
    danger: danger,
  );
}

/// 一组服务端合计项 → 合计条的项列表（空值项由合计条自行隐藏）。
List<UtenTotalEntry> reportTotalEntries(Iterable<ReportTotal> totals) => [
  for (final t in totals) reportTotalEntry(t),
];

/// 报表表格下方合计条；该报表没声明合计列时返回 null（整条不渲染）。
///
/// 直接喂给 `MasterDataTableView.summaryBar`，由表格统一挂在表体与翻页条之间——
/// 各报表页不自己摆位置，全站间距/字号因此一致。
Widget? reportTotalsBar(List<ReportTotal> totals) {
  if (totals.isEmpty) return null;
  final entries = reportTotalEntries(totals);
  if (entries.every((e) => e.value.trim().isEmpty)) return null;
  return UtenTotalsSummaryBar(density: true, compact: true, entries: entries);
}
