import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'support/table_cell_geometry.dart';

class _Row {
  const _Row(this.id, this.savedValue, this.controller);

  final String id;
  final String savedValue;
  final TextEditingController controller;
}

Widget _table(
  List<_Row> rows, {
  String columnKey = 'name',
  double padding = 12,
  bool fullscreen = false,
  ValueChanged<bool>? onCellSelection,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 900,
      height: 400,
      child: MasterDataTableView<_Row>(
        columns: [
          MasterColumnDef<_Row>(
            key: columnKey,
            label: 'Name',
            width: 112,
            cellHorizontalPaddingOf: (_) => padding,
            value: (row) => row.savedValue,
            cellBuilder: (context, row) {
              onCellSelection?.call(
                MasterDataTableCellScope.maybeOf(context)!.selected,
              );
              return TextField(
                key: ValueKey('input-${row.id}'),
                controller: row.controller,
              );
            },
          ),
        ],
        items: rows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        selectable: true,
        rowKeyOf: (row) => row.id,
        idOf: (row) => row.id,
        selectedIds: {for (final row in rows) row.id},
        onSelectedIdsChanged: (_) {},
        showFullscreenToggle: fullscreen,
      ),
    ),
  ),
);

double _columnWidth(WidgetTester tester) =>
    tableCellWidth(tester, find.text('Name'));

void main() {
  testWidgets(
    'controller edits grow custom inputs without saved value changes or losing editing state',
    (tester) async {
      final controller = TextEditingController(text: 'A');
      addTearDown(controller.dispose);
      final row = _Row('first', 'A', controller);
      var selected = false;
      await tester.pumpWidget(
        _table([row], onCellSelection: (value) => selected = value),
      );
      await tester.pumpAndSettle();
      final before = _columnWidth(tester);
      final field = find.byKey(const ValueKey('input-first'));
      await tester.showKeyboard(field);
      final editingState = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      const editingValue = TextEditingValue(
        text: 'An input value long enough to grow the business table column',
        selection: TextSelection(baseOffset: 5, extentOffset: 16),
        composing: TextRange(start: 17, end: 21),
      );
      controller.value = editingValue;
      await tester.pumpAndSettle();

      expect(_columnWidth(tester), greaterThan(before));
      expect(row.savedValue, 'A');
      expect(controller.value, editingValue);
      expect(
        identical(editingState, tester.state(find.byType(EditableText))),
        isTrue,
      );
      expect(editingState.widget.focusNode.hasFocus, isTrue);
      expect(selected, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('input growth respects manual widths and reset resumes fitting', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'A');
    addTearDown(controller.dispose);
    await tester.pumpWidget(_table([_Row('first', 'A', controller)]));
    await tester.pumpAndSettle();
    tester
        .widget<UtenColumnResizeHandle>(find.byType(UtenColumnResizeHandle))
        .onResize(20);
    await tester.pumpAndSettle();
    final manualWidth = _columnWidth(tester);

    controller.text = List.filled(30, 'long input ').join();
    await tester.pumpAndSettle();
    expect(_columnWidth(tester), manualWidth);

    tester
        .widget<UtenColumnResizeHandle>(find.byType(UtenColumnResizeHandle))
        .onReset!();
    await tester.pumpAndSettle();
    expect(_columnWidth(tester), 480);
    controller.text = 'A';
    await tester.pumpAndSettle();
    expect(_columnWidth(tester), 480);
    expect(tester.takeException(), isNull);
  });

  testWidgets('input width includes custom body padding', (tester) async {
    final controller = TextEditingController(text: 'A');
    addTearDown(controller.dispose);
    final row = _Row('first', 'A', controller);
    await tester.pumpWidget(_table([row], padding: 4));
    await tester.pumpAndSettle();
    controller.text = 'A moderately long input';
    await tester.pumpAndSettle();
    final compact = _columnWidth(tester);

    await tester.pumpWidget(_table([row], columnKey: 'padded', padding: 28));
    await tester.pumpAndSettle();
    expect(_columnWidth(tester), closeTo(compact + 48, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending growth remains safe across columns, data, and disposal',
    (tester) async {
      final first = TextEditingController(text: 'A');
      final second = TextEditingController(text: 'B');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(_table([_Row('first', 'A', first)]));
      await tester.pumpAndSettle();
      final initial = _columnWidth(tester);

      first.text = List.filled(40, 'old input ').join();
      await tester.pump();
      await tester.pumpWidget(
        _table([_Row('second', 'B', second)], columnKey: 'replacement'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('input-first')), findsNothing);
      expect(_columnWidth(tester), closeTo(initial, 1));

      second.text = List.filled(40, 'new input ').join();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      first.text = 'Detached first controller';
      second.text = 'Detached second controller';
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fullscreen custom inputs synchronize header width growth', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'A');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _table([_Row('first', 'A', controller)], fullscreen: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('master-table-fullscreen-toggle')),
    );
    await tester.pumpAndSettle();
    final before = _columnWidth(tester);

    controller.text = 'A value that expands the fullscreen input column';
    await tester.pumpAndSettle();
    expect(_columnWidth(tester), greaterThan(before));
    expect(tester.takeException(), isNull);
  });
}
