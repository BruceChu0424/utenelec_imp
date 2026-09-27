import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

import 'badge_registry.dart';
import 'effective_badge_summary_provider.dart';

/// 卡片显示的汇总范围：原始业务队列与公共草稿投影合并后统一取数。
///
/// 合并全部业务的中心用 [BadgeScope.module]；独立队列用 [BadgeScope.entry]。
/// 同一任务中心包含草稿分类时，additionalTodoEntries 声明其草稿入口，入口去重累计。
/// 红黄登记在不同入口时用 [BadgeScope.entries]，例如生产待排产与在办批次。
class BadgeScope {
  const BadgeScope.module(BadgeModule module)
    : _module = module,
      _todo = null,
      _inProgress = null,
      formDraftModule = null,
      additionalTodoEntries = const {};

  const BadgeScope.entry(
    BadgeEntry entry, {
    this.formDraftModule,
    this.additionalTodoEntries = const {},
  }) : _module = null,
       _todo = entry,
       _inProgress = entry;

  const BadgeScope.entries({
    BadgeEntry? todo,
    BadgeEntry? inProgress,
    this.formDraftModule,
    this.additionalTodoEntries = const {},
  }) : assert(todo != null || inProgress != null),
       _module = null,
       _todo = todo,
       _inProgress = inProgress;

  final BadgeModule? _module;
  final BadgeEntry? _todo;
  final BadgeEntry? _inProgress;

  /// 该任务中心同时展示未完成填写草稿时，卡片补入同一份本地数量。
  /// module 口径已含本地草稿，无需再次指定。
  final BadgeModule? formDraftModule;
  final Set<BadgeEntry> additionalTodoEntries;

  BadgeCounts counts(BadgeSummary summary) {
    final module = _module;
    if (module != null) {
      return BadgeCounts(
        summary.moduleTodo(module),
        summary.moduleInProgress(module),
      );
    }
    final todo = _todo;
    final inProgress = _inProgress;
    final todoEntries = {?todo, ...additionalTodoEntries};
    return BadgeCounts(
      todoEntries.fold(0, (sum, entry) => sum + summary.entryTodo(entry)),
      inProgress == null ? 0 : summary.entryInProgress(inProgress),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BadgeScope &&
      _module == other._module &&
      _todo == other._todo &&
      _inProgress == other._inProgress &&
      formDraftModule == other.formDraftModule &&
      setEquals(additionalTodoEntries, other.additionalTodoEntries);

  @override
  int get hashCode => Object.hash(
    _module,
    _todo,
    _inProgress,
    formDraftModule,
    Object.hashAllUnordered(additionalTodoEntries),
  );
}

/// 只订阅当前卡片所需数字；轮询其它入口变化时不重建这张卡的徽章。
final badgeScopeCountsProvider = Provider.family<BadgeCounts, BadgeScope>((
  ref,
  scope,
) {
  final counts = ref.watch(effectiveBadgeSummaryProvider.select(scope.counts));
  final module = scope.formDraftModule;
  if (module == null) return counts;
  final drafts = ref.watch(formDraftModuleCountProvider(module));
  return BadgeCounts(counts.todo + drafts, counts.inProgress);
});
