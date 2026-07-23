// 性能档 Provider（自动检测 + 用户手动覆盖）
// 文档：docs/00-项目准则/07-性能自适应.md
// 决策：ADR-003-性能分级三档.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import 'shared_providers.dart';

/// 性能档管理
///
/// 计算：用户偏好（持久化）→ 强制档位 / 设备推荐档位 → 当前档位
///
/// 注意：不用 late final 字段。Riverpod 2 的 Notifier 在依赖（如
/// recommendedTierProvider）变化时会复用同一实例重新 build()，
/// 二次给 late final 赋值会抛 LateInitializationError。
class PerformanceNotifier extends Notifier<PerformanceTier> {
  static const _key = 'performancePreference';

  @override
  PerformanceTier build() {
    final prefs = ref.read(sharedPreferencesProvider);

    // 读取用户偏好
    final saved = prefs.getString(_key);
    final preference = PerformancePreference.values.firstWhere(
      (p) => p.name == saved,
      orElse: () => PerformancePreference.auto,
    );

    // 强制档位优先
    final forced = preference.forcedTier;
    if (forced != null) return forced;

    // 否则用设备推荐档位（建立 watch 依赖：检测完成会自动 rebuild）
    final recommended = ref.watch(recommendedTierProvider);
    return recommended ?? PerformanceTier.standard;
  }

  /// 当前用户偏好
  PerformancePreference get preference {
    final saved = ref.read(sharedPreferencesProvider).getString(_key);
    return PerformancePreference.values.firstWhere(
      (p) => p.name == saved,
      orElse: () => PerformancePreference.auto,
    );
  }

  /// 设备推荐档位（用于设置页显示"自动"实际选了哪档）
  PerformanceTier? get recommended => ref.read(recommendedTierProvider);

  /// 切换用户偏好
  Future<void> setPreference(PerformancePreference pref) async {
    await ref.read(sharedPreferencesProvider).setString(_key, pref.name);

    final forced = pref.forcedTier;
    state = forced ?? (ref.read(recommendedTierProvider) ?? PerformanceTier.standard);
  }
}

final performanceProvider =
    NotifierProvider<PerformanceNotifier, PerformanceTier>(PerformanceNotifier.new);
