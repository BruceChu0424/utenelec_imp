import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/badges/badge_scope.dart';
import 'package:uten_imp/shared/badges/effective_badge_summary_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';

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
  test('prepayment finance input stays on its existing follow-up task', () {
    final checkpoint = FormDraft(
      id: 'prepayment-finance-input',
      title: '关联预付入账',
      module: BadgeModule.finance,
      route:
          '/applications/application-1?draftForm=applicationPrepaymentFinance',
      permission: 'application:prepayment:link_finance',
      draftKind: 'business_application_prepayment_finance',
      updatedAt: DateTime(2026, 11, 3),
      data: const {'createdDocId': 'application-1'},
    );
    final server = badgeSummaryFixture(
      entries: {BadgeEntry.applicationFinance: (1, 2)},
    );
    final result = includeFormDraftBadges(server, [checkpoint]);
    expect(result.entryTodo(BadgeEntry.applicationFinance), 1);
    expect(result.entryInProgress(BadgeEntry.applicationFinance), 2);
    expect(result.entryTodo(BadgeEntry.financeDrafts), 0);
  });

  test(
    'payment input checkpoints use the application finance task without double counting',
    () {
      final checkpoint = FormDraft(
        id: 'payment-input',
        title: '登记申请付款',
        module: BadgeModule.finance,
        route: '/applications/application-1?draftForm=applicationPayment',
        permission: 'application:pay',
        draftKind: 'business_application_payment',
        updatedAt: DateTime(2026, 11, 3),
        data: const {'createdDocId': 'application-1'},
      );
      final server = badgeSummaryFixture(
        entries: {BadgeEntry.applicationFinance: (1, 0)},
      );
      final result = includeFormDraftBadges(server, [checkpoint]);
      expect(result.entryTodo(BadgeEntry.applicationFinance), 1);
      expect(result.entryTodo(BadgeEntry.financeDrafts), 0);
      expect(result.total, const BadgeCounts(1, 0));
    },
  );

  test(
    'application checkpoints belong to self applications and confirmed drafts count once',
    () {
      FormDraft application(String id, Map<String, dynamic> data) => FormDraft(
        id: id,
        title: '出差申请',
        module: BadgeModule.people,
        route: '/applications/new?kind=TRAVEL',
        permission: 'application:apply:travel',
        draftKind: 'business_application',
        updatedAt: DateTime(2026, 11, 3),
        data: data,
      );
      final server = badgeSummaryFixture(
        entries: {BadgeEntry.applicationMine: (2, 1)},
      );
      final result = includeFormDraftBadges(server, [
        application('local', const {'title': '待填写'}),
        application('confirmed', const {'createdDocId': 'server-draft'}),
      ]);
      expect(result.entryTodo(BadgeEntry.applicationMine), 3);
      expect(result.entryTodo(BadgeEntry.hrTaskCenter), 0);
      expect(result.moduleTodo(BadgeModule.people), 3);
      expect(result.total, const BadgeCounts(3, 1));
    },
  );

  test('production card does not count its local draft entry twice', () {
    final container = ProviderContainer(
      overrides: [
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            entries: const {
              BadgeEntry.productionSchedule: (2, 0),
              BadgeEntry.productionBatches: (0, 7),
              BadgeEntry.productionDrafts: (5, 0),
            },
          ),
        ),
        formDraftsProvider.overrideWith(
          () => FixedFormDrafts([draft('plan-1', BadgeModule.production)]),
        ),
      ],
    );
    addTearDown(container.dispose);
    const scope = BadgeScope.entries(
      todo: BadgeEntry.productionSchedule,
      inProgress: BadgeEntry.productionBatches,
      additionalTodoEntries: {BadgeEntry.productionDrafts},
      formDraftModule: BadgeModule.production,
    );
    expect(
      container.read(badgeScopeCountsProvider(scope)),
      const BadgeCounts(8, 7),
    );
    expect(container.read(badgeModuleTodoProvider(BadgeModule.production)), 8);
  });

  test('one warehouse task plus three task checkpoints remains one todo', () {
    final checkpoints = [
      FormDraftCatalog.arrival.spec(
        route: '/warehouse/inbound/arrivals/register?expectationIds=source-a',
      ),
      FormDraftCatalog.warehouseQualityStockIn.spec(
        route: '/warehouse/quality-results/PURCHASE/receipt-a',
      ),
      FormDraftCatalog.warehouseSalesOutbound.spec(
        route: '/warehouse/sales-outbound/shipment-a',
      ),
    ];
    final local = [
      for (var index = 0; index < checkpoints.length; index++)
        FormDraft(
          id: 'checkpoint-$index',
          title: checkpoints[index].title,
          module: checkpoints[index].module,
          route: checkpoints[index].route,
          permission: checkpoints[index].permission,
          updatedAt: DateTime.utc(2026, 10, 12),
          data: const {},
        ),
    ];
    final server = badgeSummaryFixture(
      entries: const {
        BadgeEntry.warehouseWorkshopMaterial: (1, 0),
        BadgeEntry.warehouseQualityResult: (0, 1),
      },
    );
    final effective = includeFormDraftBadges(server, local);
    expect(effective.moduleTodo(BadgeModule.warehouse), 1);
    expect(effective.moduleInProgress(BadgeModule.warehouse), 1);
    expect(effective.entryTodo(BadgeEntry.warehouseDrafts), 0);
    expect(effective.facts, same(server.facts));
  });

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
