// UtenTimeDisplaySwitcher - 时间显示切换 UI（北京时间 / 当地时间）
//
// 全平台时间默认按北京时间展示（后缀「（北京）」）；切换到当地时间后按
// 设备时区换算并标注当地城市/时区。选择持久化，审计中心与单据时间共用。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/display_datetime.dart';
import '../../shared/providers/time_display_provider.dart';

/// Uten 时间显示切换器（设置页用）
class UtenTimeDisplaySwitcher extends ConsumerWidget {
  const UtenTimeDisplaySwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(timeDisplayModeProvider);
    final notifier = ref.read(timeDisplayModeProvider.notifier);
    final localLabel = DisplayDateTime.localZoneLabel();

    return RadioGroup<String>(
      groupValue: current.persistKey,
      onChanged: (value) {
        if (value == null) return;
        notifier.set(
          TimeDisplayMode.values.firstWhere(
            (mode) => mode.persistKey == value,
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RadioListTile<String>(
            value: TimeDisplayMode.beijing.persistKey,
            title: const Text('北京时间（默认）'),
            subtitle: const Text('全平台时间统一按北京时间显示'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            dense: true,
          ),
          RadioListTile<String>(
            value: TimeDisplayMode.local.persistKey,
            title: Text('当地时间（$localLabel）'),
            subtitle: const Text('按这台设备所在时区换算显示'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            dense: true,
          ),
        ],
      ),
    );
  }
}
