import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row extends EditableGridRow {
  final edit = TextEditingController();
  final focus = FocusNode();

  @override
  void dispose() {
    edit.dispose();
    focus.dispose();
    super.dispose();
  }
}

const _actionKey = Key('ordinary-column-action');
const _inputKey = Key('ordinary-column-input');

class _Fixture {
  final row = _Row();
  final selected = <String>{};
  int calls = 0;

  Widget _action() => TextButton(
    key: _actionKey,
    onPressed: () => calls++,
    child: const Text('货品操作'),
  );

  Widget _input() => TextField(
    key: _inputKey,
    controller: row.edit,
    focusNode: row.focus,
    decoration: const InputDecoration(isDense: true),
  );

  Widget master({required bool selectable}) => MasterDataTableView<_Row>(
    requiredLeadingColumnKeys: const ['status', 'billNo'],
    embedded: true,
    showColumnChooser: false,
    showFullscreenToggle: false,
    selectable: selectable,
    idOf: (_) => 'row',
    selectedIds: selected,
    onSelectedIdsChanged: (next) {
      selected
        ..clear()
        ..addAll(next);
    },
    items: [row],
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    columns: [
      MasterColumnDef<_Row>(
        key: 'status',
        label: '状态',
        width: 210,
        minimumWidthOf: (_) => 210,
        value: (_) => '待办理',
      ),
      MasterColumnDef<_Row>(
        key: 'billNo',
        label: '单号',
        width: 180,
        minimumWidthOf: (_) => 180,
        value: (_) => 'DOC-1',
      ),
      MasterColumnDef<_Row>(
        key: 'action',
        label: '货品',
        width: 120,
        minimumWidthOf: (_) => 120,
        value: (_) => '货品操作',
        cellBuilder: (_, _) => _action(),
      ),
      MasterColumnDef<_Row>(
        key: 'input',
        label: '本次数量',
        width: 180,
        minimumWidthOf: (_) => 180,
        value: (_) => '',
        cellBuilder: (_, _) => _input(),
      ),
      MasterColumnDef<_Row>(
        key: 'tail',
        label: '参考',
        width: 1000,
        minimumWidthOf: (_) => 1000,
        value: (_) => '参考',
      ),
    ],
  );

  Widget editor(UtenEditableGridController<_Row> controller) =>
      UtenEditableGrid<_Row>(
        controller: controller,
        showAddRow: false,
        showRowDelete: false,
        showColumnSettings: false,
        selectable: true,
        initialPinnedColumnKeys: const {'status', 'billNo'},
        columns: [
          EditableGridColumn<_Row>(
            key: 'status',
            label: '状态',
            width: 210,
            minimumWidthOf: (_) => 210,
            textOf: (_) => '待办理',
            cellBuilder: (_, _) => const Text('待办理'),
          ),
          EditableGridColumn<_Row>(
            key: 'billNo',
            label: '单号',
            width: 180,
            minimumWidthOf: (_) => 180,
            textOf: (_) => 'DOC-1',
            cellBuilder: (_, _) => const Text('DOC-1'),
          ),
          EditableGridColumn<_Row>(
            key: 'action',
            label: '货品',
            width: 120,
            minimumWidthOf: (_) => 120,
            textOf: (_) => '货品操作',
            cellBuilder: (_, _) => _action(),
          ),
          EditableGridColumn<_Row>(
            key: 'input',
            label: '本次数量',
            width: 180,
            minimumWidthOf: (_) => 180,
            textOf: (_) => row.edit.text,
            cellBuilder: (_, _) => _input(),
          ),
          EditableGridColumn<_Row>(
            key: 'tail',
            label: '参考',
            width: 1000,
            minimumWidthOf: (_) => 1000,
            textOf: (_) => '参考',
            cellBuilder: (_, _) => const Text('参考'),
          ),
        ],
      );
}

Future<void> _mount(
  WidgetTester tester,
  Widget table, {
  double width = 390,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 700);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ListView(children: [table])),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scroll(WidgetTester tester, double offset) async {
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    if (state.position.axis == Axis.horizontal) {
      state.position.jumpTo(offset.clamp(0, state.position.maxScrollExtent));
    }
  }
  await tester.pumpAndSettle();
}

