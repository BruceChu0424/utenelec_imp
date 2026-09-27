import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../drafts/form_draft_store.dart';
import '../drafts/form_draft_category.dart';
import 'badge_registry.dart';

/// 已保存的业务草稿由服务端统计；尚未形成单据的填写草稿在此补入一次。
/// 保留原始 facts，避免把本地草稿塞进只查询业务单据的分段列表。
final effectiveBadgeSummaryProvider = Provider<BadgeSummary>((ref) {
  final server = ref.watch(badgeSummaryProvider);
  final drafts = ref.watch(formDraftsProvider);
  return includeFormDraftBadges(server, drafts);
});

final formDraftModuleCountProvider = Provider.family<int, BadgeModule>(
  (ref, module) => ref.watch(
    formDraftCategoryCountProvider(FormDraftCategoryScope(module: module)),
  ),
);

BadgeEntry? _draftEntry(FormDraft draft) => switch (draft.module) {
  BadgeModule.sales => BadgeEntry.salesDrafts,
  BadgeModule.purchase => BadgeEntry.purchaseDrafts,
  BadgeModule.subcontract => BadgeEntry.subcontractDrafts,
  BadgeModule.production => BadgeEntry.productionDrafts,
  BadgeModule.warehouse => BadgeEntry.warehouseDrafts,
  BadgeModule.finance => BadgeEntry.financeDrafts,
  BadgeModule.people when draft.route.startsWith('/expense/') =>
    BadgeEntry.expenseMine,
  BadgeModule.people => BadgeEntry.hrTaskCenter,
  _ => null,
};

/// 纯投影，不修改轮询快照；多次投影不会把本地数量回写成下次服务端基数。
BadgeSummary includeFormDraftBadges(
  BadgeSummary server,
  Iterable<FormDraft> drafts,
) {
  final unique = {
    for (final draft in drafts)
      if (!formDraftHasFormalDraftCounter(draft) ||
          formDraftConfirmedIds(draft).isEmpty)
        draft.id: draft,
  }.values;
  if (unique.isEmpty) return server;
  final entries = Map<String, BadgeCounts>.of(server.entries);
  final modules = Map<String, BadgeCounts>.of(server.modules);
  for (final draft in unique) {
    final entry = _draftEntry(draft);
    if (entry != null) {
      final counts = entries[entry.name] ?? BadgeCounts.zero;
      entries[entry.name] = BadgeCounts(counts.todo + 1, counts.inProgress);
    }
    final counts = modules[draft.module.name] ?? BadgeCounts.zero;
    modules[draft.module.name] = BadgeCounts(
      counts.todo + 1,
      counts.inProgress,
    );
  }
  return BadgeSummary(
    loaded: server.loaded,
    entries: entries,
    modules: modules,
    total: BadgeCounts(
      server.total.todo + unique.length,
      server.total.inProgress,
    ),
    facts: server.facts,
    staleEntries: server.staleEntries,
    staleSources: server.staleSources,
  );
}
