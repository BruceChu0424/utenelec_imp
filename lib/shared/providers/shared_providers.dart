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
/// 必须在 main.dart 通过 override 注入：
/// ```dart
/// ProviderScope(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)])
/// ```
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main.dart',
  ),
);

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
  final cap = ref.watch(deviceCapabilityProvider).valueOrNull;
  if (cap == null) return null;
  return ref.watch(deviceScorerProvider).score(cap);
});
