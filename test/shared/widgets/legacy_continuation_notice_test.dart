import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/widgets/legacy_continuation_notice.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('legacy notice fits narrow $brightness at scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final theme = brightness == Brightness.dark
            ? buildDarkTheme()
            : buildLightTheme();

        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 900),
                  textScaler: TextScaler.linear(scale),
                ),
                child: const SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: LegacyContinuationNotice(
                      description: '本单完成状态和来源关联需核对；继续办理前，请核对实际收发退及损耗记录。',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('待接续核对'), findsOneWidget);
        expect(find.textContaining('旧系统状态及累计量已保留'), findsOneWidget);
        expect(find.textContaining('单位未明确时'), findsOneWidget);
        expect(find.byType(ButtonStyleButton), findsNothing);
        final card = tester.getRect(find.byType(Card));
        for (final element in find.byType(Text).evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.left, greaterThanOrEqualTo(card.left));
          expect(rect.right, lessThanOrEqualTo(card.right));
        }
        final title = tester.widget<Text>(find.text('待接续核对'));
        expect(title.style?.color, theme.colorScheme.onSurface);
      });
    }
  }
}
