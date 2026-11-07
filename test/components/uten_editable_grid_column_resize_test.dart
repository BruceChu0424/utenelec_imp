import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import '../support/table_cell_geometry.dart';

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

Finder _headerCell(String label) => tableCellFrame(find.text(label));

Future<void> _pumpGrid(
  WidgetTester tester,
  UtenEditableGridController<_ResizeRow> controller,
  TextDirection direction, {
  double minimumWidth = 48,
  bool showColumnSettings = false,
}) async {
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
                    showColumnSettings: showColumnSettings,
                    showRowDelete: false,
                    showAddRow: false,
                    columns: [
                      EditableGridColumn<_ResizeRow>(
                        key: 'name',
                        label: 'Product',
                        width: 200,
                        minimumWidthOf: (_) => minimumWidth,
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
      'hover on either side of a header divider shows the resize grip and dragging from the neighboring cell resizes only its owner: $direction',
      (tester) async {
        final row = _ResizeRow();
        final controller = UtenEditableGridController<_ResizeRow>(
          initial: [row],
        );
        await _pumpGrid(
          tester,
          controller,
          direction,
          showColumnSettings: true,
        );
        final before = tester.getRect(_headerCell('Product'));
        final quantityBefore = tester.getSize(_headerCell('Quantity')).width;
        final noteBefore = tester.getSize(_headerCell('Note')).width;
        final grip = tester.getRect(_nameGrip());
        final rtl = direction == TextDirection.rtl;
        expect(grip.width, 16);
        expect(grip.center.dx, closeTo(rtl ? before.left : before.right, 0.1));

        final divider = find.descendant(
          of: _nameGrip(),
          matching: find.byType(AnimatedContainer),
        );
        final primary = Theme.of(tester.element(divider)).colorScheme.primary;
        Color? dividerColor() =>
            (tester.widget<AnimatedContainer>(divider).decoration
                    as BoxDecoration)
                .color;
        final mouseTracker = RendererBinding.instance.mouseTracker;
        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        final neighborSide = Offset(rtl ? -6 : 6, 0);
        final outside = grip.center + Offset(rtl ? -12 : 12, 0);
        expect(tester.getSize(divider).width, 1);
        expect(dividerColor(), Colors.transparent);

        await pointer.addPointer(location: outside);
        await tester.pump();
        expect(
          mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.resizeLeftRight),
        );
        for (final point in [
          grip.center - neighborSide,
          grip.center + neighborSide,
        ]) {
          await pointer.moveTo(point);
          await tester.pumpAndSettle();
          expect(
            mouseTracker.debugDeviceActiveCursor(1),
            SystemMouseCursors.resizeLeftRight,
          );
          expect(tester.getSize(divider).width, 3);
          expect(dividerColor(), primary);
        }

        await pointer.down(grip.center + neighborSide);
        await pointer.moveBy(Offset(rtl ? -80 : 80, 0));
        await pointer.moveBy(const Offset(0, 70));
        await tester.pumpAndSettle();
        expect(tester.getSize(divider).width, 3);
        await pointer.up();
        await tester.pumpAndSettle();
        expect(tester.getSize(divider).width, 1);
        expect(dividerColor(), Colors.transparent);

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
        final after = tester.getRect(_headerCell('Product'));
        final quantity = tester.getRect(_headerCell('Quantity'));
        expect(
          rtl ? quantity.right : quantity.left,
          closeTo(rtl ? after.left : after.right, 0.1),
        );

        // Interrupt a second resize while its pointer is outside the header.
        await pointer.down(tester.getCenter(_nameGrip()) + neighborSide);
        await pointer.moveBy(Offset(rtl ? 25 : -25, 0));
        await pointer.moveBy(const Offset(0, 70));
        await tester.pumpAndSettle();
        expect(tester.getSize(divider).width, 3);
        await pointer.cancel();
        await tester.pumpAndSettle();
        expect(tester.getSize(divider).width, 1);
        expect(dividerColor(), Colors.transparent);
        await pointer.removePointer();
        expect(find.text(row.name), findsOneWidget);
        expect(find.text(row.note), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
    testWidgets(
      'shared minimum and double-click reset preserve business controllers: $direction',
      (tester) async {
        final row = _ResizeRow();
        final controller = UtenEditableGridController<_ResizeRow>(
          initial: [row],
        );
        await _pumpGrid(tester, controller, direction, minimumWidth: 140);
        final pointer = await tester.startGesture(
          tester.getCenter(_nameGrip()),
          kind: PointerDeviceKind.mouse,
        );
        await pointer.moveBy(
          Offset(direction == TextDirection.rtl ? 500 : -500, 0),
        );
        await pointer.up();
        await tester.pumpAndSettle();
        expect(tester.getSize(_headerCell('Product')).width, 140);
        await tester.tap(_nameGrip());
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(_nameGrip());
        await tester.pumpAndSettle();
        expect(tester.getSize(_headerCell('Product')).width, 200);
        expect(row.quantity.text, '123.4567');
        expect(row.quantityWrites, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
