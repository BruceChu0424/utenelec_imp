// 报表「表格下方合计」的模型（共享）—— 对齐后端 common.report.ReportTotal record。
//
// 为什么合计必须来自服务端：报表表格一律服务端分页（一页 50 行），前端对「当前页」求和
// 会得出一个看着像总计、其实只覆盖一页的数——比不显示合计更糟。后端用与列表完全相同的
// 过滤条件（含对象级授权谓词）在整个结果集上聚合，与翻到第几页无关。
//
// 为什么是 groups 而不是单个数：数量不得跨单位相加、金额不得跨币种相加。服务端按分组列
// （单位名/币种名）分好组下发，前端只负责拼成「12 个 · 3 箱」，本文件不做任何加法。
//
// 重量 (ADR-135)：type 'weight' 的值一律是千克，前端只按用户显示单位换算 (自动/克/千克/吨…)，
// 不做加法；同一报表里 key 为「<重量key>_unknown_rows」的 'count' 项并进重量项显示为
// 「≈3.52 t (另有 12 项未称)」，「<重量key>_estimated_rows」> 0 时重量前缀「≈」——这两项
// 不再单独占位。其余 'count' 项按整数显示、为 0 时整项隐藏。

import 'package:flutter/widgets.dart';

import '../../../core/formatters/china_number_format.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/measurement/weight_unit.dart';

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

  /// number / money / weight / count —— 决定数值格式化口径 (金额固定两位小数，数量去掉
  /// 多余的 0，重量为千克按显示单位换算，计数取整且为 0 时隐藏)。
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
///
/// 重量项 (type 'weight')：千克按 [weightDisplay] 换算；[weightEstimated] 加「≈」前缀；
/// [weightUnknownRows] > 0 时追加「(另有 N 项未称)」——全都没称时显示「N 项未称」。
/// 计数项 (type 'count')：整数，0 时值留空 (整项隐藏)。
UtenTotalEntry reportTotalEntry(
  ReportTotal total, {
  bool danger = false,
  WeightDisplay weightDisplay = WeightDisplay.auto,
  bool weightEstimated = false,
  int weightUnknownRows = 0,
}) {
  if (total.type == 'weight') {
    return _weightTotalEntry(
      total,
      danger: danger,
      display: weightDisplay,
      estimated: weightEstimated,
      unknownRows: weightUnknownRows,
    );
  }
  if (total.type == 'count') {
    final value = total.groups.isEmpty ? 0 : total.groups.first.value.round();
    return UtenTotalEntry(
      total.label,
      value == 0 ? '' : formatChinaNumber(value, decimalDigits: 0),
      danger: danger,
    );
  }

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

UtenTotalEntry _weightTotalEntry(
  ReportTotal total, {
  required bool danger,
  required WeightDisplay display,
  required bool estimated,
  required int unknownRows,
}) {
  final prefix = estimated ? '≈' : '';
  final String value;
  if (total.groups.isEmpty) {
    // 全都没称 (服务端 SUM 为 NULL)：只报未称项数；也没有未称项就整项隐藏。
    value = unknownRows > 0 ? '$unknownRows 项未称' : '';
  } else {
    final known = total.grouped
        ? total.groups
              .map(
                (g) =>
                    '$prefix${formatWeight(g.value, display: display)}'
                    ' (${g.unit ?? '—'})',
              )
              .join(' · ')
        : '$prefix${formatWeight(total.groups.first.value, display: display)}';
    value = unknownRows > 0 ? '$known (另有 $unknownRows 项未称)' : known;
  }
  return UtenTotalEntry(total.label, value, danger: danger);
}

/// 一组服务端合计项 → 合计条的项列表（空值项由合计条自行隐藏）。
///
/// 重量伴随项 (「<重量key>_unknown_rows」「<重量key>_estimated_rows」两个 count 项)
/// 并进对应重量项，不单独占位。
List<UtenTotalEntry> reportTotalEntries(
  Iterable<ReportTotal> totals, {
  WeightDisplay weightDisplay = WeightDisplay.auto,
}) {
  final list = totals.toList(growable: false);
  final byKey = {for (final t in list) t.key: t};
  int companion(String weightKey, String suffix) {
    final t = byKey['${weightKey}_$suffix'];
    if (t == null || t.type != 'count' || t.groups.isEmpty) return 0;
    return t.groups.first.value.round();
  }

  final folded = <String>{
    for (final t in list)
      if (t.type == 'weight') ...[
        '${t.key}_unknown_rows',
        '${t.key}_estimated_rows',
      ],
  };
  return [
    for (final t in list)
      if (t.type == 'weight')
        reportTotalEntry(
          t,
          weightDisplay: weightDisplay,
          weightEstimated: companion(t.key, 'estimated_rows') > 0,
          weightUnknownRows: companion(t.key, 'unknown_rows'),
        )
      else if (!(t.type == 'count' && folded.contains(t.key)))
        reportTotalEntry(t),
  ];
}

/// 报表表格下方合计条；该报表没声明合计列时返回 null（整条不渲染）。
///
/// 直接喂给 `MasterDataTableView.summaryBar`，由表格统一挂在表体与翻页条之间——
/// 各报表页不自己摆位置，全站间距/字号因此一致。[weightDisplay] = 用户重量显示单位。
Widget? reportTotalsBar(
  List<ReportTotal> totals, {
  WeightDisplay weightDisplay = WeightDisplay.auto,
}) {
  if (totals.isEmpty) return null;
  final entries = reportTotalEntries(totals, weightDisplay: weightDisplay);
  if (entries.every((e) => e.value.trim().isEmpty)) return null;
  return UtenTotalsSummaryBar(density: true, compact: true, entries: entries);
}
