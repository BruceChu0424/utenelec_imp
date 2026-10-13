// 界面大小调节器：所有窗口都显示 85%～200%，旧 75% 保留兼容选中。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_tokens.dart';
import '../../shared/providers/font_scale_provider.dart';

class UtenFontScaler extends ConsumerWidget {
  const UtenFontScaler({super.key});

  static String _pct(double factor) => '${(factor * 100).round()}%';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(fontScaleProvider);
    final notifier = ref.read(fontScaleProvider.notifier);
    final theme = Theme.of(context);
    final levels = [
      if (choice.manual == FontScale.xSmall) FontScale.xSmall,
      ...FontScale.selectable,
    ];
    final minHeight = UtenControlMetrics.minimumHitExtent(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(UtenRadius.control),
          ),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _pill(
                theme: theme,
                label: '自动（100%）',
                tooltip: '使用标准界面大小，保留系统显示与字体设置',
                minHeight: minHeight,
                selected: choice.isAuto,
                onTap: () => notifier.set(const FontScaleChoice.auto()),
              ),
              for (final scale in levels)
                _pill(
                  theme: theme,
                  label: '${scale.label} ${_pct(scale.factor)}',
                  tooltip: scale == FontScale.xSmall ? '保留的旧版个人设置' : null,
                  minHeight: minHeight,
                  selected: choice.manual == scale,
                  onTap: () => notifier.set(FontScaleChoice.manual(scale)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '文字、图标、按钮、卡片与间距同步调整，内容随可用宽度重新排列。'
          '此设置在当前设备按账号独立记忆。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  static Widget _pill({
    required ThemeData theme,
    required String label,
    required String? tooltip,
    required double minHeight,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final pill = Material(
      color: selected ? theme.colorScheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(UtenRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(UtenRadius.md),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: tooltip == null ? pill : Tooltip(message: tooltip, child: pill),
    );
  }
}
