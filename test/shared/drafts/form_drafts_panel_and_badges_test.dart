import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/badges/badge_scope.dart';
import 'package:uten_imp/shared/badges/effective_badge_summary_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

import '../../helpers/badge_summary_fixture.dart';

FormDraft draft(String id, BadgeModule module, {String? route}) => FormDraft(
  id: id,
  title: '新建${module.name}单据 $id',
  module: module,
  route: route ?? '/sales/orders/new?customerId=original',
  permission: 'sales_order:create',
  updatedAt: DateTime.utc(2026, 9, 26, 12),
  data: const {'remark': '填了一半', 'qty': '1.'},
);

class FixedFormDrafts extends FormDraftsNotifier {
  FixedFormDrafts(this.initial);
  final List<FormDraft> initial;
  final List<String> deleted = [];
  @override
  List<FormDraft> build() => initial;
  @override
  Future<void> delete(String id, {String? expectedRevision}) async {
    deleted.add(id);
    state = state.where((draft) => draft.id != id).toList();
  }

  void emit(List<FormDraft> next) => state = next;
}

void main() {
  test(
    'local recovery counts once without changing formal facts or yellow',
    () {
      final server = badgeSummaryFixture(
        entries: {
          BadgeEntry.salesDrafts: (3, 0),
          BadgeEntry.salesOrderInFlight: (0, 8),
          BadgeEntry.purchaseTaskCenter: (4, 7),
        },
        facts: const {'drafts.salesOrder': 3},
        stale: {BadgeEntry.purchaseTaskCenter},
      );
      final sales = draft('sales-1', BadgeModule.sales);
      final effective = includeFormDraftBadges(server, [
        sales,
        sales,
        draft('purchase-1', BadgeModule.purchase),
      ]);
      expect(effective.entryTodo(BadgeEntry.salesDrafts), 4);
      expect(effective.entryTodo(BadgeEntry.purchaseTaskCenter), 4);
      expect(effective.entryTodo(BadgeEntry.purchaseDrafts), 1);
      expect(effective.moduleTodo(BadgeModule.purchase), 5);
      expect(effective.total, const BadgeCounts(9, 15));
      expect(effective.facts, same(server.facts));
      expect(effective.fact('drafts.salesOrder'), 3);
      expect(effective.isStale(BadgeEntry.purchaseTaskCenter), isTrue);
      expect(server.total.todo, 7);
      expect(includeFormDraftBadges(server, [sales]).total.todo, 8);
    },
  );

  test('entry task card adds its local drafts; module never adds twice', () {
    final drafts = FixedFormDrafts([
      draft('purchase-1', BadgeModule.purchase),
      draft('sales-1', BadgeModule.sales),
    ]);
    final container = ProviderContainer(
      overrides: [
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            entries: {
              BadgeEntry.purchaseTaskCenter: (3, 4),
              BadgeEntry.purchaseDrafts: (5, 0),
            },
          ),
        ),
        formDraftsProvider.overrideWith(() => drafts),
      ],
    );
    addTearDown(container.dispose);
    const taskScope = BadgeScope.entry(
      BadgeEntry.purchaseTaskCenter,
      formDraftModule: BadgeModule.purchase,
    );
    expect(
      container.read(badgeScopeCountsProvider(taskScope)),
      const BadgeCounts(4, 4),
    );
    expect(container.read(badgeModuleTodoProvider(BadgeModule.purchase)), 9);
    expect(container.read(badgeTotalTodoProvider), 10);
    drafts.emit([]);
    expect(
      container.read(badgeScopeCountsProvider(taskScope)),
      const BadgeCounts(3, 4),
    );
    expect(container.read(badgeTotalTodoProvider), 8);
  });

  test('local work remains visible before server summary arrives', () {
    final local = includeFormDraftBadges(BadgeSummary.empty, [
      draft('sales-1', BadgeModule.sales),
    ]);
    expect(local.moduleTodo(BadgeModule.sales), 1);
    expect(local.total.todo, 1);
    expect(local.loaded, isFalse);
    expect(local.hasSource('drafts'), isFalse);
  });
}
