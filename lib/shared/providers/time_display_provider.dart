// 业务时间固定为北京时间。旧 local 枚举和存储键只供旧调用兼容，
// 已保存的当地时间偏好不能再改变业务时间的含义或后缀。

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
  TimeDisplayMode build() => TimeDisplayMode.beijing;

  Future<void> set(TimeDisplayMode mode) async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, TimeDisplayMode.beijing.persistKey);
    state = TimeDisplayMode.beijing;
  }

  Future<void> toggle() => set(TimeDisplayMode.beijing);
}

final timeDisplayModeProvider =
    NotifierProvider<TimeDisplayModeNotifier, TimeDisplayMode>(
      TimeDisplayModeNotifier.new,
    );
