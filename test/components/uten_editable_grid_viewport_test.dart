import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';

class _Row extends EditableGridRow with AmountRowMixin {
  _Row(this.id) : text = TextEditingController(text: '明细 $id');
  final int id;
  final TextEditingController text;
  final FocusNode focus = FocusNode();
  final ValueNotifier<bool> expanded = ValueNotifier(false);
  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    expanded.dispose();
    super.dispose();
  }
}

Future<void> _mount(
  WidgetTester tester,
  UtenEditableGridController<_Row> rows,
  ScrollController scroll, {
  bool details = false,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          controller: scroll,
          children: [
            UtenEditableGrid<_Row>(
              controller: rows,
              showAddRow: false,
              showColumnSettings: false,
              selectable: true,
              rowDetailsBuilder: details
                  ? (_, row) => ValueListenableBuilder<bool>(
                      valueListenable: row.expanded,
                      builder: (_, open, _) => SizedBox(
                        height: open ? 180 : 0,
                        child: open ? Text('详情 ${row.id}') : null,
                      ),
                    )
                  : null,
              columns: [
                EditableGridColumn<_Row>(
                  key: 'note',
                  label: '备注',
                  width: 360,
                  textOf: (row) => row.text.text,
                  cellBuilder: (_, row) => TextField(
                    key: ValueKey('input-${row.id}'),
                    controller: row.text,
                    focusNode: row.focus,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<bool> _reveal(WidgetTester tester, Future<bool> result) async {
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets(
    'near-end oversized row reveals its main line within bounded frames',
    (tester) async {
      final window = UtenAncestorRowWindowController<int>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                children: [
                  UtenAncestorRowWindow<int>(
                    viewportOnly: true,
                    controller: window,
                    rows: List.generate(1000, (i) => i),
                    rowBuilder: (_, row, _) => SizedBox(
                      height: row == 998 ? 900 : 40 + (row % 3) * 9,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text('tall row $row'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var completed = false;
      final result = window.reveal(998, alignment: .35).then((value) {
        completed = true;
        return value;
      });
      for (var frame = 0; frame < 18 && !completed; frame++) {
        await tester.pump();
      }
      expect(
        completed,
        isTrue,
        reason: 'an oversized row must not wait for its bottom to fit',
      );
      expect(await result, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('tall row 998').hitTestable(), findsOneWidget);
      expect(window.mountedRowCount, lessThan(40));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bounded host budgets against its own viewport instead of screen height',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final window = UtenAncestorRowWindowController<int>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: 240,
                child: ListView(
                  children: [
                    UtenAncestorRowWindow<int>(
                      viewportOnly: true,
                      rows: List.generate(1000, (i) => i),
                      controller: window,
                      rowBuilder: (_, row, _) =>
                          SizedBox(height: 52, child: Text('bounded $row')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(window.mountedRowCount, inInclusiveRange(4, 8));
      expect(find.text('bounded 4').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new user focus cancels pending reveal instead of stealing typed text',
    (tester) async {
      final models = List.generate(1000, _Row.new);
      final rows = UtenEditableGridController<_Row>(initial: models);
      await _mount(tester, rows, ScrollController());
      final result = rows.revealCell(models.last, 'note');
      models.first.focus.requestFocus();
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(models.last.focus.hasFocus, isFalse);
      expect(models.first.focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'rapid distant scrolls at ${scale * 100}% text have no viewport holes with a bounded pixel buffer',
      (tester) async {
        final models = List.generate(1000, _Row.new);
        final rows = UtenEditableGridController<_Row>(initial: models);
        final scroll = ScrollController();
        await _mount(tester, rows, scroll, textScale: scale);
        for (final offset in [1800.0, 20000.0, 20500.0, 4000.0, 45000.0, 0.0]) {
          scroll.jumpTo(offset);
          await tester.pump();
          final pendingRects = [
            for (final element
                in find.byType(UtenRowMountPlaceholder).evaluate())
              tester.getRect(find.byWidget(element.widget)),
          ];
          final firstFrameRows = [
            for (final row in models)
              if (find.byKey(ObjectKey(row)).evaluate().isNotEmpty)
                tester.getRect(find.byKey(ObjectKey(row))),
          ];
          for (final y in [250.0, 400.0, 550.0, 700.0, 760.0]) {
            expect(
              [
                ...firstFrameRows,
                ...pendingRects,
              ].any((rect) => rect.top <= y && rect.bottom >= y),
              isTrue,
              reason:
                  'first frame must paint a real row or explicit inert loading surface',
            );
          }
          final settled = rows.settled;
          await tester.pumpAndSettle();
          await settled;
          expect(rows.isMounting, isFalse);
          expect(find.byType(UtenRowMountPlaceholder), findsNothing);
          final visibleRects = [
            for (final row in models)
              if (find.byKey(ObjectKey(row)).evaluate().isNotEmpty)
                tester.getRect(find.byKey(ObjectKey(row))),
          ];
          for (final y in [250.0, 400.0, 550.0, 700.0, 760.0]) {
            expect(
              visibleRects.any((rect) => rect.top <= y && rect.bottom >= y),
              isTrue,
              reason: 'row window leaves a hole at scroll=$offset, y=$y',
            );
          }
          expect(rows.mountedRowCount, lessThan(35));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'dialog opened during reveal cancels background focus and pending row retention',
    (tester) async {
      final models = List.generate(1000, _Row.new);
      final rows = UtenEditableGridController<_Row>(initial: models);
      await _mount(tester, rows, ScrollController());
      final result = rows.revealCell(models.last, 'note');
      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (_) => const AlertDialog(content: Text('当前弹窗')),
      );
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(models.last.focus.hasFocus, isFalse);
      expect(find.text('当前弹窗'), findsOneWidget);
      expect(rows.mountedRowCount, lessThan(80));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ancestor viewport growth without rebuilding row window exposes mounted rows',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final height = ValueNotifier<double>(240);
      final window = UtenAncestorRowWindowController<int>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ValueListenableBuilder<double>(
                valueListenable: height,
                builder: (_, value, child) =>
                    SizedBox(height: value, child: child),
                child: ListView(
                  children: [
                    UtenAncestorRowWindow<int>(
                      rows: List.generate(1000, (i) => i),
                      controller: window,
                      rowBuilder: (_, row, _) =>
                          SizedBox(height: 52, child: Text('window $row')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      height.value = 720;
      await tester.pumpAndSettle();
      expect(find.text('window 12').hitTestable(), findsOneWidget);
      expect(window.mountedRowCount, lessThan(80));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '1000 rows keep bounded widgets and all selection/data; real input survives scrolling',
    (tester) async {
      final models = List.generate(1000, _Row.new);
      final rows = UtenEditableGridController<_Row>(initial: models);
      final scroll = ScrollController();
      await _mount(tester, rows, scroll);
      expect(rows.mountedRowCount, inInclusiveRange(10, 80));
      expect(find.byType(TextField).evaluate().length, lessThan(80));
      await tester.enterText(find.byKey(const ValueKey('input-0')), '输入保留');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '输入保留',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      scroll.jumpTo(20000);
      await tester.pumpAndSettle();
      expect(models.first.focus.hasFocus, isTrue);
      expect(find.byKey(const ValueKey('input-0')), findsOneWidget);
      expect(models.first.text.text, '输入保留');
      expect(
        models.first.text.value.composing,
        const TextRange(start: 0, end: 4),
      );
      expect(rows.mountedRowCount, lessThan(80));
      for (var i = 0; i < 3 && !models[1].focus.hasFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(
        models[1].focus.hasFocus,
        isTrue,
        reason: 'Tab from a retained offscreen input must reach its next model',
      );
      rows.selectAll();
      await tester.pump();
      expect(rows.selectedRows.length, 1000);
      expect(rows.mountedRowCount, lessThan(80));
      expect(
        await _reveal(tester, rows.revealCell(models.last, 'note')),
        isTrue,
      );
      expect(models.last.focus.hasFocus, isTrue);
      expect(
        find.byKey(const ValueKey('input-999')).hitTestable(),
        findsOneWidget,
      );
      expect(rows.length, 1000);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offscreen reveal clears view query without losing rows and resolves after idle frames',
    (tester) async {
      final models = List.generate(1000, _Row.new);
      final rows = UtenEditableGridController<_Row>(initial: models);
      await _mount(tester, rows, ScrollController());
      final header = find
          .byWidgetPredicate(
            (w) => w is GridHeaderFilterCell && w.label == '备注',
          )
          .hitTestable();
      await tester.tap(header);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '明细 999',
      );
      await tester.tap(find.byKey(const Key('uten-column-keyword-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('input-999')), findsOneWidget);
      expect(rows.length, 1000);
      expect(
        await _reveal(tester, rows.revealCell(models[500], 'note')),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('input-500')).hitTestable(),
        findsOneWidget,
      );
      expect(models[500].focus.hasFocus, isTrue);
      expect(rows.mountedRowCount, lessThan(80));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'variable details and insertion above viewport preserve row anchor and model state',
    (tester) async {
      final models = List.generate(1000, _Row.new);
      final rows = UtenEditableGridController<_Row>(initial: models);
      final scroll = ScrollController();
      await _mount(tester, rows, scroll, details: true);
      expect(
        await _reveal(tester, rows.revealRow(models[500], alignment: 0)),
        isTrue,
      );
      final target = find.byKey(const ValueKey('input-500'));
      final before = tester.getTopLeft(target).dy;
      rows.insertAt(0, _Row(-1));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(target).dy, closeTo(before, 2));
      // An overscan row fully above the viewport must preserve the visible
      // anchor. Expanding a visible row should naturally move rows below it.
      expect(
        tester.getBottomLeft(find.byKey(ObjectKey(models[499]))).dy,
        lessThanOrEqualTo(.5),
      );
      models[499].expanded.value = true;
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(target).dy, closeTo(before, 2));
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(await _reveal(tester, rows.revealRow(models[499])), isTrue);
      expect(find.text('详情 499'), findsOneWidget);
      expect(rows.mountedRowCount, lessThan(80));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focused row neighbours allow Tab beyond initial window; deleting focused row is safe',
    (tester) async {
      final models = List.generate(1000, _Row.new);
      final rows = UtenEditableGridController<_Row>(initial: models);
      await _mount(tester, rows, ScrollController());
      expect(
        await _reveal(tester, rows.revealCell(models[500], 'note')),
        isTrue,
      );
      // Selection checkboxes precede each input; traversal must still reach the
      // next model rather than skipping to the footer at the window boundary.
      for (var i = 0; i < 3 && !models[501].focus.hasFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(models[501].focus.hasFocus, isTrue);
      rows.removeAt(501);
      await tester.pumpAndSettle();
      expect(rows.length, 999);
      expect(tester.takeException(), isNull);
    },
  );
}
