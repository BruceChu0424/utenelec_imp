// UtenFontScaler - 字号调节 UI
// 文档：docs/00-项目准则/04-字体与字号可调.md §一.1
//
// 2026-09-24 起档位按屏幕容量动态列出（像 Windows「缩放」下拉框，每台机器选项数不同）：
// 「自动」+ 当前窗口放得下的档；所选手动档超出窗口上限（窗口临时变小/分屏）时仍保留选中，
// 并提示实际按多少生效。上限与推荐值由根部 UtenDisplayZoomBox 经 UtenDisplayScale 发布。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/responsive/display_zoom.dart';
import '../../shared/providers/font_scale_provider.dart';

/// Uten 字号调节器（设置页用）
class UtenFontScaler extends ConsumerWidget {
  const UtenFontScaler({super.key});

  static String _pct(double factor) => '${(factor * 100).round()}%';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(fontScaleProvider);
    final notifier = ref.read(fontScaleProvider.notifier);
    final scale = UtenDisplayScale.maybeOf(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // 不在缩放容器之下（单测/独立预览）：不限上限，推荐标准档。
    final maxFactor = scale?.maxFontFactor ?? double.infinity;
    final recommended = scale?.recommendedFontFactor ?? 1.0;
    final effective = scale?.effectiveFontFactor ?? choice.factor ?? 1.0;
    final levels = [
      for (final s in FontScale.values)
        if (s.factor <= maxFactor + 1e-6 || s == choice.manual) s,
    ];
    final hiddenCount = FontScale.values.length - levels.length;
    final recommendedLevel = FontScale.ofFactor(recommended);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: Text('自动（${_pct(recommended)}）'),
              tooltip: '按屏幕大小与系统缩放自动选择',
              selected: choice.isAuto,
              onSelected: (_) => notifier.set(const FontScaleChoice.auto()),
            ),
            for (final s in levels)
              ChoiceChip(
                label: Text('${s.label} ${_pct(s.factor)}'),
                tooltip: s == recommendedLevel ? '推荐' : null,
                selected: choice.manual == s,
                onSelected: (_) => notifier.set(FontScaleChoice.manual(s)),
              ),
          ],
        ),
        if (scale != null) ...[
          const SizedBox(height: 8),
          Text(_capacityNote(scale, hiddenCount), style: muted),
          if (scale.isCapped) ...[
            const SizedBox(height: 4),
            Text(
              '所选「${choice.manual!.label}」超出当前窗口能容纳的大小，'
              '暂按 ${_pct(effective)} 显示；窗口放大后自动恢复。',
              style: muted?.copyWith(color: theme.colorScheme.tertiary),
            ),
          ],
        ],
        const SizedBox(height: 16),
        // 预览
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('预览 Preview', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('优腾综合管理平台 · Uten IMP', style: theme.textTheme.bodyLarge),
              const SizedBox(height: 4),
              Text(
                '当前生效：${_pct(effective)}'
                '${choice.isAuto ? '（自动）' : ''}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              // 2026-09-20 起档位 = 整体缩放（display_zoom.dart）：预览卡本身也随之变大。
              Text('文字、图标、卡片与间距一起等比变化', style: muted),
            ],
          ),
        ),
      ],
    );
  }

  /// 「按当前窗口最大可用哪档、隐藏了几档」说明。
  static String _capacityNote(UtenDisplayScale scale, int hiddenCount) {
    final w = scale.window.width.round();
    final h = scale.window.height.round();
    final dpr = (scale.devicePixelRatio * 100).round();
    final top = FontScale.values.lastWhere(
      (s) => s.factor <= scale.maxFontFactor + 1e-6,
    );
    final head =
        '当前窗口 $w×$h（显示缩放 $dpr%），最大可用「${top.label} ${_pct(top.factor)}」';
    if (hiddenCount <= 0) return '$head。';
    return '$head；更大的 $hiddenCount 档会让一屏内容过少，已隐藏（屏幕更大时自动出现）。';
  }
}
