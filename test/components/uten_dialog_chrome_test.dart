import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  for (final width in [560.0, 160.0]) {
    for (final textScale in [1.0, 2.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          'painted action surfaces stay equal with wrapped icon label width=$width scale=$textScale dark=$dark',
          (tester) async {
            var submitted = false;
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      child: UtenDialogActions(
                        children: [
                          TextButton(
                            key: const Key('cancel-surface'),
                            onPressed: () {},
                            child: const Text('取消'),
                          ),
                          UtenButton(
                            key: const Key('primary-surface'),
                            icon: Icons.download_rounded,
                            onPressed: () => submitted = true,
                            child: const Text('下载文件\n保留设置'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            Rect surface(String key) => tester.getRect(
              find
                  .descendant(
                    of: find.byKey(Key(key)),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            final cancel = surface('cancel-surface');
            final primary = surface('primary-surface');
            expect(cancel.height, closeTo(primary.height, 0.01));
            if (width == 560) expect(cancel.top, closeTo(primary.top, 0.01));
            expect(tester.takeException(), isNull);
            await tester.tap(find.byKey(const Key('primary-surface')));
            expect(submitted, isTrue);
          },
        );
      }
    }
  }
  for (final dark in [false, true]) {
    testWidgets('top gradient fades into the surface dark=$dark', (
      tester,
    ) async {
      final theme = dark ? buildDarkTheme() : buildLightTheme();
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: const UtenDialogSurface(
                child: SizedBox(width: 200, height: 400),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      await tester.runAsync(() async {
        final picture = await boundary.toImage();
        final data = (await picture.toByteData())!;
        Color pixel(int y) {
          final offset = (y * picture.width + 100) * 4;
          return Color.fromARGB(
            data.getUint8(offset + 3),
            data.getUint8(offset),
            data.getUint8(offset + 1),
            data.getUint8(offset + 2),
          );
        }

        final base =
            theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface;
        expect(pixel(2), isNot(base));
        expect(pixel(2), isNot(pixel(100)));
        expect(pixel(250), base);
        expect(pixel(399), base);
        picture.dispose();
      });
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'native and Uten footer controls share height and centered group dark=$dark',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => UtenAlertDialog(
                      title: const Text('统一操作'),
                      content: const Text('核对后继续'),
                      actions: [
                        TextButton(
                          key: const Key('cancel'),
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        UtenButton(
                          key: const Key('confirm'),
                          onPressed: () => Navigator.pop(context),
                          child: const Text('继续'),
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
        final cancel = tester.getRect(find.byKey(const Key('cancel')));
        final confirm = tester.getRect(find.byKey(const Key('confirm')));
        final footer = tester.getRect(find.byType(UtenDialogActions));
        expect(cancel.height, confirm.height);
        expect(
          (cancel.left + confirm.right) / 2,
          closeTo(footer.center.dx, 0.5),
        );
        expect(find.byType(UtenDialogSurface), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(UtenAlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('busy header keeps close visible and disabled', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UtenDialogHeader(
            title: Text('正在保存'),
            icon: Icons.save_outlined,
            showCloseButton: true,
          ),
        ),
      ),
    );
    final close = tester.widget<IconButton>(find.byType(IconButton));
    expect(close.onPressed, isNull);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('a narrow embedded header retains a reachable close control', (
    tester,
  ) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              child: UtenDialogHeader(
                title: const Text('选择分类'),
                icon: Icons.category_outlined,
                showCloseButton: true,
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.close_rounded).hitTestable(), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(closed, isTrue);
  });

  testWidgets(
    'a bottom-sheet body can reuse the surface inside a dialog without double painting',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: UtenDialogSurface(
              child: UtenDialogSurface(
                child: SizedBox(width: 300, height: 300),
              ),
            ),
          ),
        ),
      );
      final decorators = find.descendant(
        of: find.byType(UtenDialogSurface).first,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient != null,
        ),
      );
      expect(decorators, findsOneWidget);
    },
  );
}
