// 时间展示模式 Provider（北京时间 / 当地时间）
//
// 全平台默认北京时间（后缀「（北京）」）；切换到当地时间后按设备时区换算，
// 后缀变为「（当地 · 城市 UTC±n）」。选择持久化在 SharedPreferences。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_providers.dart';

enum TimeDisplayMode {
  beijing('beijing', '北京时间'),
  local('local', '当地时间');

  const TimeDisplayMode(this.persistKey, this.label);

  final String persistKey;

  /// UI 标签
  final String label;
}

class TimeDisplayModeNotifier extends Notifier<TimeDisplayMode> {
  static const _key = 'timeDisplayMode';

  @override
  TimeDisplayMode build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final saved = prefs.getString(_key);
    return TimeDisplayMode.values.firstWhere(
      (mode) => mode.persistKey == saved,
      orElse: () => TimeDisplayMode.beijing,
    );
  }

  Future<void> set(TimeDisplayMode mode) async {
    await ref.read(sharedPreferencesProvider).setString(_key, mode.persistKey);
    state = mode;
  }

  Future<void> toggle() => set(
    state == TimeDisplayMode.beijing
        ? TimeDisplayMode.local
        : TimeDisplayMode.beijing,
  );
}

final timeDisplayModeProvider =
    NotifierProvider<TimeDisplayModeNotifier, TimeDisplayMode>(
      TimeDisplayModeNotifier.new,
    );
