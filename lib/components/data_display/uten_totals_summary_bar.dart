import 'package:flutter/material.dart';

import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/shared/measurement/measurement_totals.dart';

/// 明细表格下方的合计条——全站「明细 → 汇总（币种/总金额…）」统一口径。
///
/// 视觉与 MasterDataTableView 同语言：与表体同宽、顶部分隔线、右对齐的
/// 「标签 值」序列；关键金额传 [danger] 标红（与审核详情「本单金额」同色规则）。
/// 值为 null/空字符串时该项整体隐藏（避免出现「合计 —」）。
class UtenTotalsSummaryBar extends StatelessWidget {
  const UtenTotalsSummaryBar({
    super.key,
    required this.entries,
    this.density = false,
    this.showDivider = true,
    this.compact = false,
  });

  /// 合计项（按展示顺序）。
  final List<UtenTotalEntry> entries;

  /// 紧凑模式（嵌入卡片内时用，字号略小）。
  final bool density;

  /// 顶部分隔线。嵌在已自带上边框的容器里（如编辑页底部操作条）传 false，
  /// 避免出现两条平行线。
  final bool showDivider;

  /// 收紧纵向内边距。
  ///
  /// 用在列表/报表表格的表尾槽位（`MasterDataTableView.summaryBar`）：下方紧接着翻页条，
  /// 翻页条自己已有 8px 内边距，合计条再留 8+4 就显得松，且在 375px × 1.5 倍字号下
  /// 这 8px 会把表体挤到溢出。详情/编辑页的独立合计条保持默认（false）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 空串与「—」（调用方金额格式化的空值占位）都视为无值整体隐藏，
    // 避免出现「折合本币: —」这种空项。
    final visible = entries
        .where((e) => e.value.trim().isNotEmpty && e.value.trim() != '—')
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final valueStyle =
        (density ? theme.textTheme.bodyMedium : theme.textTheme.titleSmall)
            ?.copyWith(fontWeight: FontWeight.w700);
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
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s4,
        children: [
          // 标签与数值包成一个不可拆的 Row：窄屏换行只会在项与项之间发生，
          // 不会把「合计金额」和它的数值拆到两行。
          for (final e in visible)
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('${e.label}: ', style: labelStyle),
                // 值用 Flexible：窄屏/大字号下在数值内部换行，绝不把 Row 撑溢出
                // （标签与值仍是同一项，不会被 Wrap 拆到两行）。
                Flexible(
                  child: Text(
                    e.value,
                    style: valueStyle?.copyWith(
                      color: e.danger ? theme.colorScheme.error : null,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class UtenTotalEntry {
  const UtenTotalEntry(this.label, this.value, {this.danger = false});

  final String label;
  final String value;

  /// 关键金额标红（error 色）。
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
