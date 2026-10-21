import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_auto_width.dart';

const _observerKey = ValueKey('width-observer');

class _GrowingCell extends StatefulWidget {
  const _GrowingCell({super.key, required this.child, this.initialWidth = 120});

  final Widget child;
  final double initialWidth;

  @override
  State<_GrowingCell> createState() => _GrowingCellState();
}

class _GrowingCellState extends State<_GrowingCell> {
  late double width = widget.initialWidth;
  final reports = <double>[];

  void _grow(double needed) {
    reports.add(needed);
    if (needed <= width + 0.5) return;
    setState(() => width = math.max(width, needed));
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: UtenTableCellAutoWidth(
      key: _observerKey,
      onWidthNeeded: _grow,
      child: widget.child,
    ),
  );
}

Future<_GrowingCellState> _pumpCell(
  WidgetTester tester,
  Widget child, {
  double initialWidth = 120,
}) async {
  final key = GlobalKey<_GrowingCellState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _GrowingCell(
              key: key,
              initialWidth: initialWidth,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

void _expectEditableFits(WidgetTester tester, Key fieldKey) {
  final editable = tester
      .state<EditableTextState>(
        find.descendant(
          of: find.byKey(fieldKey),
          matching: find.byType(EditableText),
        ),
      )
      .renderEditable;
  expect(
    editable.size.width + 0.5,
    greaterThanOrEqualTo(editable.getMaxIntrinsicWidth(0)),
  );
}

void main() {
  testWidgets('empty hint label and validator error do not widen the cell', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    const longMessage =
        'This is a deliberately long message that is not a value';
    final cell = await _pumpCell(
      tester,
      Form(
        key: form,
        child: TextFormField(
          decoration: const InputDecoration(
            hintText: longMessage,
            labelText: longMessage,
            helperText: longMessage,
          ),
          validator: (_) => longMessage,
        ),
      ),
    );
    expect(cell.width, 120);
    expect(cell.reports, isEmpty);
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(cell.width, 120);
    expect(cell.reports, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden candidates and disabled content markers do not widen', (
    tester,
  ) async {
    const hidden = 'Hidden candidate text that must never affect column width';
    final cell = await _pumpCell(
      tester,
      const Column(
        children: [
          UtenTableInputContent(
            child: IndexedStack(children: [Text('A'), Text(hidden)]),
          ),
          UtenTableInputContent(child: Offstage(child: Text(hidden))),
          UtenTableInputContent(
            child: Visibility(visible: false, child: Text(hidden)),
          ),
          UtenTableInputContent(enabled: false, child: Text(hidden)),
        ],
      ),
    );
    expect(cell.width, 120);
    expect(cell.reports, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fixed inner SizedBox cannot trigger endless column growth', (
    tester,
  ) async {
    final controller = TextEditingController(
      text: '1234567890123456789012345678901234567890',
    );
    addTearDown(controller.dispose);
    final cell = await _pumpCell(
      tester,
      Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(width: 90, child: TextField(controller: controller)),
      ),
    );
    expect(cell.width, 120);
    expect(cell.reports, isEmpty);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selected decorator and flat values grow but ordinary text does not',
    (tester) async {
      const value = 'Selected visible value that must be fully accommodated';
      final cell = await _pumpCell(
        tester,
        const Column(
          children: [
            Text(
              'Ordinary table text is handled by the host and is not an input value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            InputDecorator(
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.person),
                suffixIcon: Icon(Icons.expand_more),
              ),
              child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            UtenTableInputContent(
              child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
      expect(cell.width, greaterThan(120));
      final paragraphs = find.text(value).evaluate();
      for (final paragraph in paragraphs) {
        final render = paragraph.findRenderObject()!;
        expect(render, isA<RenderParagraph>());
        final text = render as RenderParagraph;
        expect(
          text.size.width + 0.5,
          greaterThanOrEqualTo(text.getMaxIntrinsicWidth(0)),
        );
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a loose maximum grows to its bound and then stops requesting', (
    tester,
  ) async {
    final controller = TextEditingController(
      text: '12345678901234567890123456789012345678901234567890',
    );
    addTearDown(controller.dispose);
    final cell = await _pumpCell(
      tester,
      Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: TextField(controller: controller),
        ),
      ),
    );
    expect(cell.width, closeTo(200, 0.5));
    final reportCount = cell.reports.length;
    await tester.pump(const Duration(milliseconds: 100));
    expect(cell.reports, hasLength(reportCount));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both flexible inputs fit with their prefix and suffix chrome', (
    tester,
  ) async {
    const firstKey = ValueKey('first-input');
    const secondKey = ValueKey('second-input');
    final first = TextEditingController(text: '12345678901234567890');
    final second = TextEditingController(text: 'ABCDEFGHIJKLMNO');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final cell = await _pumpCell(
      tester,
      Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              key: firstKey,
              controller: first,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.attach_money),
                suffixText: 'kg',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              key: secondKey,
              controller: second,
              decoration: const InputDecoration(
                suffixIcon: Icon(Icons.expand_more),
              ),
            ),
          ),
        ],
      ),
      initialWidth: 240,
    );
    expect(cell.width, greaterThan(240));
    _expectEditableFits(tester, firstKey);
    _expectEditableFits(tester, secondKey);
    final reportCount = cell.reports.length;
    await tester.pump(const Duration(milliseconds: 100));
    expect(cell.reports, hasLength(reportCount));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changing controller keeps focus and subscribes to the new value',
    (tester) async {
      const fieldKey = ValueKey('controlled-input');
      final first = TextEditingController(text: 'A');
      final second = TextEditingController(text: 'B');
      final current = ValueNotifier(first);
      final focus = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(current.dispose);
      addTearDown(focus.dispose);
      final cell = await _pumpCell(
        tester,
        ValueListenableBuilder<TextEditingController>(
          valueListenable: current,
          builder: (context, controller, _) => TextField(
            key: fieldKey,
            controller: controller,
            focusNode: focus,
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      final originalEditable = tester.state(find.byType(EditableText));
      current.value = second;
      await tester.pumpAndSettle();
      second.value = const TextEditingValue(
        text: 'Controller replacement value with enough characters to grow',
        selection: TextSelection(baseOffset: 3, extentOffset: 12),
      );
      await tester.pumpAndSettle();
      expect(cell.width, greaterThan(120));
      expect(tester.state(find.byType(EditableText)), same(originalEditable));
      expect(focus.hasFocus, isTrue);
      expect(
        second.selection,
        const TextSelection(baseOffset: 3, extentOffset: 12),
      );
      final reportCount = cell.reports.length;
      first.text =
          'An old detached controller must not request a new measurement';
      await tester.pump();
      expect(cell.reports, hasLength(reportCount));
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller,
        second,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
