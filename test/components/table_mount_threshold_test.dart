import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row extends EditableGridRow {
  _Row(this.id);
  final int id;
}

class _Probe extends StatefulWidget {
  const _Probe(this.id, this.record);
  final int id;
  final VoidCallback record;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.record();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    key: ValueKey('field-${widget.id}'),
    initialValue: '原文 ${widget.id}',
  );
}

Future<void> _wait(WidgetTester tester) async {
  final pending = <Future<void>>[];
  for (final element
      in find
          .byWidgetPredicate(
            (w) => w is UtenAncestorRowWindow || w is UtenDeferredRowMount,
          )
          .evaluate()) {
    final widget = element.widget;
    if (widget is UtenAncestorRowWindow) pending.add(widget.controller.settled);
    if (widget is UtenDeferredRowMount) pending.add(widget.controller.settled);
  }
  await tester.pumpAndSettle();
  await Future.wait(pending);
  expect(find.byType(UtenRowMountPlaceholder), findsNothing);
}

ScrollableState _vertical(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    )
    .firstWhere(
      (state) =>
          state.position.axis == Axis.vertical &&
          state.position.hasContentDimensions,
    );

void main() {
  for (final server in [false, true]) {
    testWidgets(
      'master ${server ? 'server' : 'local'} preserves editing across the 12-row admission boundary',
      (tester) async {
        final count = ValueNotifier(11);
        addTearDown(count.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: count,
                builder: (_, length, _) => MasterDataTableView<int>(
                  items: List.generate(length, (i) => i),
                  virtualized: true,
                  rowKeyOf: (row) => '$row',
                  onLoadMore: server ? () {} : null,
                  columns: [
                    MasterColumnDef<int>(
                      key: 'value',
                      label: '值',
                      width: 250,
                      value: (row) => '$row',
                      cellBuilder: (_, row) => _Probe(row, () {}),
                    ),
                  ],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                ),
              ),
            ),
          ),
        );
        await _wait(tester);
        final field = find.byKey(const ValueKey('field-0'));
        await tester.tap(field);
        await tester.enterText(field, '未提交输入');
        await tester.pump();
        final editable = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        final state = tester.state<EditableTextState>(editable);
        final controller = state.widget.controller;
        controller.value = controller.value.copyWith(
          selection: const TextSelection(baseOffset: 1, extentOffset: 3),
          composing: const TextRange(start: 1, end: 3),
        );
        for (final length in [12, 10, 20]) {
          count.value = length;
          await _wait(tester);
          expect(tester.state<EditableTextState>(editable), same(state));
          expect(state.widget.focusNode.hasFocus, isTrue);
          expect(controller.text, '未提交输入');
          expect(
            controller.selection,
            const TextSelection(baseOffset: 1, extentOffset: 3),
          );
          expect(controller.value.composing, const TextRange(start: 1, end: 3));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final grid in [true, false]) {
    for (final count in [20, 63, 199]) {
      testWidgets(
        '${grid ? 'grid' : 'master'} $count rows use real mount budget below the old 200-row cutoff',
        (tester) async {
          final frames = <Duration, int>{};
          void record() {
            final stamp = SchedulerBinding.instance.currentFrameTimeStamp;
            frames.update(stamp, (value) => value + 1, ifAbsent: () => 1);
          }

          final models = List.generate(count, _Row.new);
          final controller = UtenEditableGridController<_Row>(initial: models);
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: TargetPlatform.windows),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    height: 400,
                    child: grid
                        ? ListView(
                            children: [
                              UtenEditableGrid<_Row>(
                                controller: controller,
                                showAddRow: false,
                                showColumnSettings: false,
                                columns: [
                                  for (var c = 0; c < 8; c++)
                                    EditableGridColumn<_Row>(
                                      key: 'c$c',
                                      label: '列$c',
                                      width: 180,
                                      cellBuilder: (_, row) => c == 0
                                          ? _Probe(row.id, record)
                                          : TextFormField(
                                              initialValue: '值 ${row.id}',
                                            ),
                                    ),
                                ],
                              ),
                            ],
                          )
                        : MasterDataTableView<_Row>(
                            items: models,
                            virtualized: true,
                            rowKeyOf: (row) => '${row.id}',
                            showColumnChooser: false,
                            columns: [
                              for (var c = 0; c < 8; c++)
                                MasterColumnDef<_Row>(
                                  key: 'c$c',
                                  label: '列$c',
                                  width: 180,
                                  value: (row) => '${row.id}',
                                  cellBuilder: (_, row) => c == 0
                                      ? _Probe(row.id, record)
                                      : TextFormField(
                                          initialValue: '值 ${row.id}',
                                        ),
                                ),
                            ],
                            facets: const {},
                            nullCounts: const {},
                            filters: const {},
                            onFilterChanged: (_, _) {},
                          ),
                  ),
                ),
              ),
            ),
          );
          final first = frames.values.fold(0, (a, b) => a + b);
          debugPrint('mount-threshold grid=$grid rows=$count first=$first');
          expect(first, lessThanOrEqualTo(4));
          await _wait(tester);
          expect(frames.values.every((value) => value <= 4), isTrue);
          expect(
            find.byKey(const ValueKey('field-0')).hitTestable(),
            findsOneWidget,
          );
          expect(models, hasLength(count));
          final position = _vertical(tester).position;
          for (var hop = 0; hop < 8; hop++) {
            final before = position.maxScrollExtent;
            position.jumpTo(before);
            await _wait(tester);
            if ((position.maxScrollExtent - before).abs() < .5) break;
          }
          expect(frames.values.every((value) => value <= 4), isTrue);
          expect(
            find.byKey(ValueKey('field-${count - 1}')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    '200-row server load-more sliver bounds actual Elements across far jumps',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final frames = <Duration, int>{};
      var loads = 0;
      void record() {
        final stamp = SchedulerBinding.instance.currentFrameTimeStamp;
        frames.update(stamp, (value) => value + 1, ifAbsent: () => 1);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<int>(
              items: List.generate(200, (i) => i),
              virtualized: true,
              rowKeyOf: (row) => '$row',
              onLoadMore: () => loads++,
              columns: [
                for (var c = 0; c < 8; c++)
                  MasterColumnDef<int>(
                    key: 'c$c',
                    label: '列$c',
                    width: 180,
                    value: (row) => '$row',
                    cellBuilder: (_, row) => c == 0
                        ? _Probe(row, record)
                        : TextFormField(initialValue: '值 $row'),
                  ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      await _wait(tester);
      final position = _vertical(tester).position;
      frames.clear();
      for (var hop = 0; hop < 8; hop++) {
        final before = position.maxScrollExtent;
        position.jumpTo(before);
        await _wait(tester);
        debugPrint(
          'server-jump-hop=$hop pixels=${position.pixels} max=${position.maxScrollExtent} before=$before',
        );
        if ((position.maxScrollExtent - before).abs() < .5) break;
      }
      final builtAtEnd = frames.values.fold(0, (a, b) => a + b);
      debugPrint(
        'server-sliver-jump newElements=$builtAtEnd maxPerFrame=${frames.values.fold(0, (a, b) => a > b ? a : b)}',
      );
      expect(frames.values.every((value) => value <= 4), isTrue);
      expect(builtAtEnd, lessThan(80));
      expect(
        find.byKey(const ValueKey('field-199')).hitTestable(),
        findsOneWidget,
      );
      expect(loads, greaterThan(0));
      position.jumpTo(0);
      await _wait(tester);
      final firstField = find.byKey(const ValueKey('field-0'));
      debugPrint(
        'server-return pixels=${position.pixels} max=${position.maxScrollExtent} field0=${firstField.evaluate().length} rect=${firstField.evaluate().isEmpty ? null : tester.getRect(firstField)}',
      );
      expect(frames.values.every((value) => value <= 4), isTrue);
      expect(
        find.byKey(const ValueKey('field-0')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