void main() {
  for (final selectable in [true, false]) {
    testWidgets(
      '390px ${selectable ? 'task' : 'history'} can operate ordinary columns behind a wide required prefix',
      (tester) async {
        final fixture = _Fixture();
        addTearDown(fixture.row.dispose);
        final semantics = tester.ensureSemantics();
        try {
          await _mount(tester, fixture.master(selectable: selectable));
          await _scroll(tester, 250);
          expect(find.byKey(_actionKey).hitTestable(), findsOneWidget);
          await tester.tap(find.byKey(_actionKey));
          await tester.pump();
          expect(fixture.calls, 1);
          expect(
            tester
                .getSemantics(find.byKey(_actionKey))
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isTrue,
          );
          expect(fixture.selected, isEmpty);
          await tester.ensureVisible(find.byKey(_inputKey));
          await tester.pumpAndSettle();
          expect(find.byKey(_inputKey).hitTestable(), findsOneWidget);
          await tester.tap(find.byKey(_inputKey));
          await tester.enterText(find.byKey(_inputKey), '17');
          expect(fixture.row.focus.hasFocus, isTrue);
          expect(fixture.row.edit.text, '17');
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'scrolled required pins adapt wide to narrow to wide without another scroll',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.row.dispose);
      await _mount(tester, fixture.master(selectable: true), width: 1200);
      await _scroll(tester, 250);
      expect(find.text('DOC-1').hitTestable(), findsOneWidget);
      expect(find.byKey(_actionKey).hitTestable(), findsNothing);
      tester.view.physicalSize = const Size(390, 700);
      await tester.pumpAndSettle();
      expect(find.byKey(_actionKey).hitTestable(), findsOneWidget);
      final checks = find
          .descendant(
            of: find.byKey(const ValueKey('row:row')),
            matching: find.byType(Checkbox),
          )
          .hitTestable();
      expect(checks, findsOneWidget);
      await tester.tap(checks);
      await tester.pump();
      expect(fixture.selected, {'row'});
      tester.view.physicalSize = const Size(1200, 700);
      await tester.pumpAndSettle();
      expect(find.text('DOC-1').hitTestable(), findsOneWidget);
      expect(find.byKey(_actionKey).hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '390px editor uses the same frozen budget for cells and focus reveal',
    (tester) async {
      final fixture = _Fixture();
      final controller = UtenEditableGridController<_Row>(
        initial: [fixture.row],
      );
      addTearDown(controller.dispose);
      await _mount(tester, fixture.editor(controller));
      await _scroll(tester, 250);
      expect(find.byKey(_actionKey).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_actionKey));
      expect(fixture.calls, 1);
      expect(controller.selectedRows, isEmpty);
      expect(find.byType(TextField), findsOneWidget);
      await tester.ensureVisible(find.byKey(_inputKey));
      await tester.pumpAndSettle();
      expect(find.byKey(_inputKey).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_inputKey));
      await tester.enterText(find.byKey(_inputKey), '18');
      expect(fixture.row.edit.text, '18');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow fallback preserves visible pinned text selection without duplicate copies',
    (tester) async {
      var clipboard = '';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final fixture = _Fixture();
      final controller = UtenEditableGridController<_Row>(
        initial: [fixture.row],
      );
      addTearDown(controller.dispose);
      await _mount(tester, fixture.editor(controller));
      await _scroll(tester, 250);
      await tester.ensureVisible(find.text('DOC-1').first);
      await tester.pumpAndSettle();
      final doc = find.text('DOC-1').hitTestable();
      expect(doc, findsOneWidget);
      final bounds = tester.getRect(doc);
      final gesture = await tester.startGesture(
        Offset(bounds.left + 1, bounds.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(bounds.left + 25, bounds.center.dy));
      await tester.pump();
      await gesture.moveTo(Offset(bounds.right + 2, bounds.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      Future<void> copy() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await copy();
      expect(clipboard, 'DOC-1');
      final area = find.descendant(
        of: find.byType(UtenEditableGrid<_Row>),
        matching: find.byType(SelectionArea),
      );
      tester.state<SelectionAreaState>(area).selectableRegion.selectAll();
      await tester.pump();
      await copy();
      expect('DOC-1'.allMatches(clipboard), hasLength(1));
      expect('待办理'.allMatches(clipboard), hasLength(1));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
