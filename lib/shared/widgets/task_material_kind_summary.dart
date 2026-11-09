// 任务直属物料的逐种摘要：「我的车间任务」与「委外任务中心」的「物料」列共用的唯一入口
// （ADR-095 / ADR-143 2026-11-09 修订）。
//
// 一行按「种」说清物料到位情况——已领 a/n 种 · 缺 k 种 · 计划未下单 j 种 · 可领 m 种 ·
// 待发 p 种；缺=红、可领=蓝、等计划下单=品红、待发=灰。每种物料只落一个桶，数字只来自
// 服务端逐种事实，页面不推算；多种物料时不把不同物料的数量相加成一个数。
// 各业务只组装自己的分段（车间的内料仓/认料前缀、委外的已结束领料），色调、单元格、
// 宽度测算与详情文字在这里统一维护。
import 'package:flutter/material.dart';

import '../../components/inputs/uten_table_cell_action.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// 摘要分段的色调（ADR-169 档位）。
enum MaterialKindTone { plain, short, planning, drawable, muted }

/// 摘要的一段：显示文字 + 色调。
typedef MaterialKindSegment = (String, MaterialKindTone);

/// 逐种分桶的公共分段。[shortDetail] 是「缺」段的括注（如车间的「自制子件 2」）。
/// 已领一段恒在；其余为 0 的桶不显示。
List<MaterialKindSegment> materialKindCountSegments({
  required int kindCount,
  required int issuedKindCount,
  int shortKindCount = 0,
  String? shortDetail,
  int planningGapKindCount = 0,
  int drawableKindCount = 0,
  int awaitingWarehouseKindCount = 0,
}) => [
  ('已领 $issuedKindCount/$kindCount 种', MaterialKindTone.plain),
  if (shortKindCount > 0)
    (
      shortDetail == null
          ? '缺 $shortKindCount 种'
          : '缺 $shortKindCount 种($shortDetail)',
      MaterialKindTone.short,
    ),
  // ADR-117：缺的料里计划还没下单的，单独用品红点出来(可以催计划)。
  if (planningGapKindCount > 0)
    ('计划未下单 $planningGapKindCount 种', MaterialKindTone.planning),
  if (drawableKindCount > 0)
    ('可领 $drawableKindCount 种', MaterialKindTone.drawable),
  if (awaitingWarehouseKindCount > 0)
    ('待发 $awaitingWarehouseKindCount 种', MaterialKindTone.muted),
];

/// 纯文本摘要（列宽测算、排序键、无障碍标签）。
String materialKindSummaryText(List<MaterialKindSegment> segments) =>
    segments.map((segment) => segment.$1).join(' · ');

/// 分段色。表格格子用 ADR-169 状态实底深档（行底色上保证对比），详情里的独立文字
/// 「缺」用主题错误色；可领=蓝、等计划下单=品红、次要=次级文字色、普通=继承。
Color? materialKindToneColor(
  ThemeData theme,
  MaterialKindTone tone, {
  bool inTable = true,
}) {
  final dark = theme.brightness == Brightness.dark;
  return switch (tone) {
    MaterialKindTone.short =>
      inTable
          ? (dark ? UtenColors.errorOnDark : UtenColors.statusDanger)
          : theme.colorScheme.error,
    MaterialKindTone.drawable =>
      dark ? UtenColors.infoOnDark : UtenColors.statusInfo,
    MaterialKindTone.planning =>
      dark ? UtenColors.fuchsiaOnDark : UtenColors.statusFuchsia,
    MaterialKindTone.muted => theme.colorScheme.onSurfaceVariant,
    MaterialKindTone.plain => null,
  };
}

/// 「物料」列单元格：分段着色的一行摘要，单击打开物料明细（[onPressed] 为空时置灰）。
class MaterialKindSummaryCell extends StatelessWidget {
  const MaterialKindSummaryCell({
    super.key,
    required this.segments,
    this.tooltip,
    this.onPressed,
  });

  final List<MaterialKindSegment> segments;
  final String? tooltip;
  final VoidCallback? onPressed;

  /// 列宽测算口径（与单元格同字号同字重）。
  static double measureWidth(
    BuildContext context,
    List<MaterialKindSegment> segments,
    TextScaler textScaler,
  ) => UtenTableCellAction.contentWidthOf(
    context,
    materialKindSummaryText(segments),
    textScaler: textScaler,
    style: Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenTableCellAction.rich(
      label: materialKindSummaryText(segments),
      tooltip: tooltip,
      onPressed: onPressed,
      textSpan: TextSpan(
        style: theme.textTheme.bodySmall,
        children: [
          for (var index = 0; index < segments.length; index++) ...[
            if (index > 0) const TextSpan(text: ' · '),
            TextSpan(
              text: segments[index].$1,
              style: switch (materialKindToneColor(theme, segments[index].$2)) {
                final color? => TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
                null => null,
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// 详情里的摘要文字（任务详情弹窗等独立区块，不在表格行里）。
class MaterialKindSummaryText extends StatelessWidget {
  const MaterialKindSummaryText({super.key, required this.segments});

  final List<MaterialKindSegment> segments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: UtenSpacing.s16,
      runSpacing: UtenSpacing.s4,
      children: [
        for (final segment in segments)
          Text(
            segment.$1,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: materialKindToneColor(theme, segment.$2, inTable: false),
            ),
          ),
      ],
    );
  }
}
