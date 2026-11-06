import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

/// A local constraint changes; screen, width, rows, table
/// Widget identity and scroll pixels remain unchanged. No API/session providers.
void main() {
  testWidgets(
    'fixed-child table height growth fills viewport and retains composing editor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final height = ValueNotifier<double>(280);
      addTearDown(height.dispose);
      final rows = List<int>.unmodifiable(List.generate(1000, (i) => i));
      final first = GlobalKey<_HeightRowState>();
      var firstMounts = 0;
      final table = MasterDataTableView<int>(
        // Default primary/virtualized/embedded flags are intentional.
        items: rows,
        rowKeyOf: (row) => '$row',
        columns: [
          MasterColumnDef<int>(
            key: 'value',
            label: 'Value',
            width: 420,
            value: (row) => '$row',
            cellBuilder: (_, row) => _HeightRow(
              row,
              key: row == 0 ? first : ValueKey('probe:$row'),
              onFirstMount: () => firstMounts++,
            ),
          ),
        ],
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        showFullscreenToggle: false,
        showColumnChooser: false,
      );
      const screen = Size(1000, 1000);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(size: screen),
              child: Align(
                alignment: Alignment.topLeft,
                child: ValueListenableBuilder<double>(
                  valueListenable: height,
                  child: table,
                  builder: (_, value, child) =>
                      SizedBox(width: 900, height: value, child: child),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _covered(tester);
      final scrollable = _body(tester);
      expect(scrollable.position.pixels, 0);
      final initialViewport = _viewport(tester);
      final state = first.currentState!;
      await tester.showKeyboard(
        find.descendant(
          of: find.byKey(first),
          matching: find.byType(TextField),
        ),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'ni',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      final editorValue = state.controller.value;
      expect(editorValue.composing, const TextRange(start: 0, end: 2));
      expect(state.focus.hasFocus, isTrue);
      final mediaSize = MediaQuery.sizeOf(first.currentContext!);
      final width = tester.getSize(find.byType(MasterDataTableView<int>)).width;

      height.value = 700;
      // Let normal metrics and post-layout callbacks settle without moving the
      // scroll position or rebuilding the fixed child. Caret stays focused.
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        _viewport(tester).height,
        greaterThan(initialViewport.height + 300),
      );
      expect(scrollable.position.pixels, 0);
      expect(MediaQuery.sizeOf(first.currentContext!), mediaSize);
      expect(
        tester.getSize(find.byType(MasterDataTableView<int>)).width,
        width,
      );
      expect(first.currentState, same(state));
      expect(firstMounts, 1);
      expect(state.focus.hasFocus, isTrue);
      expect(state.controller.value, editorValue);
      _covered(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

ScrollableState _body(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    )
    .singleWhere((state) => state.position.axis == Axis.vertical);

Rect _viewport(WidgetTester tester) => tester.getRect(
  find.descendant(
    of: find.byType(ListView),
    matching: find.byWidgetPredicate(
      (widget) => widget is Viewport || widget is ShrinkWrappingViewport,
    ),
  ),
);

void _covered(WidgetTester tester) {
  final viewport = _viewport(tester);
  final rectangles = <Rect>[];
  for (final element in find.byType(_HeightRow).evaluate()) {
    final id = (element.widget as _HeightRow).id;
    Element? boundary;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is RepaintBoundary &&
          ancestor.widget.key == ValueKey('row:$id')) {
        boundary = ancestor;
        return false;
      }
      return true;
    });
    final box = boundary?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.bottom > viewport.top && rect.top < viewport.bottom) {
      rectangles.add(rect);
    }
  }
  rectangles.sort((a, b) => a.top.compareTo(b.top));
  expect(rectangles, isNotEmpty);
  var end = viewport.top;
  for (final rect in rectangles) {
    expect(
      rect.top,
      lessThanOrEqualTo(end + 1),
      reason: 'No spacer/blank gap in the actual visible rows.',
    );
    if (rect.bottom > end) end = rect.bottom;
  }
  expect(end, greaterThanOrEqualTo(viewport.bottom - 1));
}

class _HeightRow extends StatefulWidget {
  const _HeightRow(this.id, {super.key, required this.onFirstMount});
  final int id;
  final VoidCallback onFirstMount;
  @override
  State<_HeightRow> createState() => _HeightRowState();
}

class _HeightRowState extends State<_HeightRow> {
  final controller = TextEditingController();
  final focus = FocusNode();
  @override
  void initState() {
    super.initState();
    if (widget.id == 0) widget.onFirstMount();
  }

  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: widget.id == 0
        ? TextField(controller: controller, focusNode: focus)
        : Text('row-${widget.id}'),
  );
}
