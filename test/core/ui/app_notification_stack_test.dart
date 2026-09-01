import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/ui/uten_top_banner_card.dart';

void main() {
  testWidgets(
    'compact dark stack is accessible, reduced-motion, and expandable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final semantics = tester.ensureSemantics();
      try {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: ThemeData.dark(useMaterial3: true),
              home: const MediaQuery(
                data: MediaQueryData(
                  size: Size(320, 568),
                  textScaler: TextScaler.linear(3),
                  disableAnimations: true,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AppNotificationHost(),
                ),
              ),
            ),
          ),
        );

        final notifications = container.read(appNotificationProvider.notifier);
        for (var index = 1; index <= 3; index++) {
          notifications.showMessage(
            '通知 $index',
            duration: const Duration(hours: 1),
            force: true,
          );
        }
        await tester.pump();

        expect(find.byType(UtenTopBannerCard), findsOneWidget);
        expect(find.text('通知 3'), findsOneWidget);
        expect(find.text('通知 2'), findsNothing);

        final toggle = find.byKey(
          const ValueKey('app-notification-stack-toggle'),
        );
        expect(toggle, findsOneWidget);
        final toggleSize = tester.getSize(toggle);
        expect(toggleSize.width, greaterThanOrEqualTo(48));
        expect(toggleSize.height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(toggle).label, '展开 3 条通知');

        await tester.tap(toggle);
        await tester.pump();

        expect(find.byType(UtenTopBannerCard), findsNWidgets(3));
        expect(find.text('通知 3'), findsOneWidget);
        expect(find.text('通知 2'), findsOneWidget);
        expect(find.text('通知 1'), findsOneWidget);
        expect(tester.takeException(), isNull);

        final liveRegions = tester
            .widgetList<Semantics>(find.byType(Semantics))
            .where((widget) => widget.properties.liveRegion == true);
        expect(liveRegions, hasLength(1));

        final closeButtons = find.byTooltip('关闭通知');
        expect(closeButtons, findsNWidgets(3));
        for (var index = 0; index < 3; index++) {
          final size = tester.getSize(closeButtons.at(index));
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
      } finally {
        semantics.dispose();
      }
    },
  );
}
