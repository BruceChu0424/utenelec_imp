import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/print/print_pdf_document.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import '../../support/print_test_font.dart';

UtenPrintTable _table(int count) => UtenPrintTable(
  headers: const ['货品', '金额'],
  columnKeys: const ['name', 'amount'],
  rows: [
    for (var i = 0; i < count; i++) ['row-$i', '$i.12345678'],
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late pw.Font font;
  setUpAll(() async => font = await loadPrintTestFont());
  test(
    'large projections yield to timer work and preserve exact ordered cells',
    () async {
      final source = _table(2000);
      var turns = 0;
      final timer = Timer.periodic(Duration.zero, (_) => turns++);
      final projected = await projectUtenPrintTable(
        source,
        const TableColumnProjection(
          tableKey: 'test-print',
          columns: [
            TableProjectedColumn(
              key: 'amount',
              label: '精确金额',
              width: 80,
              type: 'money',
            ),
            TableProjectedColumn(
              key: 'name',
              label: '名称',
              width: 260,
              type: 'text',
            ),
          ],
        ),
        budget: UiWorkBudget(maxItems: 64),
      );
      timer.cancel();
      expect(turns, greaterThan(1));
      expect(projected.rows, [
        for (final row in source.rows) [row[1], row[0]],
      ]);
      expect(projected.headers, ['精确金额', '名称']);
      expect(projected.columnWidths, [80, 260]);
    },
  );

  test(
    'revoking an in-progress projection returns no partially projected table',
    () async {
      var current = true;
      Timer.run(() => current = false);
      await expectLater(
        projectUtenPrintTable(
          _table(2000),
          const TableColumnProjection(
            tableKey: 'test-print',
            columns: [
              TableProjectedColumn(
                key: 'amount',
                label: '金额',
                width: 80,
                type: 'money',
              ),
            ],
          ),
          budget: UiWorkBudget(maxItems: 16, isCurrent: () => current),
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
    },
  );

  test(
    'PDF cell construction yields while retaining fonts, padding and raw decimals',
    () async {
      final table = _table(1000);
      var yielded = false;
      Timer.run(() => yielded = true);
      final rows = await buildPrintPdfRows(
        PrintPdfRequest(
          title: 'test',
          headers: table.headers,
          rows: table.rows,
        ),
        font,
        budget: UiWorkBudget(maxItems: 32),
      );
      expect(yielded, isTrue);
      expect(rows, hasLength(1001));
      String value(pw.Widget widget) =>
          ((widget as pw.Padding).child! as pw.Text).text.toPlainText();
      expect(rows.first.children.map(value), table.headers);
      for (var index = 0; index < table.rows.length; index++) {
        expect(rows[index + 1].children.map(value), table.rows[index]);
      }
      final amount = rows.last.children.last as pw.Padding;
      expect(
        amount.padding,
        const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      );
      final text = amount.child! as pw.Text;
      expect(text.text.style!.fontSize, 8);
      expect(text.text.style!.fontWeight, pw.FontWeight.normal);
    },
  );

  test(
    'PDF construction and full-document copying stop when their owner expires',
    () async {
      for (final copy in [false, true]) {
        var current = true;
        Timer.run(() => current = false);
        final budget = UiWorkBudget(maxItems: 16, isCurrent: () => current);
        final work = copy
            ? buildUtenPrintSelectionText(_table(2000), '标题', budget: budget)
            : buildPrintPdfRows(
                PrintPdfRequest(
                  title: 'test',
                  headers: _table(2000).headers,
                  rows: _table(2000).rows,
                ),
                font,
                budget: budget,
              );
        await expectLater(work, throwsA(isA<UiWorkCancelled>()));
      }
    },
  );

  testWidgets(
    '100 paper pages mount only nearby pages and select-all copies the full document',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final table = _table(2000);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showUtenPrintPreview(
                  context: context,
                  title: '大表预览',
                  loader: () async => table,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      Finder papers() => find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'uten-print-paper-',
            ) &&
            widget is RepaintBoundary,
      );
      expect(papers().evaluate().length, lessThan(5));
      final initialMounted = papers().evaluate().length;
      expect(find.text('row-1999'), findsNothing);
      final area = tester.state<SelectionAreaState>(find.byType(SelectionArea));
      // Invoke the same overridable selection actions as keyboard shortcuts.
      final actionContext = tester.element(find.text('row-0'));
      Actions.invoke(
        actionContext,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();
      Actions.invoke(actionContext, CopySelectionTextIntent.copy);
      for (var i = 0; i < 100 && copied == null; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(copied, isNotNull);
      expect(copied, contains('row-1999'));
      expect(copied, contains('1999.12345678'));
      expect(copied, endsWith('第 100 / 100 页 · 共 2000 行'));
      expect(
        papers().evaluate().length,
        lessThan(5),
        reason: 'copying must not build the full document',
      );
      area.selectableRegion.clearSelection();
      await tester.pump();
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('uten-print-paper-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      for (var i = 0; i < 5; i++) {
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      expect(find.text('row-1999'), findsOneWidget);
      expect(papers().evaluate().length, lessThan(5));
      debugPrint(
        'print-preview rows=2000 pages=100 mountedInitially=$initialMounted mountedAtLast=${papers().evaluate().length}',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short 200-percent preview keeps horizontal paper scrolling and close reachable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showUtenPrintPreview(
                  context: context,
                  title: '宽表打印预览',
                  loader: () async => _table(60),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final horizontal = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      horizontal.position.jumpTo(horizontal.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(horizontal.position.pixels, greaterThan(500));
      final close = find.widgetWithText(UtenButton, '关闭');
      await tester.ensureVisible(close);
      await tester.pumpAndSettle();
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('uten-print-paper-list')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
