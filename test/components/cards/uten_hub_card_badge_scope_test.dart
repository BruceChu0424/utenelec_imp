import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_module_badges.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_scoped_badges.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/badges/badge_scope.dart';

import '../../helpers/badge_summary_fixture.dart';

Widget _app(FixedBadgeSummaryNotifier notifier, Widget child) => ProviderScope(
  overrides: [badgeSummaryProvider.overrideWith(() => notifier)],
  child: MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  ),
);

Widget _card({
  required BadgeScope scope,
  String label = '任务中心',
  bool enabled = true,
  Widget? badge,
  Widget? progressBadge,
}) => SizedBox(
  width: 320,
  height: 150,
  child: UtenHubCard(
    key: ValueKey(label),
    icon: Icons.assignment_outlined,
    label: label,
    onTap: () {},
    enabled: enabled,
    badgeScope: scope,
    badgeShowLabel: true,
    badge: badge,
    progressBadge: progressBadge,
  ),
);

Finder _inside(String cardLabel, Type type) => find.descendant(
  of: find.byKey(ValueKey(cardLabel)),
  matching: find.byType(type),
);

void main() {
  testWidgets(
    'module includes its child queues; entry excludes sibling queues',
    (tester) async {
      final notifier = FixedBadgeSummaryNotifier(
        badgeSummaryFixture(
          entries: {
            BadgeEntry.salesAttention: (3, 0),
            BadgeEntry.salesOrderInFlight: (0, 7),
            BadgeEntry.salesDrafts: (5, 0),
            BadgeEntry.purchaseTaskCenter: (11, 13),
          },
        ),
      );
      await tester.pumpWidget(
        _app(
          notifier,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _card(
                label: '销售任务中心',
                scope: const BadgeScope.module(BadgeModule.sales),
              ),
              _card(
                label: '订货进度',
                scope: const BadgeScope.entry(BadgeEntry.salesAttention),
              ),
            ],
          ),
        ),
      );

      expect(
        tester
            .widget<UtenNotificationBadge>(
              _inside('销售任务中心', UtenNotificationBadge),
            )
            .count,
        8,
      );
      expect(
        tester
            .widget<UtenInProgressBadge>(_inside('销售任务中心', UtenInProgressBadge))
            .count,
        7,
      );
      expect(
        tester
            .widget<UtenNotificationBadge>(
              _inside('订货进度', UtenNotificationBadge),
            )
            .count,
        3,
      );
      expect(_inside('订货进度', UtenInProgressBadge), findsNothing);
      expect(find.text('11'), findsNothing);
      expect(find.text('13'), findsNothing);
    },
  );

  testWidgets('split scope picks the requested color from each entry', (
    tester,
  ) async {
    final notifier = FixedBadgeSummaryNotifier(
      badgeSummaryFixture(
        entries: {
          BadgeEntry.productionSchedule: (4, 81),
          BadgeEntry.productionBatches: (82, 6),
          BadgeEntry.productionDrafts: (83, 84),
        },
      ),
    );
    await tester.pumpWidget(
      _app(
        notifier,
        _card(
          scope: const BadgeScope.entries(
            todo: BadgeEntry.productionSchedule,
            inProgress: BadgeEntry.productionBatches,
          ),
        ),
      ),
    );

    expect(find.text('4'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(
      tester
          .widget<UtenNotificationBadge>(find.byType(UtenNotificationBadge))
          .count,
      4,
    );
    expect(
      tester
          .widget<UtenInProgressBadge>(find.byType(UtenInProgressBadge))
          .count,
      6,
    );
    final yellow = tester.getRect(find.byType(UtenInProgressBadge));
    final red = tester.getRect(find.byType(UtenNotificationBadge));
    expect(yellow.right, lessThan(red.left));
    expect(red.height, closeTo(16 * 1.4, 0.01));
    expect(
      tester
          .widget<UtenNotificationBadge>(find.byType(UtenNotificationBadge))
          .showLabel,
      isTrue,
    );
  });

  testWidgets('summary updates cap counts and remove hidden badge spacing', (
    tester,
  ) async {
    BadgeSummary summary(int todo, int progress) => badgeSummaryFixture(
      entries: {BadgeEntry.purchaseTaskCenter: (todo, progress)},
    );
    final notifier = FixedBadgeSummaryNotifier(summary(2, 3));
    await tester.pumpWidget(
      _app(
        notifier,
        _card(scope: const BadgeScope.entry(BadgeEntry.purchaseTaskCenter)),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    notifier.emit(summary(100, 120));
    await tester.pump();
    expect(find.text('99+'), findsNWidgets(2));
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsNothing);

    notifier.emit(summary(0, 5));
    await tester.pump();
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(
      tester.getSize(find.byType(UtenScopedBadges)),
      tester.getSize(find.byType(UtenInProgressBadge)),
    );

    notifier.emit(summary(7, 0));
    await tester.pump();
    expect(find.byType(UtenInProgressBadge), findsNothing);
    expect(
      tester.getSize(find.byType(UtenScopedBadges)),
      tester.getSize(find.byType(UtenNotificationBadge)),
    );

    notifier.emit(summary(0, 0));
    await tester.pump();
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(find.byType(UtenInProgressBadge), findsNothing);
    expect(tester.getSize(find.byType(UtenScopedBadges)), Size.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled cards hide scoped counts and custom overrides', (
    tester,
  ) async {
    final notifier = FixedBadgeSummaryNotifier(
      badgeSummaryFixture(entries: {BadgeEntry.purchaseTaskCenter: (3, 5)}),
    );
    await tester.pumpWidget(
      _app(
        notifier,
        _card(
          scope: const BadgeScope.entry(BadgeEntry.purchaseTaskCenter),
          enabled: false,
          badge: const Text('专用待办'),
          progressBadge: const Text('专用进行中'),
        ),
      ),
    );
    expect(find.text('未启用'), findsOneWidget);
    expect(find.text('专用待办'), findsNothing);
    expect(find.text('专用进行中'), findsNothing);
    expect(find.byType(UtenScopedBadges), findsNothing);
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(find.byType(UtenInProgressBadge), findsNothing);
  });

  testWidgets('zero-count custom badge leaves no gap beside the live color', (
    tester,
  ) async {
    final notifier = FixedBadgeSummaryNotifier(
      badgeSummaryFixture(entries: {BadgeEntry.purchaseTaskCenter: (0, 5)}),
    );
    await tester.pumpWidget(
      _app(
        notifier,
        _card(
          scope: const BadgeScope.entry(BadgeEntry.purchaseTaskCenter),
          badge: const UtenNotificationBadge(count: 0),
        ),
      ),
    );
    expect(tester.getSize(find.byType(UtenNotificationBadge)), Size.zero);
    expect(
      tester.getRect(find.byType(UtenScopedBadges)),
      tester.getRect(find.byType(UtenInProgressBadge)),
    );
    expect(find.text('5'), findsOneWidget);
  });

  for (final overrideTodo in [true, false]) {
    testWidgets(
      'custom ${overrideTodo ? 'todo' : 'progress'} keeps other color live',
      (tester) async {
        final notifier = FixedBadgeSummaryNotifier(
          badgeSummaryFixture(entries: {BadgeEntry.purchaseTaskCenter: (3, 5)}),
        );
        const custom = Tooltip(message: '保留异常说明', child: Text('专用'));
        await tester.pumpWidget(
          _app(
            notifier,
            _card(
              scope: const BadgeScope.entry(BadgeEntry.purchaseTaskCenter),
              badge: overrideTodo ? custom : null,
              progressBadge: overrideTodo ? null : custom,
            ),
          ),
        );
        expect(find.text('专用'), findsOneWidget);
        expect(find.byTooltip('保留异常说明'), findsOneWidget);
        expect(find.text(overrideTodo ? '3' : '5'), findsNothing);
        expect(find.text(overrideTodo ? '5' : '3'), findsOneWidget);

        notifier.emit(
          badgeSummaryFixture(entries: {BadgeEntry.purchaseTaskCenter: (7, 9)}),
        );
        await tester.pump();
        expect(find.text('专用'), findsOneWidget);
        expect(find.text(overrideTodo ? '9' : '7'), findsOneWidget);
        expect(find.text(overrideTodo ? '7' : '9'), findsNothing);
      },
    );
  }

  testWidgets('module heading uses the same scope and disappears on zero', (
    tester,
  ) async {
    final notifier = FixedBadgeSummaryNotifier(
      badgeSummaryFixture(
        entries: {
          BadgeEntry.salesAttention: (2, 0),
          BadgeEntry.salesOrderInFlight: (0, 7),
          BadgeEntry.salesDrafts: (3, 0),
          BadgeEntry.purchaseTaskCenter: (11, 13),
        },
      ),
    );
    await tester.pumpWidget(
      _app(notifier, const UtenModuleBadges(module: BadgeModule.sales)),
    );
    expect(find.text('待办 5'), findsOneWidget);
    expect(find.text('进行中 7'), findsOneWidget);
    expect(
      tester.getRect(find.text('进行中 7')).right,
      lessThan(tester.getRect(find.text('待办 5')).left),
    );

    notifier.emit(
      badgeSummaryFixture(entries: {BadgeEntry.salesAttention: (120, 0)}),
    );
    await tester.pump();
    expect(find.text('待办 99+'), findsOneWidget);
    expect(find.text('进行中 7'), findsNothing);

    notifier.emit(badgeSummaryFixture());
    await tester.pump();
    expect(tester.getSize(find.byType(UtenModuleBadges)), Size.zero);
    expect(tester.takeException(), isNull);
  });
}
