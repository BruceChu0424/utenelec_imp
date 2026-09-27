import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/sales/pages/sales_hub_page.dart';
import 'package:uten_imp/features/sales/pages/sales_task_center_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../helpers/badge_summary_fixture.dart';

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  ProviderContainer containerFor(
    WidgetTester tester,
    BadgeSummary summary, {
    Set<String> permissions = const {Perm.salesOrderView},
  }) {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(summary),
        // This suite checks the server summary only. Local-draft merging has
        // its own authenticated tests; do not construct a real session/probe.
        authenticatedScopeProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpPage(
    WidgetTester tester,
    ProviderContainer container, [
    Widget page = const SalesHubPage(),
  ]) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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

  Finder taskCard() => find.byWidgetPredicate(
    (widget) => widget is UtenHubCard && widget.label == '销售任务中心',
  );

  Finder cardRedBadge() => find.descendant(
    of: taskCard(),
    matching: find.byType(UtenNotificationBadge),
  );

  testWidgets('只有订货草稿时，订货进度与外层任务中心卡都显示红徽章', (tester) async {
    final container = containerFor(
      tester,
      badgeSummaryFixture(
        entries: const {BadgeEntry.salesDrafts: (3, 0)},
        facts: const {'drafts.salesOrder': 3},
      ),
    );
    await pumpPage(tester, container, const SalesTaskCenterPage());
    expect(find.text('订货进度'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    await pumpPage(tester, container);
    expect(
      find.descendant(of: taskCard(), matching: find.text('3')),
      findsOneWidget,
    );
    expect(find.text('待办 3'), findsOneWidget);
  });

  testWidgets('任务中心累计全部销售待办一次，红黄分开且新建卡不挂数', (tester) async {
    final container = containerFor(
      tester,
      badgeSummaryFixture(
        entries: const {
          BadgeEntry.salesAttention: (5, 0),
          BadgeEntry.salesDrafts: (10, 0),
          BadgeEntry.salesShipmentFinanceRejected: (2, 0),
          BadgeEntry.salesOrderInFlight: (0, 7),
          BadgeEntry.purchaseDrafts: (99, 0),
        },
        // 这些是入口的明细，不能在卡片上再加一次；零星发货包含在出货草稿内。
        facts: const {
          'drafts.salesOrder': 2,
          'drafts.salesShipment': 1,
          'drafts.salesReturn': 3,
          'drafts.salesQuote': 4,
          'financeRejected.salesShipment': 2,
        },
      ),
      permissions: const {
        Perm.salesOrderView,
        Perm.salesOrderCreate,
        Perm.salesShipmentView,
        Perm.salesShipmentCreate,
        Perm.salesOtherShipmentView,
        Perm.salesOtherShipmentCreate,
        Perm.salesReturnView,
        Perm.salesReturnCreate,
        Perm.salesQuoteView,
        Perm.salesQuoteCreate,
      },
    );
    await pumpPage(tester, container);

    expect(tester.widget<UtenNotificationBadge>(cardRedBadge()).count, 17);
    expect(
      find.descendant(of: taskCard(), matching: find.text('17')),
      findsOneWidget,
    );
    expect(find.text('待办 17'), findsOneWidget);
    final progressBadge = find.descendant(
      of: taskCard(),
      matching: find.byType(UtenInProgressBadge),
    );
    expect(tester.widget<UtenInProgressBadge>(progressBadge).count, 7);
    final newCards = tester.widgetList<UtenHubCard>(
      find.byWidgetPredicate(
        (widget) => widget is UtenHubCard && widget.label.startsWith('新建'),
      ),
    );
    expect(newCards, hasLength(5));
    for (final card in newCards) {
      expect(card.badge, isNull);
      expect(card.progressBadge, isNull);
      expect(card.badgeScope, isNull);
    }
  });

  testWidgets('只有报价查看权限时也显示报价草稿待办', (tester) async {
    final container = containerFor(
      tester,
      badgeSummaryFixture(entries: const {BadgeEntry.salesDrafts: (4, 0)}),
      permissions: const {Perm.salesQuoteView},
    );
    await pumpPage(tester, container);
    expect(
      find.descendant(of: taskCard(), matching: find.text('4')),
      findsOneWidget,
    );
    expect(find.text('新建报价单'), findsNothing);
  });

  testWidgets('无销售查看权限时隐藏任务中心卡', (tester) async {
    final container = containerFor(
      tester,
      badgeSummaryFixture(),
      permissions: const {},
    );
    await pumpPage(tester, container);
    expect(taskCard(), findsNothing);
  });

  testWidgets('汇总更新后徽章同步变化，大数显示99+，清零后隐藏', (tester) async {
    final container = containerFor(tester, badgeSummaryFixture());
    await pumpPage(tester, container);
    expect(
      find.descendant(of: taskCard(), matching: find.text('0')),
      findsNothing,
    );
    final notifier =
        container.read(badgeSummaryProvider.notifier)
            as FixedBadgeSummaryNotifier;

    notifier.emit(
      badgeSummaryFixture(entries: const {BadgeEntry.salesDrafts: (120, 0)}),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: taskCard(), matching: find.text('99+')),
      findsOneWidget,
    );

    notifier.emit(badgeSummaryFixture());
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: taskCard(), matching: find.text('99+')),
      findsNothing,
    );
    expect(find.text('待办 0'), findsNothing);
    expect(
      find.descendant(of: taskCard(), matching: find.text('0')),
      findsNothing,
    );
  });
}
