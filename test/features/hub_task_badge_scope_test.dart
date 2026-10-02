import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/production/pages/production_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  Future<void> pumpHub(
    WidgetTester tester,
    Widget page,
    BadgeSummary summary,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(true),
          fixedBadgeSummaryOverride(summary),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Finder card(String label) => find.byWidgetPredicate(
    (widget) => widget is UtenHubCard && widget.label == label,
  );

  List<int> redCounts(WidgetTester tester, String label) => tester
      .widgetList<UtenNotificationBadge>(
        find.descendant(
          of: card(label),
          matching: find.byType(UtenNotificationBadge),
        ),
      )
      .map((badge) => badge.count)
      .toList();

  void expectNewCardsWithoutCounts(WidgetTester tester) {
    final newCards = tester.widgetList<UtenHubCard>(
      find.byWidgetPredicate(
        (widget) => widget is UtenHubCard && widget.label.startsWith('新建'),
      ),
    );
    expect(newCards, isNotEmpty);
    for (final card in newCards) {
      expect(card.badgeScope, isNull);
      expect(card.badge, isNull);
      expect(card.progressBadge, isNull);
    }
  }

  testWidgets('仓库任务中心取本模块全部红黄数，新建卡保持无徽章', (tester) async {
    await pumpHub(
      tester,
      const WarehouseHubPage(),
      badgeSummaryFixture(
        entries: const {
          BadgeEntry.warehouseOutboundCenter: (2, 0),
          BadgeEntry.warehouseInboundCenter: (3, 0),
          BadgeEntry.warehouseDrawCenter: (5, 0),
          BadgeEntry.warehouseQualityResult: (7, 11),
          BadgeEntry.warehouseDrafts: (13, 0),
          BadgeEntry.salesDrafts: (97, 0),
        },
      ),
    );

    expect(redCounts(tester, '仓库任务中心'), [30]);
    // 黄色「进行中」徽章 count=11。
    final inProgress = tester.widgetList<UtenInProgressBadge>(
      find.byType(UtenInProgressBadge),
    );
    expect(inProgress.any((b) => b.count == 11), isTrue);
    expect(find.text('待办 30'), findsOneWidget);
    expectNewCardsWithoutCounts(tester);
  });

  testWidgets('生产任务与审批各取自己的数，保留逾期与催料提示', (tester) async {
    await pumpHub(
      tester,
      const ProductionHubPage(),
      badgeSummaryFixture(
        entries: const {
          BadgeEntry.productionSchedule: (2, 0),
          BadgeEntry.productionBatches: (0, 13),
          BadgeEntry.productionPlanningUrges: (5, 0),
          BadgeEntry.productionRateApprovals: (3, 0),
          BadgeEntry.productionMaterialIncrementApprovals: (7, 0),
          BadgeEntry.productionDrafts: (11, 0),
          BadgeEntry.productionWorkshop: (97, 89),
        },
        facts: const {
          BadgeFact.productionScheduleCount: 2,
          BadgeFact.productionScheduleUrgent: 1,
          BadgeFact.productionScheduleOverdue: 1,
        },
      ),
    );

    expect(redCounts(tester, '生产任务中心'), unorderedEquals([2, 5]));
    expect(redCounts(tester, '超产比例审批'), [3]);
    expect(redCounts(tester, '追加用料审批'), [7]);
    expect(find.text('逾期 1'), findsOneWidget);
    expect(
      tester
          .widget<UtenNotificationBadge>(
            find.descendant(
              of: card('生产任务中心'),
              matching: find.byType(UtenNotificationBadge),
            ),
          )
          .count,
      13,
    );
    expect(find.text('待办 28'), findsOneWidget);
    expectNewCardsWithoutCounts(tester);
  });

  testWidgets('财务审核与报销不混入草稿或彼此计数，保留审核语义', (tester) async {
    await pumpHub(
      tester,
      const FinanceHubPage(),
      badgeSummaryFixture(
        entries: const {
          BadgeEntry.financeAuditCenter: (4, 0),
          BadgeEntry.expenseFinance: (6, 0),
          BadgeEntry.financeDrafts: (9, 0),
          BadgeEntry.salesDrafts: (97, 0),
        },
      ),
    );

    expect(redCounts(tester, '业务审核中心'), [4]);
    expect(redCounts(tester, '报销审批'), [6]);
    expect(find.text('待办 19'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '待我审核共 4 笔',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('uten-module-progress-chip')),
      findsNothing,
    );
    expectNewCardsWithoutCounts(tester);
  });
}
