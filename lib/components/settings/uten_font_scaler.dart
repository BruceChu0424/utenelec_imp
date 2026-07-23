// UtenFontScaler - 字号调节 UI
// 文档：docs/02-组件库/UtenFontScaler.md（待写）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/font_scale_provider.dart';

/// Uten 字号调节器（设置页用）
class UtenFontScaler extends ConsumerWidget {
  const UtenFontScaler({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(fontScaleProvider);
    final notifier = ref.read(fontScaleProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<FontScale>(
          segments: const [
            ButtonSegment(
              value: FontScale.small,
              label: Text('小'),
            ),
            ButtonSegment(
              value: FontScale.medium,
              label: Text('中'),
            ),
            ButtonSegment(
              value: FontScale.large,
              label: Text('大'),
            ),
            ButtonSegment(
              value: FontScale.xLarge,
              label: Text('超大'),
            ),
          ],
          selected: {current},
          onSelectionChanged: (selection) => notifier.set(selection.first),
        ),
        const SizedBox(height: 16),
        // 预览
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '预览 Preview',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                '优腾综合管理平台 · Uten IMP',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 4),
              Text(
                '字号档：${current.persistKey}（${(current.factor * 100).round()}%）',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
