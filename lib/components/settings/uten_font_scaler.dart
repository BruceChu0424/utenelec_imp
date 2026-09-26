// UtenFontScaler - 字号调节 UI
// 文档：docs/00-项目准则/04-字体与字号可调.md §一.1
//
// 2026-09-24 起档位按屏幕容量动态列出（像 Windows「缩放」下拉框，每台机器选项数不同）：
// 「自动」+ 当前窗口放得下的档；所选手动档超出窗口上限（窗口临时变小/分屏）时仍保留选中，
// 并提示实际按多少生效。上限与推荐值由根部 UtenDisplayZoomBox 经 UtenDisplayScale 发布。
// 2026-09-25 起选择器 = 灰底轨道内的胶囊组（选中 teal 实心，沿用全站「选中只变
// 背景色、不打勾」范式），预览卡退役——档位即整体缩放，整页本身就是实时预览。

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
    final levels = [
      for (final s in FontScale.values)
        if (s.factor <= maxFactor + 1e-6 || s == choice.manual) s,
    ];
    final hiddenCount = FontScale.values.length - levels.length;
    final recommendedLevel = FontScale.ofFactor(recommended);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _pill(
                theme: theme,
                label: '自动（${_pct(recommended)}）',
                tooltip: '按屏幕大小与系统缩放自动选择',
                selected: choice.isAuto,
                onTap: () => notifier.set(const FontScaleChoice.auto()),
              ),
              for (final s in levels)
                _pill(
                  theme: theme,
                  label: '${s.label} ${_pct(s.factor)}',
                  tooltip: s == recommendedLevel ? '推荐' : null,
                  selected: choice.manual == s,
                  onTap: () => notifier.set(FontScaleChoice.manual(s)),
                ),
            ],
          ),
        ),
        if (scale != null) ...[
          const SizedBox(height: 8),
          Text(_capacityNote(scale, hiddenCount), style: muted),
          if (scale.isCapped) ...[
            const SizedBox(height: 4),
            Text(
              '所选「${choice.manual!.label}」超出当前窗口能容纳的大小，'
              '暂按 ${_pct(scale.effectiveFontFactor)} 显示；窗口放大后自动恢复。',
              style: muted?.copyWith(color: theme.colorScheme.tertiary),
            ),
          ],
        ],
      ],
    );
  }

  /// 轨道里的一颗档位胶囊：未选 = 透明底灰字，选中 = 主色实心白字（不加勾）。
  static Widget _pill({
    required ThemeData theme,
    required String label,
    required String? tooltip,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final pill = Material(
      color: selected ? theme.colorScheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
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
    );
    return Semantics(
      button: true,
      selected: selected,
      child: tooltip == null ? pill : Tooltip(message: tooltip, child: pill),
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
