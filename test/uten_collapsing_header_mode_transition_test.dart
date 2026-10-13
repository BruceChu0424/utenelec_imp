import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _ZoomTestBinding extends AutomatedTestWidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}

class _CellProbe extends StatefulWidget {
  const _CellProbe({super.key, required this.value});
  final int value;
  @override
  State<_CellProbe> createState() => _CellProbeState();
}

class _CellProbeState extends State<_CellProbe> {
  @override
  Widget build(BuildContext context) => Text('ROW-${widget.value}');
}

class _EditableBody extends StatefulWidget {
  const _EditableBody({
    super.key,
    required this.tableKey,
    required this.fieldKey,
    required this.cellKey,
    this.fullscreen = false,
  });
  final GlobalKey tableKey;
  final GlobalKey fieldKey;
  final GlobalKey cellKey;
  final bool fullscreen;
  @override
  State<_EditableBody> createState() => _EditableBodyState();
}

class _EditableBodyState extends State<_EditableBody> {
  final input = TextEditingController();
  final focus = FocusNode();
  late ScrollController primary;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    primary = PrimaryScrollController.of(context);
  }

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 64,
        child: TextField(
          key: widget.fieldKey,
          controller: input,
          focusNode: focus,
        ),
      ),
      Expanded(
        child: MasterDataTableView<int>(
          key: widget.tableKey,
          tableKey: 'test.mode-transition',
          primary: true,
          virtualized: true,
          showColumnChooser: false,
          showFullscreenToggle: widget.fullscreen,
          items: [for (var i = 0; i < 80; i++) i],
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          rowKeyOf: (row) => 'row-$row',
          columns: [
            MasterColumnDef<int>(
              key: 'value',
              label: '记录',
              width: 280,
              value: (row) => 'ROW-$row',
              cellBuilder: (_, row) => _CellProbe(
                key: row == 0 ? widget.cellKey : ValueKey(row),
                value: row,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _BorrowedList extends StatefulWidget {
  const _BorrowedList({required this.borrowed, required this.cellKey});
  final bool borrowed;
  final GlobalKey cellKey;
  @override
  State<_BorrowedList> createState() => _BorrowedListState();
}

class _BorrowedListState extends State<_BorrowedList> {
  final local = ScrollController();
  @override
  void dispose() {
    local.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: widget.borrowed ? PrimaryScrollController.of(context) : local,
    primary: false,
    itemExtent: 48,
    itemCount: 80,
    itemBuilder: (_, row) =>
        _CellProbe(key: row == 0 ? widget.cellKey : ValueKey(row), value: row),
  );
}

void main() {
  _ZoomTestBinding();
  for (final zoom in [1.0, 2.0]) {
    testWidgets(
      'compact/nested transitions retain table, row, IME and wheel offset ($zoom)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bodyKey = GlobalKey<_EditableBodyState>();
        final tableKey = GlobalKey();
        final fieldKey = GlobalKey();
        final cellKey = GlobalKey();
        final outer = ScrollController();
        addTearDown(outer.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: UtenDisplayZoomBox(
              fontFactor: zoom,
              child: Scaffold(
                body: UtenCollapsingHeaderScrollView(
                  controller: outer,
                  wheelGateDistance: 0,
                  wheelHoldWindow: Duration.zero,
                  compactBodyMinHeight: 480,
                  collapsingHeader: const SizedBox(
                    height: 96,
                    child: Text('HEADER'),
                  ),
                  body: _EditableBody(
                    key: bodyKey,
                    tableKey: tableKey,
                    fieldKey: fieldKey,
                    cellKey: cellKey,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final body = bodyKey.currentState!;
        final table = tableKey.currentState;
        final row = cellKey.currentState;
        final editableFinder = find.descendant(
          of: find.byKey(fieldKey),
          matching: find.byType(EditableText),
        );
        await tester.ensureVisible(find.byKey(fieldKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(fieldKey));
        await tester.pumpAndSettle();
        const editing = TextEditingValue(
          text: '12.3456789',
          selection: TextSelection(baseOffset: 3, extentOffset: 6),
          composing: TextRange(start: 1, end: 8),
        );
        tester.testTextInput.updateEditingValue(editing);
        await tester.pumpAndSettle();
        final editable = tester.state<EditableTextState>(editableFinder);
        expect(tester.getSemantics(editableFinder).value, editing.text);

        Future<void> wheel(double delta) async {
          final window = Offset.zero & tester.view.physicalSize;
          final point = tester
              .getRect(find.byKey(tableKey))
              .intersect(window)
              .center;
          await tester.sendEventToBinding(
            PointerScrollEvent(position: point, scrollDelta: Offset(0, delta)),
          );
          await tester.pumpAndSettle();
        }

        if (outer.position.pixels < outer.position.maxScrollExtent - 0.5) {
          await wheel(1000);
        }
        await wheel(24);
        final offset = body.primary.position.pixels;
        expect(offset, closeTo(24 / zoom, 0.01));
        expect(body.input.value, editing);

        for (final size in [
          const Size(1600, 1600),
          const Size(320, 900),
          const Size(1600, 1600),
          const Size(1600, 400),
          const Size(1600, 1600),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(bodyKey.currentState, same(body));
          expect(tableKey.currentState, same(table));
          expect(cellKey.currentState, same(row));
          expect(
            tester.state<EditableTextState>(editableFinder),
            same(editable),
          );
          expect(body.focus.hasFocus, isTrue);
          expect(body.input.value, editing);
          expect(tester.getSemantics(editableFinder).value, editing.text);
          expect(body.primary.position.pixels, closeTo(offset, 0.01));
          expect(tester.testTextInput.isRegistered, isTrue);
        }
        final before = outer.position.pixels;
        await wheel(24);
        expect(outer.position.pixels, greaterThan(before));
        expect(body.primary.position.pixels, closeTo(offset, 0.01));
        await wheel(1000);
        expect(body.primary.position.pixels, 0, reason: '到点交接保留第一行');
        expect(find.text('ROW-0'), findsOneWidget);
        await wheel(24);
        expect(body.primary.position.pixels, closeTo(24 / zoom, 0.01));
        await wheel(24);
        expect(body.primary.position.pixels, closeTo(48 / zoom, 0.01));
        expect(body.primary.position.pixels, greaterThan(offset));
        expect(body.input.value, editing);
      },
    );
  }

  testWidgets('primary master fullscreen returns to the coordinator safely', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bodyKey = GlobalKey<_EditableBodyState>();
    final tableKey = GlobalKey();
    final fieldKey = GlobalKey();
    final cellKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => UtenDisplayZoomBox(fontFactor: 2, child: child!),
        home: Scaffold(
          body: UtenCollapsingHeaderScrollView(
            collapsingHeader: const SizedBox(height: 96, child: Text('HEADER')),
            body: _EditableBody(
              key: bodyKey,
              tableKey: tableKey,
              fieldKey: fieldKey,
              cellKey: cellKey,
              fullscreen: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final body = bodyKey.currentState!;
    final table = tableKey.currentState;
    final row = cellKey.currentState;
    body.input.value = const TextEditingValue(
      text: '12.3456789',
      selection: TextSelection(baseOffset: 3, extentOffset: 6),
    );
    body.primary.jumpTo(24);
    await tester.pumpAndSettle();
    final before = body.primary.position.pixels;
    final toggle = find.byKey(const ValueKey('master-table-fullscreen-toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tableKey.currentState, same(table));
    expect(cellKey.currentState, same(row));
    await tester.tap(find.text('退出全屏'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tableKey.currentState, same(table));
    expect(cellKey.currentState, same(row));
    expect(body.primary.position.pixels, before);
    expect(body.input.text, '12.3456789');
    expect(
      body.input.selection,
      const TextSelection(baseOffset: 3, extentOffset: 6),
    );
    expect(
      tester.widget<MasterDataTableView<int>>(find.byKey(tableKey)).items,
      [for (var i = 0; i < 80; i++) i],
    );
  });

  testWidgets(
    'explicit primary borrower reattaches a foreign position safely',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      final cellKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, primary, _) => Scaffold(
              body: UtenCollapsingHeaderScrollView(
                collapsingHeader: const SizedBox(height: 96),
                body: _BorrowedList(cellKey: cellKey, borrowed: primary),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = cellKey.currentState;
      Scrollable.of(cellKey.currentContext!).position.jumpTo(24);
      await tester.pumpAndSettle();
      for (final primary in [false, true, false, true]) {
        enabled.value = primary;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(cellKey.currentState, same(row));
        expect(Scrollable.of(cellKey.currentContext!).position.pixels, 24);
      }
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getRect(find.byType(_BorrowedList)).center,
          scrollDelta: const Offset(0, 24),
        ),
      );
      await tester.pumpAndSettle();
      expect(Scrollable.of(cellKey.currentContext!).position.pixels, 48);
      expect(tester.takeException(), isNull);
    },
  );
}
