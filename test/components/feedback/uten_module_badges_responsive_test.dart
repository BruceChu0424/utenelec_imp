import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_module_badges.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';

Widget _app(
  FixedBadgeSummaryNotifier notifier, {
  bool dark = false,
  required VoidCallback onDraftAction,
}) => ProviderScope(
  overrides: [badgeSummaryProvider.overrideWith(() => notifier)],
  child: MaterialApp(
    theme: dark ? buildDarkTheme() : buildLightTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: Consumer(
      builder: (context, ref, child) => Scaffold(
        appBar: UtenAppBar(
          title: '模块中心',
          leading: IconButton(
            key: const Key('back'),
            onPressed: () {},
            icon: const Icon(Icons.arrow_back),
          ),
          actions: [
            IconButton(
              key: const Key('draft-action'),
              tooltip: '查看草稿',
              onPressed: onDraftAction,
              icon: const Icon(Icons.drafts_outlined),
            ),
          ],
          bottom: UtenModuleBadges.compactAppBarBottom(
            context,
            ref,
            BadgeModule.sales,
          ),
          showPagePermissionAction: false,
        ),
        body: const SizedBox.expand(),
      ),
    ),
  ),
);

void main() {
  for (final dark in [false, true]) {
    testWidgets('compact counts wrap below a usable toolbar dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notifier = FixedBadgeSummaryNotifier(
        badgeSummaryFixture(
          entries: const {
            BadgeEntry.salesAttention: (120, 0),
            BadgeEntry.salesOrderInFlight: (0, 140),
          },
        ),
      );
      var draftCalls = 0;
      await tester.pumpWidget(
        _app(notifier, dark: dark, onDraftAction: () => draftCalls++),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('进行中 99+'), findsOneWidget);
      expect(find.text('待办 99+'), findsOneWidget);
      final title = tester.getRect(find.text('模块中心'));
      final back = tester.getRect(find.byKey(const Key('back')));
      final more = find.byKey(const Key('uten-app-bar-more-actions'));
      final action = tester.getRect(more);
      expect(title.left, greaterThanOrEqualTo(back.right));
      expect(title.right, lessThanOrEqualTo(action.left));
      expect(find.byKey(const Key('draft-action')), findsNothing);
      final progress = tester.getRect(find.text('进行中 99+'));
      final todo = tester.getRect(find.text('待办 99+'));
      expect(progress.top, greaterThanOrEqualTo(56));
      expect(todo.top, greaterThan(progress.bottom));
      expect(todo.right, lessThanOrEqualTo(375));
      final appBar = tester.widget<UtenAppBar>(find.byType(UtenAppBar));
      expect(appBar.bottom!.preferredSize.height, greaterThan(72));

      // 窄屏操作移到“更多”面板，实际打开后仍可按窗口坐标点击原动作。
      await tester.tap(more);
      await tester.pumpAndSettle();
      final draft = find.byKey(const Key('draft-action'));
      expect(find.byTooltip('查看草稿'), findsOneWidget);
      final draftRect = tester.getRect(draft);
      expect(draftRect.left, greaterThanOrEqualTo(0));
      expect(draftRect.right, lessThanOrEqualTo(375));
      expect(draftRect.top, greaterThanOrEqualTo(0));
      expect(draftRect.bottom, lessThanOrEqualTo(812));
      await tester.tapAt(draftRect.center);
      await tester.pumpAndSettle();
      expect(draftCalls, 1);
      expect(draft, findsNothing);
      expect(more, findsOneWidget);
      expect(find.text('进行中 99+'), findsOneWidget);
      expect(find.text('待办 99+'), findsOneWidget);
      expect(tester.getRect(find.text('进行中 99+')), progress);
      expect(tester.getRect(find.text('待办 99+')), todo);

      notifier.emit(badgeSummaryFixture());
      await tester.pumpAndSettle();
      expect(tester.widget<UtenAppBar>(find.byType(UtenAppBar)).bottom, isNull);
      expect(
        tester.widget<UtenAppBar>(find.byType(UtenAppBar)).preferredSize.height,
        56,
      );
      expect(find.text('进行中 99+'), findsNothing);
      expect(find.text('待办 99+'), findsNothing);
      expect(tester.takeException(), isNull);

      notifier.emit(BadgeSummary.empty);
      await tester.pump();
      expect(tester.widget<UtenAppBar>(find.byType(UtenAppBar)).bottom, isNull);
      expect(find.byType(UtenModuleBadges), findsNothing);
    });
  }
}
