import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

Future<void> _select(WidgetTester tester, String first, {String? last}) async {
  Offset edge(String text, bool end) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text(text).last,
        matching: find.byType(RichText),
      ),
    );
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    final box = end ? boxes.last : boxes.first;
    return paragraph.localToGlobal(
      Offset(end ? box.right + 1 : box.left + 0.1, (box.top + box.bottom) / 2),
    );
  }

  final start = edge(first, false);
  final finish = edge(last ?? first, true);
  final mouse = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
  for (var step = 1; step <= 8; step++) {
    await mouse.moveTo(Offset.lerp(start, finish, step / 8)!);
    await tester.pump(const Duration(milliseconds: 20));
  }
  await mouse.up();
  await tester.pumpAndSettle();
}

Future<void> _copy(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'frozen column contributes each value once after horizontal scroll',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 440,
              height: 300,
              child: MasterDataTableView<String>(
                requiredLeadingColumnKeys: const ['code'],
                columns: [
                  MasterColumnDef(
                    key: 'code',
                    label: 'Code',
                    width: 180,
                    value: (row) => row,
                  ),
                  MasterColumnDef(
                    key: 'notes',
                    label: 'Notes',
                    width: 480,
                    value: (row) =>
                        'A very long description for $row with notes',
                  ),
                ],
                items: const ['ALPHA-001', 'BETA-002'],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                idOf: (row) => row,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Touch scroll keeps the mouse drag available for text selection.
      await tester.drag(
        find.textContaining('A very long description').first,
        const Offset(-170, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('ALPHA-001'), findsNWidgets(2));
      await _select(tester, 'ALPHA-001');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _copy(tester);
      expect(
        'ALPHA-001'.allMatches(clipboard!).length,
        2,
        reason:
            'one code cell plus one occurrence in its note, no frozen duplicate',
      );
      expect('BETA-002'.allMatches(clipboard!).length, 2);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'column removal invalidates selected text and an open copy menu',
    (tester) async {
      final showName = ValueNotifier(true);
      addTearDown(showName.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => UtenContextMenuPolicy(child: child!),
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: showName,
              builder: (_, visible, _) => MasterDataTableView<String>(
                columns: [
                  MasterColumnDef(
                    key: 'code',
                    label: 'Code',
                    width: 180,
                    value: (row) => row,
                  ),
                  if (visible)
                    MasterColumnDef(
                      key: 'name',
                      label: 'Name',
                      width: 180,
                      value: (_) => 'PRIVATE-NAME',
                    ),
                ],
                items: const ['ROW-001'],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                rowMenuBuilder: (_) => [
                  UtenMenuItem(label: '业务操作', onTap: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _select(tester, 'PRIVATE-NAME');
      final mouse = await tester.startGesture(
        tester.getCenter(find.text('PRIVATE-NAME')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('复制所选文字'), findsOneWidget);
      showName.value = false;
      await tester.pumpAndSettle();
      expect(find.text('PRIVATE-NAME'), findsNothing);
      clipboard = null;
      await tester.tap(find.text('复制所选文字'));
      await tester.pumpAndSettle();
      expect(
        clipboard,
        isNull,
        reason: 'open menus cannot copy removed column text',
      );
      final remainingRow = await tester.startGesture(
        tester.getCenter(find.text('ROW-001')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await remainingRow.up();
      await tester.pumpAndSettle();
      expect(find.text('复制所选文字'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'checkbox table drag/copy dark=$dark scale=$scale',
        (tester) async {
          var checked = <String>{};
          var opens = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              builder: (context, child) => UtenContextMenuPolicy(
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
              ),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, update) => MasterDataTableView<String>(
                    columns: [
                      MasterColumnDef(
                        key: 'code',
                        label: 'Code',
                        width: 240,
                        value: (row) => row,
                      ),
                      MasterColumnDef(
                        key: 'name',
                        label: 'Name',
                        width: 260,
                        value: (row) => 'SWITCH-$row',
                      ),
                    ],
                    items: const ['ALPHA-001', 'BETA-002'],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: true,
                    idOf: (row) => row,
                    selectedIds: checked,
                    onSelectedIdsChanged: (next) =>
                        update(() => checked = next),
                    onRowTap: (_) => opens++,
                    rowMenuBuilder: (_) => [
                      UtenMenuItem(label: '复制货品', onTap: () {}),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _select(tester, 'ALPHA-001');
          await _copy(tester);
          expect(clipboard, 'ALPHA-001');
          expect(checked, isEmpty, reason: '拖选不应勾选业务行');
          expect(opens, 0);

          // Right click keeps the existing business menu and exposes text copy.
          final mouse = await tester.startGesture(
            tester.getCenter(find.text('ALPHA-001')),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryButton,
          );
          await mouse.up();
          await tester.pumpAndSettle();
          expect(find.text('复制货品'), findsOneWidget);
          expect(find.text('复制所选文字'), findsOneWidget);
          clipboard = null;
          final selectionBeforeCopy = Set<String>.of(checked);
          await tester.tap(find.text('复制所选文字'));
          await tester.pumpAndSettle();
          expect((await Clipboard.getData('text/plain'))?.text, 'ALPHA-001');
          expect(checked, selectionBeforeCopy);

          // A new selection can span cells and rows without changing checkbox state.
          await _select(tester, 'ALPHA-001', last: 'SWITCH-BETA-002');
          await _copy(tester);
          expect(clipboard, contains('ALPHA-001'));
          expect(clipboard, contains('SWITCH-ALPHA-001'));
          expect(clipboard, contains('BETA-002'));
          expect(clipboard, isNot(contains('Code')));
          expect(checked, selectionBeforeCopy);
          expect(opens, 0);
          expect(tester.takeException(), isNull);
        },
        variant: const TargetPlatformVariant({TargetPlatform.windows}),
      );
    }
  }
}
