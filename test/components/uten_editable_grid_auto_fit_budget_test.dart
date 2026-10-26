import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

class _Row extends EditableGridRow {
  _Row(this.index);
  final int index;
}

Widget _surface(
  UtenEditableGridController<_Row> controller, {
  required String Function(_Row) read,
  required ValueChanged<double> onWidth,
  double scale = 1,
}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: ListView(
          children: [
            UtenEditableGrid<_Row>(
              controller: controller,
              showAddRow: false,
              showColumnSettings: false,
              columns: [
                EditableGridColumn<_Row>(
                  key: 'value',
                  label: '备注',
                  width: 120,
                  filterValueOf: (_) => 'group',
                  textOf: read,
                  cellBuilder: (_, row) => LayoutBuilder(
                    builder: (_, constraints) {
                      onWidth(constraints.maxWidth);
                      return Text('row ${row.index}');
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('sampled widths publish once after the complete bounded scan', (
    tester,
  ) async {
    final controller = UtenEditableGridController<_Row>(
      initial: List.generate(1000, _Row.new),
    );
    addTearDown(controller.dispose);
    var width = 0.0;
    var reads = 0;
    final presentedWidths = <double>[];
    await tester.pumpWidget(
      _surface(
        controller,
        read: (row) {
          reads++;
          return 'm' * (15 + row.index ~/ 5);
        },
        onWidth: (value) {
          width = value;
          if (presentedWidths.isEmpty ||
              (presentedWidths.last - value).abs() > .5) {
            presentedWidths.add(value);
          }
        },
      ),
    );
    for (var frame = 0; frame < 120 && reads < 200; frame++) {
      final before = reads;
      await tester.pump(const Duration(milliseconds: 16));
      expect(reads - before, lessThanOrEqualTo(32));
    }
    await tester.pumpAndSettle();
    expect(reads, 200, reason: 'the existing 200-row sample stays complete');
    expect(
      presentedWidths,
      hasLength(2),
      reason: 'one floor and one final width',
    );
    expect(presentedWidths.first, closeTo(104, .5));
    expect(width, closeTo(464, .5));
    expect(controller.length, 1000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source replacement cancels unread old width samples', (
    tester,
  ) async {
    final controller = UtenEditableGridController<_Row>(
      initial: List.generate(1000, _Row.new),
    );
    addTearDown(controller.dispose);
    final reads = <int>[];
    var width = 0.0;
    await tester.pumpWidget(
      _surface(
        controller,
        read: (row) {
          reads.add(row.index);
          return row.index == 199 ? '长内容' * 60 : 'a';
        },
        onWidth: (value) => width = value,
      ),
    );
    expect(reads, isNot(contains(199)));
    controller.replaceAll(List.generate(20, (i) => _Row(2000 + i)));
    reads.clear();
    await tester.pumpAndSettle();
    expect(reads, isNotEmpty);
    expect(reads.every((index) => index >= 2000), isTrue);
    expect(width, closeTo(104, .5));
    expect(controller.length, 20);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual resize remains locked while sampled widths are pending', (
    tester,
  ) async {
    final controller = UtenEditableGridController<_Row>(
      initial: List.generate(1000, _Row.new),
    );
    addTearDown(controller.dispose);
    var width = 0.0;
    var reachedLastSample = false;
    await tester.pumpWidget(
      _surface(
        controller,
        read: (row) {
          reachedLastSample |= row.index == 199;
          return row.index == 199 ? '长内容' * 60 : 'a';
        },
        onWidth: (value) => width = value,
      ),
    );
    expect(reachedLastSample, isFalse);
    // The first frame is the table shell. Start the drag once its first real
    // row has geometry; the long-tail width sample is still pending.
    await tester.pump();
    expect(reachedLastSample, isFalse);
    final header = tester.renderObject(find.text('备注')) as RenderBox;
    final origin = header.localToGlobal(Offset.zero);
    final grip = Offset(origin.dx - 12 + width + 16 - 2, origin.dy + 10);
    final gesture = await tester.startGesture(
      grip,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.up();
    await tester.pump();
    final locked = width;
    expect(locked, lessThan(104));
    await tester.pumpAndSettle();
    expect(width, locked);
    expect(controller.length, 1000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text scale changes discard earlier queued sample geometry', (
    tester,
  ) async {
    final controller = UtenEditableGridController<_Row>(
      initial: List.generate(1000, _Row.new),
    );
    addTearDown(controller.dispose);
    var width = 0.0;
    Widget surface(double scale) => _surface(
      controller,
      scale: scale,
      read: (_) => 'abcdefghijklmnop',
      onWidth: (value) => width = value,
    );
    await tester.pumpWidget(surface(1));
    await tester.pumpAndSettle();
    final normal = width;
    await tester.pumpWidget(surface(2));
    await tester.pumpWidget(surface(1));
    await tester.pumpAndSettle();
    expect(width, closeTo(normal, .5));
    expect(controller.length, 1000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cold auto-fit samples advance in bounded layout turns', (
    tester,
  ) async {
    final rows = List.generate(1000, _Row.new);
    final controller = UtenEditableGridController<_Row>(initial: rows);
    addTearDown(controller.dispose);
    final readRows = <int>[];
    var width = 0.0;
    final slices = <String, List<int>>{};
    debugUiWorkSliceObserver = (label, elapsed) {
      slices.putIfAbsent(label, () => []).add(elapsed.inMicroseconds);
    };
    addTearDown(() => debugUiWorkSliceObserver = null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              UtenEditableGrid<_Row>(
                controller: controller,
                showAddRow: false,
                showColumnSettings: false,
                columns: [
                  EditableGridColumn<_Row>(
                    key: 'value',
                    label: '备注',
                    width: 120,
                    filterValueOf: (_) => 'group',
                    textOf: (row) {
                      readRows.add(row.index);
                      return row.index == 199 ? '长内容' * 60 : '物料 ${row.index}';
                    },
                    cellBuilder: (_, row) => LayoutBuilder(
                      builder: (_, constraints) {
                        width = constraints.maxWidth;
                        return Text('row ${row.index}');
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    debugPrint(
      'cold-grid first text samples=${readRows.length}; slices=$slices',
    );
    expect(readRows.length, lessThanOrEqualTo(32));
    await tester.pumpAndSettle();
    expect(readRows.toSet(), containsAll(List.generate(200, (i) => i)));
    expect(readRows.every((row) => row < 200), isTrue);
    expect(width, closeTo(464, .5), reason: 'Sample 199 still controls width.');
    expect(controller.length, 1000);
    expect(tester.takeException(), isNull);
  });
}
