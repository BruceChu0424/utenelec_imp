// 徽章汇总 —— 全站红黄徽章与通知未读数的唯一数据源(ADR-108)。
//
// 一次 GET /api/workbench/badges 带回当前身份全部入口、容器、总数与页内分段细数。
// 取代此前约 40 个各自 60s 轮询的计数 provider(回一次工作台打出约 40 个请求)。
//
// 节奏:
//   · 登录后立即拉一次, 之后每 60s 一次;
//   · 页面隐藏/切后台时暂停, 回到前台立即拉一次;
//   · 写操作成功、返回工作台、新通知到达时调 [BadgeSummaryNotifier.refresh];
//   · 兜底(2026-09-24 用户反馈「车间任务点批量开工后分类徽章出不来, 得手动刷新」):
//     网络层每记一次本端业务写([lastDataWriteProvider]), 静默 [writeSettle] 后补拉一次——
//     页面漏调 refresh 也不会让徽章停在旧数上; 连续写(逐单提交)合并成末尾一次,
//     期间有人显式 refresh 就取消这次补拉(那次取数已在写之后, 不重复请求);
//   · 单飞: 同一帧里多处调用合并成一个请求; 请求在途时再调用只在其返回后补一次;
//   · 登出/换身份: 作用域变化, 整体重建为空, 旧定时器与迟到响应作废。
// 取数失败保留上一次的数(准则 §四之三, 徽章不闪 0); 服务端标记某些入口本次没算出
// (staleEntries)时, 这些入口保留上一次的数, 所在容器与总数按差额修正(只把这些入口
// 换回上一次的数, 其它健康入口的变化照常反映); 没算出的来源(staleSources)的
// 页内分段事实数同样保留上一次的数。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/connection_recovery.dart';
import '../../core/network/data_write_revision.dart';
import '../providers/app_visibility_provider.dart';
import '../providers/authenticated_scope_provider.dart';
import 'badge_module.dart';
import 'badge_registry.dart' show BadgeEntry;

/// 红(待办)与黄(进行中)两个数。
@immutable
class BadgeCounts {
  const BadgeCounts(this.todo, this.inProgress);

  static const zero = BadgeCounts(0, 0);

  final int todo;
  final int inProgress;

  factory BadgeCounts.fromJson(Object? json) {
    if (json is! Map) return zero;
    return BadgeCounts(_int(json['todo']), _int(json['inProgress']));
  }

  BadgeCounts _plus(BadgeCounts other) =>
      BadgeCounts(todo + other.todo, inProgress + other.inProgress);

  @override
  bool operator ==(Object other) =>
      other is BadgeCounts &&
      other.todo == todo &&
      other.inProgress == inProgress;

  @override
  int get hashCode => Object.hash(todo, inProgress);
}

/// 一份徽章汇总快照。值相等即同一份(与 generatedAt 无关), 轮询没变化时不触发重建。
@immutable
class BadgeSummary {
  const BadgeSummary({
    this.loaded = false,
    this.entries = const {},
    this.modules = const {},
    this.total = BadgeCounts.zero,
    this.facts = const {},
    this.staleEntries = const {},
    this.staleSources = const {},
  });

  /// 未登录 / 还没拉到过 = 全 0。
  static const empty = BadgeSummary();

  /// 至少成功拉到过一次。
  final bool loaded;
  final Map<String, BadgeCounts> entries;
  final Map<String, BadgeCounts> modules;
  final BadgeCounts total;
  final Map<String, int> facts;

  /// 服务端本次没算出的入口(它们的数取自上一份)。
  final Set<String> staleEntries;

  /// 服务端本次没算出的来源(它们的事实数取自上一份)。
  final Set<String> staleSources;

