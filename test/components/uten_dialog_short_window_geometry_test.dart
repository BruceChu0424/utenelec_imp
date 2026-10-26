import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';

void main() {
  for (final fixture in [
    (const Size(844, 390), 150.0, 2.0),
    (const Size(390, 320), 80.0, 1.5),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        'whole dialog surface stays centered with keyboard ${fixture.$1} dark=$dark',
        (tester) async {
          final size = fixture.$1;
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.view.viewInsets = FakeViewPadding(bottom: fixture.$2);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          var saved = false;
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              scrollBehavior: const UtenScrollBehavior(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(fixture.$3)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => UtenAlertDialog(
                        alignment: Alignment.center,
                        maxWidth: 800,
                        title: const Text('版本发布配置'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < 12; i++) Text('第 ${i + 1} 项配置'),
                          ],
                        ),
                        actions: [
                          UtenButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                          UtenButton(
                            onPressed: () {
                              saved = true;
                              Navigator.pop(context);
                            },
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          final surface = find.descendant(
            of: find.byType(Dialog),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Material && widget.type == MaterialType.card,
            ),
          );
          final outerScroll = find.ancestor(
            of: surface,
            matching: find.byType(Scrollable),
          );
          expect(outerScroll, findsOneWidget);
          final canvas = Rect.fromLTWH(
            0,
            0,
            size.width,
            size.height - fixture.$2,
          );
          final visible = tester
              .getRect(surface)
              .intersect(tester.getRect(outerScroll))
              .intersect(canvas);
          expect(visible.center.dx, closeTo(canvas.center.dx, 1));
          expect(visible.center.dy, closeTo(canvas.center.dy, 1));
          final save = find.text('保存');
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          expect(save.hitTestable(), findsOneWidget);
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(saved, isTrue);
          expect(find.byType(Dialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
