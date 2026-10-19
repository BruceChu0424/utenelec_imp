// 全局 Provider 集合
// 文档：docs/05-架构/状态管理.md
//
// 这里集中所有跨 feature 共享的 Provider：
// - sharedPreferencesProvider：偏好存储（main.dart override）
// - themeProvider / localeProvider / fontScaleProvider / performanceProvider：四大可调项
// - currentSessionProvider：当前登录会话
// - deviceCapabilityProvider：设备能力（启动时探测一次）

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/performance/device_scorer.dart';
import '../../core/performance/performance_tier.dart';

// ===== 基础设施 Provider =====

/// SharedPreferences 实例
///
/// 真实实例必须在 main.dart 通过 override 注入：
/// ```dart
/// ProviderScope(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)])
/// ```
///
/// 未注入时（测试容器/预览）返回全内存空实现而不是抛错：Riverpod 3 的
/// container.listen 会同步挂载整条依赖链，抛错会把上千个未显式注入 prefs 的
/// 测试连人带 widget 一起击穿；空实现读出全默认值、写入不持久化，语义等同
/// v2 时代「测试里从未真正读到存储」的事实行为。
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => InMemorySharedPreferences(),
);

/// sharedPreferencesProvider 的未注入兜底：读写仅落在进程内存。
class InMemorySharedPreferences implements SharedPreferences {
  final Map<String, Object> _values = {};

  @override
  Set<String> getKeys() => _values.keys.toSet();

  @override
  Object? get(String key) => _values[key];

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  int? getInt(String key) => _values[key] as int?;

  @override
  double? getDouble(String key) => _values[key] as double?;

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  bool containsKey(String key) => _values.containsKey(key);

  @override
  List<String>? getStringList(String key) =>
      (_values[key] as List<Object?>?)?.cast<String>();

  @override
  Future<bool> setBool(String key, bool value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }

  @override
  Future<bool> commit() async => true;

  @override
  Future<bool> clear() async {
    _values.clear();
    return true;
  }

  @override
  Future<void> reload() async {}
}

/// 设备探测 + 打分器
final deviceProbeProvider = Provider<DeviceProbe>((ref) => DeviceProbe());

final deviceScorerProvider = Provider<DeviceScorer>(
  (ref) => const DeviceScorer(),
);

/// 启动时探测一次设备能力
final deviceCapabilityProvider = FutureProvider<DeviceCapability>((ref) async {
  final probe = ref.watch(deviceProbeProvider);
  return probe.probe();
});

/// 设备推荐档位（基于检测结果）
final recommendedTierProvider = Provider<PerformanceTier?>((ref) {
  final cap = ref.watch(deviceCapabilityProvider).value;
  if (cap == null) return null;
  return ref.watch(deviceScorerProvider).score(cap);
});
