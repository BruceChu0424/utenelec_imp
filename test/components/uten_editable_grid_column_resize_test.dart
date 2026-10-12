import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

class _ResizeRow extends EditableGridRow {
  _ResizeRow() {
    quantity.addListener(() => quantityWrites++);
  }

  final name = 'Product-1';
  final note = 'Original note';
  final quantity = TextEditingController(text: '123.4567');
  int quantityWrites = 0;

  @override
  void dispose() {
    quantity.dispose();
    super.dispose();
  }
}

Finder _nameGrip() => find.byWidgetPredicate(
  (widget) => widget is UtenColumnResizeHandle && widget.label == 'Product',
);

Finder _headerCell(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox &&
            widget.width != null &&
            widget.child is DecoratedBox,
      ),
    )
    .first;

Future<void> _pumpGrid(
  WidgetTester tester,
  UtenEditableGridController<_ResizeRow> controller,
  TextDirection direction,
) async {
  tester.view.physicalSize = const Size(1024, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 760,
              child: ListView(
                children: [
                  UtenEditableGrid<_ResizeRow>(
                    controller: controller,
                    showColumnSettings: false,
                    showRowDelete: false,
                    showAddRow: false,
                    columns: [
                      EditableGridColumn<_ResizeRow>(
                        key: 'name',
                        label: 'Product',
                        width: 200,
                        cellBuilder: (_, row) => Text(row.name),
                      ),
                      EditableGridColumn<_ResizeRow>(
                        key: 'quantity',
                        label: 'Quantity',
                        width: 220,
                        cellBuilder: (_, row) => TextField(
                          key: const ValueKey('quantity-input'),
                          controller: row.quantity,
                        ),
                      ),
                      EditableGridColumn<_ResizeRow>(
                        key: 'note',
                        label: 'Note',
                        width: 180,
                        cellBuilder: (_, row) => Text(row.note),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

void main() {
  for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
    testWidgets(
      'grid grip follows the logical header end and outward mouse drag grows only that column: $direction',
      (tester) async {
        final row = _ResizeRow();
        final controller = UtenEditableGridController<_ResizeRow>(
          initial: [row],
        );
        await _pumpGrid(tester, controller, direction);
        final before = tester.getRect(_headerCell('Product'));
        final quantityBefore = tester.getSize(_headerCell('Quantity')).width;
        final noteBefore = tester.getSize(_headerCell('Note')).width;
        final grip = tester.getRect(_nameGrip());
        final rtl = direction == TextDirection.rtl;
        expect(grip.width, 8);
        expect(grip.center.dx, closeTo(rtl ? before.left : before.right, 0.1));

        // Half of the 8px grip extends beyond the header Stack. Start two pixels
        // inside the column so the real clipped hit area receives the pointer.
        final point = Offset(
          rtl ? before.left + 2 : before.right - 2,
          grip.center.dy,
        );
        final pointer = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
        );
        await pointer.moveBy(Offset(rtl ? -80 : 80, 0));
        await pointer.up();
        await tester.pumpAndSettle();

        expect(
          tester.getSize(_headerCell('Product')).width,
          closeTo(before.width + 80, 0.5),
        );
        expect(tester.getSize(_headerCell('Quantity')).width, quantityBefore);
        expect(tester.getSize(_headerCell('Note')).width, noteBefore);
        expect(controller.rows, [row]);
        expect(row.quantity.text, '123.4567');
        expect(row.quantityWrites, 0);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('quantity-input')))
              .controller,
          same(row.quantity),
        );
        expect(find.text(row.name), findsOneWidget);
        expect(find.text(row.note), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