  factory BadgeSummary.fromJson(Map<String, dynamic> json) {
    Map<String, BadgeCounts> counts(Object? raw) => {
      if (raw is Map)
        for (final entry in raw.entries)
          entry.key.toString(): BadgeCounts.fromJson(entry.value),
    };
    final rawFacts = json['facts'];
    final rawStale = json['staleEntries'];
    final rawStaleSources = json['staleSources'];
    return BadgeSummary(
      loaded: true,
      entries: counts(json['entries']),
      modules: counts(json['modules']),
      total: BadgeCounts.fromJson(json['total']),
      facts: {
        if (rawFacts is Map)
          for (final fact in rawFacts.entries)
            if (fact.value is num) fact.key.toString(): _int(fact.value),
      },
      staleEntries: {
        if (rawStale is List)
          for (final key in rawStale)
            if (key is String) key,
      },
      staleSources: {
        if (rawStaleSources is List)
          for (final key in rawStaleSources)
            if (key is String) key,
      },
    );
  }

  int entryTodo(BadgeEntry entry) => entries[entry.name]?.todo ?? 0;

  int entryInProgress(BadgeEntry entry) => entries[entry.name]?.inProgress ?? 0;

  int moduleTodo(BadgeModule module) => modules[module.name]?.todo ?? 0;

  int moduleInProgress(BadgeModule module) =>
      modules[module.name]?.inProgress ?? 0;

  int fact(String key) => facts[key] ?? 0;

  /// 汇总里带回了该来源(当前身份对原端点有权)。
  bool hasSource(String source) {
    final prefix = '$source.';
    return facts.keys.any((key) => key.startsWith(prefix));
  }

  /// 入口本次没算出(显示的是上一份的数)。
  bool isStale(BadgeEntry entry) => staleEntries.contains(entry.name);

