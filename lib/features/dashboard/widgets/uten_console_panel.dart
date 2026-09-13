// 工作台共用面板：连续的浅色底、细边框和清晰层级。
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

class UtenConsoleHeader extends StatelessWidget {
  const UtenConsoleHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.accentColor,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 4,
          height: 28,
          decoration: BoxDecoration(
            color: accentColor ?? theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: UtenSpacing.s8),
          trailing!,
        ],
      ],
    );
  }
}
