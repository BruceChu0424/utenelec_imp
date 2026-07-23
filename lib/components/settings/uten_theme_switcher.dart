// UtenThemeSwitcher - 主题切换 UI
// 文档：docs/02-组件库/UtenThemeSwitcher.md（待写）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/theme_provider.dart';

/// Uten 主题切换器（设置页用）
class UtenThemeSwitcher extends ConsumerWidget {
  const UtenThemeSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeProvider);
    final notifier = ref.read(themeProvider.notifier);

    final options = <(ThemeMode, String, IconData)>[
      (ThemeMode.light, '浅色', Icons.light_mode_outlined),
      (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
      (ThemeMode.system, '跟随系统', Icons.settings_brightness_outlined),
    ];

    return RadioGroup<ThemeMode>(
      groupValue: current,
      onChanged: (value) {
        if (value != null) notifier.set(value);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (mode, label, icon) in options)
            RadioListTile<ThemeMode>(
              value: mode,
              title: Row(
                children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 12),
                  Text(label),
                ],
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              dense: true,
            ),
        ],
      ),
    );
  }
}
