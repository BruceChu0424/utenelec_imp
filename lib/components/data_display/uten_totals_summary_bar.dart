import 'package:flutter/material.dart';

import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/shared/measurement/measurement_totals.dart';

/// 明细表格下方的合计条——全站「明细 → 汇总（币种/总金额…）」统一口径。
///
/// 在表格可见范围的右侧显示圆角红底汇总；宽度由汇总项决定。
/// 值为 null/空字符串时该项整体隐藏（避免出现「合计 —」）。
class UtenTotalsSummaryBar extends StatelessWidget {
  const UtenTotalsSummaryBar({
    super.key,
    required this.entries,
    this.density = false,
    this.showDivider = false,
    this.compact = false,
    this.rowCount,
    this.trailing,
  });

  /// 合计项（按展示顺序）。
  final List<UtenTotalEntry> entries;

  /// 保留已有调用接口。汇总始终使用正常正文字号，不因紧凑布局缩小。
  final bool density;

  /// 顶部分隔线。2026-09-15 用户口径：合计条不再画顶部分隔线（表格自带行线，
  /// 紧贴其下再一条横线显得重复）——默认 false；嵌在自带上边框容器里的旧调用
  /// 语义保留，显式传 true 仍可画线。
  final bool showDivider;

  /// 收紧纵向内边距。
  ///
  /// 用在列表/报表表格的表尾槽位（`MasterDataTableView.summaryBar`）：下方紧接着翻页条，
  /// 翻页条自己已有 8px 内边距，合计条再留 8+4 就显得松，且在 375px × 1.5 倍字号下
  /// 这 8px 会把表体挤到溢出。详情/编辑页的独立合计条保持默认（false）。
  final bool compact;

  /// 总行数（明细行数）：非空且 > 0 时在合计条最前显示「总行数: N 行」。
  ///
  /// 2026-09-29 用户口径：带合计条的明细表在最前补行数，方便先看规模再看合计。
  /// 0 行（空表）不显示——与「空值项整体隐藏」同语义。行数不折算、不分组，
  /// 数的是调用方表格里的行（编辑网格含未选货品的空行）。
  final int? rowCount;

  /// Optional adjacent action, outside the amount background.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 空串与「—」（调用方金额格式化的空值占位）都视为无值整体隐藏，
    // 避免出现「折合本币: —」这种空项。
    final visible = <UtenTotalEntry>[
      if (rowCount != null && rowCount! > 0)
        UtenTotalEntry('总行数', '$rowCount 行'),
      ...entries.where(
        (e) => e.value.trim().isNotEmpty && e.value.trim() != '—',
      ),
    ];
    if (visible.isEmpty && trailing == null) return const SizedBox.shrink();
    final summary = visible.isEmpty
        ? null
        : DecoratedBox(
            decoration: const BoxDecoration(
              color: UtenColors.errorText,
              borderRadius: UtenRadius.smAll,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s8,
                vertical: UtenSpacing.s4,
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: UtenSpacing.s16,
                runSpacing: UtenSpacing.s4,
                children: [
                  for (final entry in visible)
                    _UtenTotalEntryView(entry: entry),
                ],
              ),
            ),
          );
    return Container(
      width: double.infinity,
      padding: compact
          ? const EdgeInsets.only(top: UtenSpacing.s4)
          : const EdgeInsets.only(top: UtenSpacing.s8, bottom: UtenSpacing.s4),
      decoration: showDivider
          ? BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            )
          : null,
      child: trailing == null
          ? Align(alignment: AlignmentDirectional.centerEnd, child: summary)
          : Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s4,
              children: [?summary, trailing!],
            ),
    );
  }
}

/// Keeps the full value readable with the active text scaler.
class _UtenTotalEntryView extends StatelessWidget {
  const _UtenTotalEntryView({required this.entry});

  final UtenTotalEntry entry;

  @override
  Widget build(BuildContext context) {
    final heading =
        Theme.of(context).textTheme.titleLarge ?? const TextStyle(fontSize: 18);
    final labelStyle = heading.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w700,
    );
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('${entry.label}: ', style: labelStyle),
        Text(
          entry.value,
          textAlign: TextAlign.end,
          style: labelStyle.copyWith(
            fontSize: (labelStyle.fontSize ?? 18) + 4,
            fontWeight: entry.danger ? FontWeight.w800 : FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class UtenTotalEntry {
  const UtenTotalEntry(this.label, this.value, {this.danger = false});

  final String label;
  final String value;

  /// Adds emphasis to the primary amount.
  final bool danger;
}

/// 「合计数量」项的唯一构造口径：按 unitId 分组，不同单位的数量**绝不相加**，
/// 多单位显示「12 个 · 3 箱」。明细为空时值为「—」，由合计条整体隐藏该项。
UtenTotalEntry utenQuantityTotalEntry(
  Iterable<MeasuredAmount> amounts, {
  String label = '合计数量',
}) => UtenTotalEntry(label, measurementTotalsText(amounts));

/// 金额项标签：币种名取自单据表头（不硬编码 ¥）；无币种时退回纯「合计金额」。
String utenAmountTotalLabel(String? currencyLabel, {String base = '合计金额'}) {
  final label = currencyLabel?.trim();
  if (label == null || label.isEmpty || label == '—') return base;
  return '$base($label)';
}