  /// 把服务端标记为没算出的入口换回上一份的数, 所在容器与总数按差额修正:
  /// 减去该入口本次(残缺)的数、加回上一份的数。容器与总数不整体沿用上一份——
  /// 否则某个来源持续出错时, 导航总数与整个容器会冻结在第一次的值上, 其它入口怎么变都不动。
  /// 没算出的来源的事实数(页内分段)同样换回上一份。
  BadgeSummary keepStaleFrom(BadgeSummary previous) {
    if ((staleEntries.isEmpty && staleSources.isEmpty) || !previous.loaded) {
      return this;
    }
    final nextEntries = Map<String, BadgeCounts>.of(entries);
    final nextModules = Map<String, BadgeCounts>.of(modules);
    var nextTotal = total;
    final byName = {for (final entry in BadgeEntry.values) entry.name: entry};
    for (final key in staleEntries) {
      final kept = previous.entries[key];
      if (kept == null) continue; // 上一份也没有: 只能用本次的数
      final partial = entries[key] ?? BadgeCounts.zero;
      final delta = BadgeCounts(
        kept.todo - partial.todo,
        kept.inProgress - partial.inProgress,
      );
      nextEntries[key] = kept;
      nextTotal = nextTotal._plus(delta);
      final module = byName[key]?.module.name;
      if (module != null) {
        nextModules[module] = (nextModules[module] ?? BadgeCounts.zero)._plus(
          delta,
        );
      }
    }
    final nextFacts = Map<String, int>.of(facts);
    for (final source in staleSources) {
      final prefix = '$source.';
      for (final fact in previous.facts.entries) {
        if (fact.key.startsWith(prefix)) nextFacts[fact.key] = fact.value;
      }
    }
    return BadgeSummary(
      loaded: true,
      entries: nextEntries,
      modules: nextModules,
      total: nextTotal,
      facts: nextFacts,
      staleEntries: staleEntries,
      staleSources: staleSources,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BadgeSummary &&
          other.loaded == loaded &&
          other.total == total &&
          mapEquals(other.entries, entries) &&
          mapEquals(other.modules, modules) &&
          mapEquals(other.facts, facts) &&
          setEquals(other.staleEntries, staleEntries) &&
          setEquals(other.staleSources, staleSources);

  @override
  int get hashCode => Object.hash(
    loaded,
    total,
    entries.length,
    modules.length,
    facts.length,
    staleEntries.length,
    staleSources.length,
  );
}

int _int(Object? value) => value is num ? value.toInt() : 0;

/// 全站唯一的徽章数据源。见文件头。
final badgeSummaryProvider =
    NotifierProvider<BadgeSummaryNotifier, BadgeSummary>(
      BadgeSummaryNotifier.new,
    );

class BadgeSummaryNotifier extends Notifier<BadgeSummary> {
  /// 轮询周期(可见时)。
  static const pollInterval = Duration(seconds: 60);

  /// 本端业务写之后等这么久没有新的写再补拉(合并逐单提交的一串写)。
  static const writeSettle = Duration(milliseconds: 400);

  Timer? _timer;
  Timer? _writeTimer;
  Future<void>? _running;
  bool _dirty = false;
  bool _active = false;
  bool _visible = true;
  int _generation = 0;

  @override
  BadgeSummary build() {
    final scope = ref.watch(authenticatedScopeProvider);
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    _writeTimer?.cancel();
    _writeTimer = null;
    _running = null;
    _dirty = false;
    _active = scope != null;
    ref.onDispose(() {
      if (_generation == generation) {
        _generation++;
        _active = false;
        _timer?.cancel();
        _timer = null;
        _writeTimer?.cancel();
        _writeTimer = null;
      }
    });
    if (!_active) return BadgeSummary.empty;

    _visible = ref.read(appVisibilityProvider);
    ref.listen<bool>(appVisibilityProvider, (previous, visible) {
      _visible = visible;
      if (visible) {
        unawaited(refresh());
      } else {
        _timer?.cancel();
        _timer = null;
      }
    });
    // 断网恢复后补拉一次(不重建网络层, 见 ADR-108 网络层一节)。
    ref.listen<int>(
      connectionRecoveryProvider.select((state) => state.recoveryEpoch),
      (previous, next) {
        if (next > (previous ?? 0)) unawaited(refresh());
      },
    );
    // 本端业务写成功后补拉(见文件头「兜底」): 静默 writeSettle 再拉, 连续写只拉末尾一次。
    ref.listen<({int seq, String path})?>(lastDataWriteProvider, (
      previous,
      next,
    ) {
      if (next == null || next.seq == previous?.seq) return;
      _writeTimer?.cancel();
      _writeTimer = Timer(writeSettle, () {
        _writeTimer = null;
        if (_generation == generation) unawaited(refresh());
      });
    });
    // 首次拉取放到微任务: build 返回后 state 才可写。
    scheduleMicrotask(() {
      if (_generation == generation) unawaited(refresh());
    });
    return BadgeSummary.empty;
  }

  /// 立即重拉一次(单飞合并)。页面隐藏时只记下「有变化」, 回到前台再拉。
  Future<void> refresh() {
    if (!_active) return Future<void>.value();
    // 这次取数发生在此前所有写之后, 等写静默的补拉不必再发。
    _writeTimer?.cancel();
    _writeTimer = null;
    _dirty = true;
    final running = _running;
    if (running != null) return running;
    final run = _run(_generation);
    _running = run;
    return run;
  }

  Future<void> _run(int generation) async {
    // 让同一帧里的其它 refresh() 调用合并进这一次。
    await Future<void>.value();
    try {
      while (_dirty && _visible && generation == _generation) {
        _dirty = false;
        await _fetch(generation);
      }
    } finally {
      if (generation == _generation) {
        _running = null;
        _schedulePoll();
      }
    }
  }

  Future<void> _fetch(int generation) async {
    try {
      final json = await ref
          .read(apiClientProvider)
          .get(ApiEndpoints.workbenchBadges);
      if (generation != _generation) return;
      final next = BadgeSummary.fromJson(json).keepStaleFrom(state);
      if (next != state) state = next;
    } catch (_) {
      // 网络/服务异常保留上一次的数, 下一轮再试。
    }
  }

  void _schedulePoll() {
    _timer?.cancel();
    _timer = null;
    if (!_active || !_visible) return;
    _timer = Timer(pollInterval, () => unawaited(refresh()));
  }
}
