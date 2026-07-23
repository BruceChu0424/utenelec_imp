// UtenPerformanceTierSwitcher - 性能档切换 UI
// 文档：docs/02-组件库/UtenPerformanceTierSwitcher.md（待写）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../shared/providers/performance_provider.dart';

/// Uten 性能档切换器（设置页用）
class UtenPerformanceTierSwitcher extends ConsumerWidget {
  const UtenPerformanceTierSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(performanceProvider.notifier);
    final currentPref = notifier.preference;
    final currentTier = ref.watch(performanceProvider);
    final recommended = notifier.recommended;

    final options = <(PerformancePreference, String, String, IconData)>[
      (PerformancePreference.auto, '自动', '根据设备自动选择', Icons.auto_mode),
      (PerformancePreference.lite, '省电', '禁用动效，最省电', Icons.battery_saver),
      (PerformancePreference.standard, '标准', '平衡性能与效果', Icons.tune),
      (PerformancePreference.rich, '极致', '玻璃拟态+完整动画', Icons.auto_awesome),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RadioGroup<PerformancePreference>(
          groupValue: currentPref,
          onChanged: (value) {
            if (value != null) notifier.setPreference(value);
          },
          child: Column(
            children: [
              for (final (pref, label, desc, icon) in options)
                RadioListTile<PerformancePreference>(
                  value: pref,
                  title: Row(
                    children: [
                      Icon(icon, size: 20),
                      const SizedBox(width: 12),
                      Text(label),
                    ],
                  ),
                  subtitle: Text(desc),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  dense: true,
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 当前实际档位信息
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  currentPref.isAuto
                      ? '当前档位：${currentTier.name}（设备推荐：${recommended?.name ?? '-'}）'
                      : '当前档位：${currentTier.name}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
