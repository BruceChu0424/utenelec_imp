import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_module_progress_chip.dart';
import 'package:uten_imp/components/feedback/uten_module_todo_chip.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  Future<void> pumpHub(
    WidgetTester tester,
    Widget hub,
    BadgeSummary summary,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          isSuperAdminProvider.overrideWithValue(true),
          fixedBadgeSummaryOverride(summary),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: hub,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectCardCounts(
    WidgetTester tester,
    String label, {
    required int todo,
    int? inProgress,
  }) {
    final card = find.byWidgetPredicate(
      (widget) => widget is UtenHubCard && widget.label == label,
    );
    expect(card, findsOneWidget);
    final red = tester.widget<UtenNotificationBadge>(
      find.descendant(of: card, matching: find.byType(UtenNotificationBadge)),
    );
    expect(red.count, todo);
    expect(red.showLabel, isTrue);
    if (inProgress != null) {
      final yellow = tester.widget<UtenInProgressBadge>(
        find.descendant(of: card, matching: find.byType(UtenInProgressBadge)),
      );
      expect(yellow.count, inProgress);
      expect(yellow.showLabel, isTrue);
    }
  }

  void expectModuleCounts(WidgetTester tester) {
    expect(
      tester.widget<UtenModuleTodoChip>(find.byType(UtenModuleTodoChip)).count,
      10,
    );
    expect(
      tester
          .widget<UtenModuleProgressChip>(find.byType(UtenModuleProgressChip))
          .count,
      4,
    );
    final createCards = find.byWidgetPredicate(
      (widget) => widget is UtenHubCard && widget.label.startsWith('新建'),
    );
    expect(createCards, findsWidgets);
    expect(
      find.descendant(
        of: createCards,
        matching: find.byType(UtenNotificationBadge),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  }

  testWidgets('采购任务卡包括其草稿分类，供应商退货仍为独立任务', (tester) async {
    await pumpHub(
      tester,
      const PurchaseHubPage(),
      badgeSummaryFixture(
        entries: const {
          BadgeEntry.purchaseTaskCenter: (3, 4),
          BadgeEntry.purchaseDrafts: (5, 0),
          BadgeEntry.purchaseSupplierReturn: (2, 0),
        },
      ),
    );

    expectCardCounts(tester, '采购任务中心', todo: 8, inProgress: 4);
    expectCardCounts(tester, '待退回供应商', todo: 2);
    expectModuleCounts(tester);
  });

  testWidgets('委外任务卡包括其草稿分类，退货独立且短交不再次累计', (tester) async {
    await pumpHub(
      tester,
      const SubcontractHubPage(),
      badgeSummaryFixture(
        entries: const {
          BadgeEntry.subcontractTaskCenter: (3, 4),
          BadgeEntry.subcontractDrafts: (5, 0),
          BadgeEntry.subcontractSupplierReturn: (2, 0),
        },
        // 短交已经属于任务中心的三件待办，独立卡只是展示同一事实。
        facts: const {BadgeFact.subcontractShortDeliveryPending: 1},
      ),
    );

    expectCardCounts(tester, '委外任务中心', todo: 8, inProgress: 4);
    expectCardCounts(tester, '待退回供应商', todo: 2);
    expectCardCounts(tester, '回厂短交判定', todo: 1);
    expectModuleCounts(tester);
  });
}
