// 徽章汇总测试夹具(ADR-108): 给页面/卡片测试一份固定的汇总, 不发请求。
//
// 容器与总数按入口求和 —— 模拟服务端 WorkbenchBadgeService 的算法, 页面测试只关心
// 「显示哪个数」; 口径与求和本身由服务端 WorkbenchBadgeSummaryPostgresTest 锁定。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

/// 固定汇总的徽章 notifier: [refresh] 只计次数, [emit] 手动推下一份。
class FixedBadgeSummaryNotifier extends BadgeSummaryNotifier {
  FixedBadgeSummaryNotifier(this._initial);

  final BadgeSummary _initial;

  /// refresh() 被调用的次数(页面「写后刷新 / 返回刷新」的证据)。
  int refreshCalls = 0;

  @override
  BadgeSummary build() => _initial;

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  /// 推一份新汇总(模拟下一轮轮询带回的数)。
  void emit(BadgeSummary next) => state = next;
}

/// 按入口红黄数与事实数拼一份已加载的汇总。
BadgeSummary badgeSummaryFixture({
  Map<BadgeEntry, (int todo, int inProgress)> entries = const {},
  Map<String, int> facts = const {},
  Set<BadgeEntry> stale = const {},
}) {
  final modules = <String, (int, int)>{};
  var todo = 0;
  var inProgress = 0;
  for (final MapEntry(key: entry, value: counts) in entries.entries) {
    final current = modules[entry.module.name] ?? (0, 0);
    modules[entry.module.name] = (
      current.$1 + counts.$1,
      current.$2 + counts.$2,
    );
    todo += counts.$1;
    inProgress += counts.$2;
  }
  return BadgeSummary(
    loaded: true,
    entries: {
      for (final MapEntry(key: entry, value: counts) in entries.entries)
        entry.name: BadgeCounts(counts.$1, counts.$2),
    },
    modules: {
      for (final MapEntry(key: name, value: counts) in modules.entries)
        name: BadgeCounts(counts.$1, counts.$2),
    },
    total: BadgeCounts(todo, inProgress),
    facts: facts,
    staleEntries: {for (final entry in stale) entry.name},
  );
}

/// ProviderScope/ProviderContainer 覆盖: 徽章汇总固定为 [summary]。
Override fixedBadgeSummaryOverride([BadgeSummary? summary]) =>
    badgeSummaryProvider.overrideWith(
      () => FixedBadgeSummaryNotifier(summary ?? badgeSummaryFixture()),
    );
