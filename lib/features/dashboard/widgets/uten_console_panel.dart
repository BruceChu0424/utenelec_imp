// 工作台共用面板：连续的浅色底、细边框和清晰层级。
// （2026-09-28 两段区块合并后，原独立分区标题 UtenConsoleHeader 退役删除。）
import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';

class UtenConsolePanel extends StatelessWidget {
  const UtenConsolePanel({
    super.key,
    required this.child,
    this.accentColor,
    this.padding = const EdgeInsets.all(UtenSpacing.s16),
    this.sweepTrigger = 0,
  });

  final Widget child;
  final Color? accentColor;
  final EdgeInsetsGeometry padding;
  // 保留刷新标识接口，刷新不触发装饰性扫描动画。
  final int sweepTrigger;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.control),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .65)),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
