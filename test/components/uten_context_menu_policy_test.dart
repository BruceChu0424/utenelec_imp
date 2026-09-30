import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

Widget _app(Widget child) => MaterialApp(
  builder: (context, routedChild) => UtenContextMenuPolicy(child: routedChild!),
  home: Scaffold(body: child),
);

Future<void> _rightClick(WidgetTester tester, Offset position) async {
  final mouse = await tester.startGesture(
    position,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  // SelectionArea normally shows the toolbar at its tap-down deadline, even
  // before the button is released. Verify both phases of a real right click.
  await tester.pump(const Duration(milliseconds: 250));
  expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
  await mouse.up();
  await tester.pumpAndSettle();
  expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      'right-click text and blank area shows no toolbar on $platform',
      (tester) async {
        await tester.pumpWidget(
          _app(
            const SelectionArea(
              child: SizedBox.expand(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text('Selectable body text'),
                ),
              ),
            ),
          ),
        );

        await _rightClick(
          tester,
          tester.getCenter(find.text('Selectable body text')),
        );
        await _rightClick(tester, const Offset(500, 300));
        expect(find.text('Select all'), findsNothing);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'right-click TextField shows only its Uten menu on $platform',
      (tester) async {
        final controller = TextEditingController(text: 'Editable body text');
        addTearDown(controller.dispose);
        var calls = 0;
        await tester.pumpWidget(
          _app(
            UtenContextMenuRegion(
              entriesBuilder: () => [
                UtenMenuItem(label: '业务复制', onTap: () => calls++),
              ],
              child: TextField(controller: controller),
            ),
          ),
        );

        await _rightClick(tester, tester.getCenter(find.byType(TextField)));
        expect(find.text('业务复制'), findsOneWidget);
        await tester.tap(find.text('业务复制'));
        await tester.pumpAndSettle();
        expect(calls, 1);

        await _rightClick(tester, tester.getCenter(find.byType(TextField)));
        expect(find.text('业务复制'), findsOneWidget);
        await _rightClick(tester, const Offset(500, 500));
        expect(find.text('业务复制'), findsNothing);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'plain TextField right click is silent; keyboard select/copy works',
    (tester) async {
      final controller = TextEditingController(
        text: 'Keyboard copy stays usable',
      );
      addTearDown(controller.dispose);
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(_app(TextField(controller: controller)));
      await _rightClick(tester, tester.getCenter(find.byType(TextField)));
      await tester.tap(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(clipboardText, controller.text);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets('nested row/header menus win over the table background menu', (
    tester,
  ) async {
    var backgroundBuilds = 0;
    await tester.pumpWidget(
      _app(
        UtenContextMenuRegion(
          behavior: HitTestBehavior.opaque,
          entriesBuilder: () {
            backgroundBuilds++;
            return [UtenMenuItem(label: '背景粘贴', onTap: () {})];
          },
          child: Column(
            children: [
              UtenColumnHeaderMenuRegion(
                entriesBuilder: () => [
                  UtenMenuItem(label: '表头固定', onTap: () {}),
                ],
                child: const SizedBox(
                  height: 60,
                  child: Center(child: Text('表头区域')),
                ),
              ),
              Transform.translate(
                offset: const Offset(15, 5),
                child: UtenContextMenuRegion(
                  entriesBuilder: () => [
                    UtenMenuItem(label: '行复制', onTap: () {}),
                  ],
                  child: const SizedBox(
                    height: 60,
                    child: Center(child: Text('行区域')),
                  ),
                ),
              ),
              const Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      ),
    );
    await _rightClick(tester, tester.getCenter(find.text('行区域')));
    expect(find.text('行复制'), findsOneWidget);
    expect(find.text('背景粘贴'), findsNothing);
    expect(backgroundBuilds, 0);
    await tester.tap(find.text('行复制'));
    await tester.pumpAndSettle();

    await _rightClick(tester, tester.getCenter(find.text('表头区域')));
    expect(find.text('表头固定'), findsOneWidget);
    expect(find.text('背景粘贴'), findsNothing);
    expect(backgroundBuilds, 0);
    await tester.tap(find.text('表头固定'));
    await tester.pumpAndSettle();

    await _rightClick(tester, const Offset(500, 400));
    expect(find.text('背景粘贴'), findsOneWidget);
    expect(backgroundBuilds, 1);
  });

  testWidgets(
    'primary mouse drag still selects read-only text',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        _app(
          SelectionArea(
            onSelectionChanged: (content) => selected = content?.plainText,
            child: const Align(
              alignment: Alignment.topLeft,
              child: Text('Read-only text can still be selected'),
            ),
          ),
        ),
      );
      final start = tester.getTopLeft(
        find.text('Read-only text can still be selected'),
      );
      final mouse = await tester.startGesture(
        start + const Offset(2, 8),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(180, 0));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(selected, isNotEmpty);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'policy covers dialog overlay text as well as routed pages',
    (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(
                  content: SelectionArea(child: Text('Dialog selection text')),
                ),
              ),
              child: const Text('Open dialog'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      await _rightClick(
        tester,
        tester.getCenter(find.text('Dialog selection text')),
      );
      expect(find.byType(AlertDialog), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'touch long-press still offers text selection actions',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const SelectionArea(child: Center(child: Text('Touch selection'))),
        ),
      );
      await tester.longPress(find.text('Touch selection'));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
