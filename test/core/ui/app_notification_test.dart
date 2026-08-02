import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/ui/app_notification.dart';

void main() {
  testWidgets('top notification becomes visible and exposes a live region', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Stack(
            children: [
              Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => context.appError('排产预览已过期'),
                    child: const Text('触发错误'),
                  ),
                ),
              ),
              const Align(
                alignment: Alignment.topCenter,
                child: AppNotificationHost(),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('触发错误'));
    await tester.pump();
    expect(find.text('排产预览已过期'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 110));
    final fade = tester.widget<FadeTransition>(
      find.byWidgetPredicate(
        (widget) =>
            widget is FadeTransition &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'app-notification-fade-',
            ),
      ),
    );
    expect(fade.opacity.value, greaterThan(0));

    final hasLiveRegion = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .any((semantics) => semantics.properties.liveRegion == true);
    expect(hasLiveRegion, isTrue);
    expect(find.byTooltip('关闭通知'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭通知'));
    await tester.pumpAndSettle();
    expect(find.text('排产预览已过期'), findsNothing);
  });
}
