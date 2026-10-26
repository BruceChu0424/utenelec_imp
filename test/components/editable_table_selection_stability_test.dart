import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_row_drag.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row extends EditableGridRow {
  final tone = ValueNotifier<int>(0);

  @override
  void dispose() {
    tone.dispose();
    super.dispose();
  }
}

class _Editor extends StatefulWidget {
  const _Editor({required this.onMount});
  final VoidCallback onMount;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final text = TextEditingController(text: 'original');
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('cell-input'),
    controller: text,
    focusNode: focus,
  );
}

void main() {
  testWidgets(
    'an empty source becoming populated retains its live custom editor',
    (tester) async {
      final row = _Row();
      final canonical = ValueNotifier('');
      addTearDown(row.dispose);
      addTearDown(canonical.dispose);
      var mounts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: canonical,
              builder: (_, value, _) => MasterDataTableView<_Row>(
                columns: [
                  MasterColumnDef<_Row>(
                    key: 'value',
                    label: 'Value',
                    width: 300,
                    value: (_) => value,
                    cellBuilder: (_, _) => _Editor(onMount: () => mounts++),
                  ),
                ],
                items: [row],
                idOf: (_) => 'row',
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cell-input')));
      await tester.pump();
      final editor = tester.state<_EditorState>(find.byType(_Editor));
      const draft = TextEditingValue(
        text: '中文 draft ',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      editor.text.value = draft;
      for (final value in ['saved', '', 'next']) {
        canonical.value = value;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(_Editor)), same(editor));
        expect(editor.focus.hasFocus, isTrue);
        expect(editor.text.value, draft);
      }
      expect(mounts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'append rows appear and disappear without remounting the last data editor',
    (tester) async {
      final row = _Row();
      final append = ValueNotifier(true);
      addTearDown(row.dispose);
      addTearDown(append.dispose);
      var mounts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: append,
              builder: (_, showAppend, _) => MasterDataTableView<_Row>(
                columns: [
                  MasterColumnDef<_Row>(
                    key: 'value',
                    label: 'Value',
                    width: 300,
                    value: (_) => 'original',
                    cellBuilder: (_, _) => _Editor(onMount: () => mounts++),
                  ),
                ],
                items: [row],
                idOf: (_) => 'row',
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                appendRows: [
                  if (showAppend)
                    MasterTableAppendRow(
                      key: const ValueKey('new-row'),
                      cellBuilder: (_, _) => const Text('New row'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cell-input')));
      await tester.pump();
      final editor = tester.state<_EditorState>(find.byType(_Editor));
      const draft = TextEditingValue(
        text: '中文 draft ',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      editor.text.value = draft;
      for (final show in [false, true, false]) {
        append.value = show;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(_Editor)), same(editor));
        expect(editor.focus.hasFocus, isTrue);
        expect(editor.text.value, draft);
      }
      expect(mounts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disabling row drag retains focused editors and rejects stale gestures',
    (tester) async {
      final row = _Row();
      final allowed = ValueNotifier(true);
      addTearDown(row.dispose);
      addTearDown(allowed.dispose);
      var mounts = 0;
      var starts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: allowed,
              builder: (_, canDrag, _) => MasterDataTableView<_Row>(
                columns: [
                  MasterColumnDef<_Row>(
                    key: 'value',
                    label: 'Value',
                    width: 300,
                    value: (_) => 'original',
                    cellBuilder: (_, _) => _Editor(onMount: () => mounts++),
                  ),
                ],
                items: [row],
                idOf: (_) => 'row',
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                rowDrag: UtenTableRowDrag<_Row>(
                  canDragRow: (_) => allowed.value,
                  dragRowsOf: (row) {
                    starts++;
                    return [row];
                  },
                  canDrop: (_, _) => false,
                  onDrop: (_, _, _) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('cell-input'));
      await tester.tap(input);
      await tester.pump();
      final editor = tester.state<_EditorState>(find.byType(_Editor));
      const draft = TextEditingValue(
        text: '中文 draft ',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      editor.text.value = draft;
      final affordance = tester
          .widgetList<RawGestureDetector>(
            find.ancestor(of: input, matching: find.byType(RawGestureDetector)),
          )
          .firstWhere(
            (widget) =>
                widget.gestures.containsKey(LongPressGestureRecognizer) &&
                widget.gestures.containsKey(VerticalDragGestureRecognizer),
          );
      final factory =
          affordance.gestures[LongPressGestureRecognizer]!
              as GestureRecognizerFactoryWithHandlers<
                LongPressGestureRecognizer
              >;
      final recognizer = factory.constructor();
      factory.initializer(recognizer);
      final staleStart = recognizer.onLongPressStart!;
      allowed.value = false;
      staleStart(
        LongPressStartDetails(globalPosition: tester.getCenter(input)),
      );
      expect(starts, 0);
      recognizer.dispose();
      await tester.pump();
      expect(tester.state(find.byType(_Editor)), same(editor));
      expect(editor.focus.hasFocus, isTrue);
      expect(editor.text.value, draft);
      allowed.value = true;
      await tester.pump();
      expect(tester.state(find.byType(_Editor)), same(editor));
      expect(editor.text.value, draft);
      expect(mounts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final grid in [false, true]) {
    testWidgets(
      '${grid ? 'document' : 'master'} selection retains semantic-cell editor and IME composition',
      (tester) async {
        final row = _Row();
        final controller = UtenEditableGridController<_Row>(initial: [row]);
        final selected = ValueNotifier(false);
        addTearDown(controller.dispose);
        addTearDown(selected.dispose);
        var mounts = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: selected,
                builder: (context, isSelected, _) {
                  final color = Theme.of(context).colorScheme.errorContainer;
                  return grid
                      ? ListView(
                          children: [
                            UtenEditableGrid<_Row>(
                              controller: controller,
                              selectable: true,
                              showAddRow: false,
                              showRowDelete: false,
                              columns: [
                                EditableGridColumn<_Row>(
                                  key: 'value',
                                  label: 'Value',
                                  width: 300,
                                  cellColor: (_, _) => color,
                                  cellColorListenableOf: (row) => row.tone,
                                  cellBuilder: (_, _) =>
                                      _Editor(onMount: () => mounts++),
                                ),
                              ],
                            ),
                          ],
                        )
                      : MasterDataTableView<_Row>(
                          columns: [
                            MasterColumnDef<_Row>(
                              key: 'value',
                              label: 'Value',
                              width: 300,
                              value: (_) => 'original',
                              cellColor: (_, _) => color,
                              cellColorListenableOf: (row) => row.tone,
                              cellBuilder: (_, _) =>
                                  _Editor(onMount: () => mounts++),
                            ),
                          ],
                          items: [row],
                          selectable: true,
                          idOf: (_) => 'row',
                          selectedIds: isSelected ? const {'row'} : const {},
                          facets: const {},
                          nullCounts: const {},
                          filters: const {},
                          onFilterChanged: (_, _) {},
                        );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('cell-input')));
        await tester.pump();
        final editor = tester.state<_EditorState>(find.byType(_Editor));
        const draft = TextEditingValue(
          text: '中文 draft ',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        );
        editor.text.value = draft;
        for (final value in [true, false, true, false]) {
          if (grid) {
            controller.setSelected([row], value);
          } else {
            selected.value = value;
          }
          await tester.pump();
          expect(tester.state(find.byType(_Editor)), same(editor));
          expect(editor.focus.hasFocus, isTrue);
          expect(editor.text.value, draft);
          row.tone.value++;
          await tester.pump();
          expect(tester.state(find.byType(_Editor)), same(editor));
          expect(editor.text.value, draft);
        }
        expect(mounts, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
