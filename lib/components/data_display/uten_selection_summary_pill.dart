import 'package:flutter/material.dart';

import 'package:uten_imp/core/theme/uten_tokens.dart';

/// 「已选 N 项 + ✕ 清除」选择摘要胶囊——全站表格批量动作区的统一口径
/// （原 MasterDataTableView._buildBatchBar 私有实现升位为公共组件）。
///
/// 选中态走主色（primaryContainer 底 + primary 边框/字）；未选态整体降级为
/// 中性灰。固定高 48（UtenTableToolbar.controlHeight），与表头工具条控件等高。
/// ⚠ 不能给 Container 设 alignment（又没给 width 会撑满父级可用宽度）；
/// 垂直居中靠固定 height + Row 默认 crossAxis.center，宽度随内容收紧。
class UtenSelectionSummaryPill extends StatelessWidget {
  const UtenSelectionSummaryPill({
    super.key,
    required this.count,
    this.onClear,
    this.clearKey,
    this.minHeight = UtenTableToolbar.controlHeight,
  });

  /// 当前选中行数（可传服务端口径的汇总数，如跨页全选总数）。
  final int count;

  /// 清除选择（一键清空选中集合）；null = 未选中时不可点。
  final VoidCallback? onClear;

  /// 清除按钮的 Key（master-table-clear-selection 契约由调用方保留传入）。
  final Key? clearKey;

  /// 最小高度。默认对齐表格工具条（48）；放进
  /// [UtenFloatingActionGroup] 时由该组统一抬到 52，调用点不用管。
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSelection = count > 0;
    // 未选态 2026-09-11 加浓：原来是半透明浅灰底 + 极淡边框 + slate400 文字，
    // 在白底上几乎看不见，用户反馈「不选的时候都不知道这里可以点」。
    // 现在是实底 + 可见描边 + 正常灰字——看得见、但与选中态（主色）仍分得清。
    final accent = hasSelection
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final barBackground = hasSelection
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
        : theme.colorScheme.surfaceContainerHigh;
    final barBorder = hasSelection
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
      // 固定 height 改 minHeight：悬浮组会统一抬高到 52 与业务按钮对齐，
      // 超大字号下也还能继续长高（写死 height 会把文字压出去）。
      constraints: BoxConstraints(minHeight: minHeight),
      decoration: BoxDecoration(
        color: barBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: barBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '已选 $count 项', // TODO(l10n): 补 arb
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          const SizedBox(width: UtenSpacing.s4),
          InkWell(
            key: clearKey,
            onTap: onClear,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close_rounded, size: 18, color: accent),
            ),
          ),
        ],
      ),
    );
  }
}
