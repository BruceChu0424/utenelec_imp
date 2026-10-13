import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_module_badges.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';

Widget _app(FixedBadgeSummaryNotifier notifier, {bool dark = false}) =>
    ProviderScope(
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
                  onPressed: () {},
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
      await tester.pumpWidget(_app(notifier, dark: dark));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('进行中 99+'), findsOneWidget);
      expect(find.text('待办 99+'), findsOneWidget);
      final title = tester.getRect(find.text('模块中心'));
      final back = tester.getRect(find.byKey(const Key('back')));
      final action = tester.getRect(find.byKey(const Key('draft-action')));
      expect(title.left, greaterThanOrEqualTo(back.right));
      expect(title.right, lessThanOrEqualTo(action.left));
      final progress = tester.getRect(find.text('进行中 99+'));
      final todo = tester.getRect(find.text('待办 99+'));
      expect(progress.top, greaterThanOrEqualTo(56));
      expect(todo.top, greaterThan(progress.bottom));
      expect(todo.right, lessThanOrEqualTo(375));
      final appBar = tester.widget<UtenAppBar>(find.byType(UtenAppBar));
      expect(appBar.bottom!.preferredSize.height, greaterThan(72));

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
