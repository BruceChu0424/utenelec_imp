import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_h_scroll_area.dart';
import 'package:uten_imp/components/data_display/uten_table_text_selection.dart';

class _Row extends EditableGridRow {
  _Row(this.name) : note = TextEditingController(text: 'Original input note');

  final String name;
  final TextEditingController note;

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }
}

Widget _page(
  UtenEditableGridController<_Row> controller, {
  bool editing = false,
  bool selectable = false,
  bool readOnlyInput = false,
  String? tableKey,
  bool showName = true,
  Set<String> hidden = const {},
  Set<String> pinned = const {},
}) => MaterialApp(
  home: Scaffold(
    body: SelectionArea(
      child: ListView(
        children: [
          const Text('Outside table'),
          UtenEditableGrid<_Row>(
            controller: controller,
            tableKey: tableKey,
            showAddRow: editing,
            showRowDelete: editing,
            selectable: selectable,
            showColumnSettings: false,
            initialHiddenColumnKeys: hidden,
            initialPinnedColumnKeys: pinned,
            stickyHeader: false,
            createBlankRow: () => _Row('New product'),
            cloneRow: (row) => _Row(row.name),
            columns: [
              if (showName)
                EditableGridColumn<_Row>(
                  key: 'name',
                  label: 'Product',
                  width: 200,
                  textOf: (row) => row.name,
                  cellBuilder: (_, row) => Text(row.name),
                ),
              EditableGridColumn<_Row>(
                key: 'detail',
                label: 'Details',
                width: 210,
                cellBuilder: (_, row) => const Row(
                  children: [
                    Icon(Icons.inventory_2_outlined, size: 16),
                    SizedBox(width: 4),
                    Text('Custom cell'),
                  ],
                ),
              ),
              EditableGridColumn<_Row>(
                key: 'note',
                label: 'Note',
                width: 230,
                textOf: (row) => row.note.text,
                cellBuilder: (_, row) => TextField(
                  key: ValueKey(row),
                  controller: row.note,
                  readOnly: readOnlyInput,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  ),
);

Finder get _bodyArea => find.descendant(
  of: find.byType(UtenEditableGrid<_Row>),
  matching: find.byType(SelectionArea),
);

Future<void> _selectText(WidgetTester tester, String text) async {
  final bounds = tester.getRect(find.text(text));
  final start = Offset(bounds.left + 1, bounds.center.dy);
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveTo(start + const Offset(25, 0));
  await tester.pump();
  await gesture.moveTo(Offset(bounds.right + 2, bounds.center.dy));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

Future<void> _copyShortcut(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pump();
}

void _testWindows(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

void main() {
  var clipboard = '';

  setUp(() {
    clipboard = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': clipboard};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  _testWindows(
    'plain and custom cells share a stable body-only selection region',
    (tester) async {
      final controller = UtenEditableGridController<_Row>(
        initial: [_Row('Alpha goods')],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(_page(controller, selectable: true));
      await tester.pumpAndSettle();

      final areaState = tester.state<SelectionAreaState>(_bodyArea);
      final bodyRegistrar = SelectionContainer.maybeOf(
        tester.element(find.text('Alpha goods')),
      );
      expect(bodyRegistrar, isNotNull);
      expect(
        SelectionContainer.maybeOf(tester.element(find.text('Custom cell'))),
        same(bodyRegistrar),
      );
      expect(
        SelectionContainer.maybeOf(tester.element(find.text('Product'))),
        isNull,
      );
      expect(
        SelectionContainer.maybeOf(tester.element(find.text('Outside table'))),
        isNot(same(bodyRegistrar)),
      );

      controller.selectAll();
      await tester.pump();
      expect(tester.state<SelectionAreaState>(_bodyArea), same(areaState));
      controller.addRow(_Row('Beta goods'));
      await tester.pumpAndSettle();
      expect(tester.state<SelectionAreaState>(_bodyArea), same(areaState));
      expect(tester.takeException(), isNull);
    },
  );

  _testWindows(
    'mouse text drag and Ctrl+C copy text without toggling the row',
    (tester) async {
      final controller = UtenEditableGridController<_Row>(
        initial: [_Row('Alpha goods')],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(_page(controller, selectable: true));
      await tester.pumpAndSettle();

      await _selectText(tester, 'Alpha goods');
      await _copyShortcut(tester);
      expect((await Clipboard.getData('text/plain'))?.text, 'Alpha goods');
      expect(controller.selectedCount, 0);

      await tester.tap(find.text('Alpha goods'));
      await tester.pump();
      expect(controller.selectedCount, 1);
    },
  );

  _testWindows(
    'row menu copies captured selected text and keeps row operations',
    (tester) async {
      final controller = UtenEditableGridController<_Row>(
        initial: [_Row('Alpha goods')],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(_page(controller, editing: true));
      await tester.pumpAndSettle();

      await _selectText(tester, 'Alpha goods');
      await _rightClick(tester, find.text('Alpha goods'));
      expect(find.text('复制所选文字'), findsOneWidget);
      expect(find.text('复制选中 (1)'), findsOneWidget);
      expect(find.text('粘贴'), findsOneWidget);
      expect(find.text('删除选中 (1)'), findsOneWidget);
      await tester.tap(find.text('复制所选文字'));
      await tester.pump();
      expect((await Clipboard.getData('text/plain'))?.text, 'Alpha goods');
      expect(controller.selectedCount, 1);

      controller.addRow(_Row('Beta goods'));
      await tester.pumpAndSettle();
      await _rightClick(tester, find.text('Beta goods'));
      expect(find.text('复制所选文字'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  _testWindows(
    'selection crosses display cells and rows without copying chrome',
    (tester) async {
      final controller = UtenEditableGridController<_Row>(
        initial: [_Row('Alpha goods'), _Row('Beta goods')],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(_page(controller));
      await tester.pumpAndSettle();
      final first = tester.getRect(find.text('Alpha goods'));
      final last = tester.getRect(find.text('Beta goods'));
      final gesture = await tester.startGesture(
        Offset(first.left + 1, first.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(first.right, first.center.dy));
      await tester.pump();
      await gesture.moveTo(Offset(last.right + 2, last.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await _copyShortcut(tester);
      final copied = (await Clipboard.getData('text/plain'))!.text!;
      expect(copied, contains('Alpha goods'));
      expect(copied, contains('Custom cell'));
      expect(copied, contains('Beta goods'));
      expect(copied, isNot(contains('Product')));
      expect(copied, isNot(contains('Outside table')));
      expect(copied, isNot(contains('Original input note')));
    },
  );

  _testWindows('changing controllers clears text from the previous entity', (
    tester,
  ) async {
    final previous = UtenEditableGridController<_Row>(
      initial: [_Row('Alpha goods')],
    );
    final next = UtenEditableGridController<_Row>(
      initial: [_Row('Beta goods')],
    );
    addTearDown(previous.dispose);
    addTearDown(next.dispose);
    await tester.pumpWidget(_page(previous, editing: true));
    await tester.pumpAndSettle();
    final bodyState = tester.state<SelectionAreaState>(_bodyArea);
    await _selectText(tester, 'Alpha goods');
    await tester.pumpWidget(_page(next, editing: true));
    await tester.pumpAndSettle();
    expect(tester.state<SelectionAreaState>(_bodyArea), same(bodyState));
    await _rightClick(tester, find.text('Beta goods'));
    expect(find.text('复制所选文字'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final removeColumn in [false, true]) {
    _testWindows(
      'hidden or revoked columns clear selection remove=$removeColumn',
      (tester) async {
        final controller = UtenEditableGridController<_Row>(
          initial: [_Row('Alpha goods')],
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(_page(controller, editing: true));
        await tester.pumpAndSettle();
        final bodyState = tester.state<SelectionAreaState>(_bodyArea);
        await _selectText(tester, 'Alpha goods');
        await tester.pumpWidget(
          _page(
            controller,
            editing: true,
            showName: !removeColumn,
            hidden: removeColumn ? const {} : const {'name'},
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Alpha goods'), findsNothing);
        expect(tester.state<SelectionAreaState>(_bodyArea), same(bodyState));
        await _rightClick(tester, find.text('Custom cell'));
        expect(find.text('复制所选文字'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testWindows('a copy menu open during row changes cannot copy stale text', (
    tester,
  ) async {
    final controller = UtenEditableGridController<_Row>(
      initial: [_Row('Alpha goods')],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_page(controller, editing: true));
    await tester.pumpAndSettle();
    await _selectText(tester, 'Alpha goods');
    await _rightClick(tester, find.text('Alpha goods'));
    expect(find.text('复制所选文字'), findsOneWidget);
    controller.addRow(_Row('Beta goods'));
    await tester.pumpAndSettle();
    await Clipboard.setData(const ClipboardData(text: 'Current clipboard'));
    await tester.tap(find.text('复制所选文字'));
    await tester.pump();
    expect((await Clipboard.getData('text/plain'))?.text, 'Current clipboard');
  });

  _testWindows(
    'post-frame row swaps clear safely and invalidate an already open copy action',
    (tester) async {
      final previous = _Row('Alpha goods');
      final next = _Row('Beta goods');
      final controller = UtenEditableGridController<_Row>(initial: [previous]);
      addTearDown(() {
        final owned = controller.rows.toSet();
        controller.dispose();
        if (!owned.contains(previous)) previous.dispose();
        if (!owned.contains(next)) next.dispose();
      });
      await tester.pumpWidget(_page(controller, editing: true));
      await tester.pumpAndSettle();
      final bodyState = tester.state<SelectionAreaState>(_bodyArea);
      await _selectText(tester, 'Alpha goods');
      await _rightClick(tester, find.text('Alpha goods'));
      expect(find.text('复制所选文字'), findsOneWidget);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.swapRows([previous, next]);
        controller.swapRows([]);
        controller.swapRows([next]);
      });
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();
      await Clipboard.setData(const ClipboardData(text: 'Current clipboard'));
      await tester.tap(find.text('复制所选文字'));
      await tester.pumpAndSettle();
      expect(
        (await Clipboard.getData('text/plain'))?.text,
        'Current clipboard',
      );
      expect(controller.rows, [next]);
      expect(find.text('Alpha goods'), findsNothing);
      expect(find.text('Beta goods'), findsOneWidget);
      expect(tester.state<SelectionAreaState>(_bodyArea), same(bodyState));
      expect(tester.takeException(), isNull);
      await _selectText(tester, 'Beta goods');
      await _copyShortcut(tester);
      expect((await Clipboard.getData('text/plain'))?.text, 'Beta goods');
      expect(tester.takeException(), isNull);
    },
  );

  _testWindows(
    'native copy cannot use old selected text while a frame clear is pending',
    (tester) async {
      final previous = _Row('Alpha goods');
      final next = _Row('Beta goods');
      final controller = UtenEditableGridController<_Row>(initial: [previous]);
      addTearDown(() {
        final owned = controller.rows.toSet();
        controller.dispose();
        if (!owned.contains(previous)) previous.dispose();
        if (!owned.contains(next)) next.dispose();
      });
      await tester.pumpWidget(_page(controller, editing: true));
      await tester.pumpAndSettle();
      final area = tester.state<SelectionAreaState>(_bodyArea);
      await _selectText(tester, 'Alpha goods');
      final focus = FocusManager.instance.primaryFocus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.swapRows([next]);
      });
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();
      await Clipboard.setData(const ClipboardData(text: 'Current clipboard'));
      await _copyShortcut(tester);
      await tester.pumpAndSettle();
      expect(
        (await Clipboard.getData('text/plain'))?.text,
        'Current clipboard',
      );
      expect(tester.state<SelectionAreaState>(_bodyArea), same(area));
      expect(FocusManager.instance.primaryFocus, same(focus));
      await _selectText(tester, 'Beta goods');
      await _copyShortcut(tester);
      expect((await Clipboard.getData('text/plain'))?.text, 'Beta goods');
      expect(tester.takeException(), isNull);
    },
  );

  _testWindows(
    'frozen cells copy once and keep native input state while scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(520, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = UtenEditableGridController<_Row>(
        initial: [_Row('Alpha goods')],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _page(controller, pinned: const {'name', 'note'}),
      );
      await tester.pumpAndSettle();
      final inputState = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final horizontal = tester
          .widget<UtenHScrollArea>(find.byType(UtenHScrollArea))
          .controller!;
      horizontal.jumpTo(100);
      await tester.pumpAndSettle();
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(inputState),
      );
      expect(find.text('Alpha goods'), findsNWidgets(2));
      await tester.tap(find.text('Alpha goods').last);
      tester.state<SelectionAreaState>(_bodyArea).selectableRegion.selectAll();
      await tester.pump();
      await _copyShortcut(tester);
      final copied = (await Clipboard.getData('text/plain'))!.text!;
      expect('Alpha goods'.allMatches(copied), hasLength(1));
      horizontal.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(inputState),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final readOnly in [false, true]) {
    _testWindows('native input selection and copy survive readOnly=$readOnly', (
      tester,
    ) async {
      final row = _Row('Alpha goods');
      final controller = UtenEditableGridController<_Row>(initial: [row]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _page(controller, editing: true, readOnlyInput: readOnly),
      );
      await tester.pumpAndSettle();
      await _selectText(tester, 'Alpha goods');
      await tester.tap(find.byType(TextField));
      row.note.selection = const TextSelection(baseOffset: 0, extentOffset: 8);
      await tester.pump();
      await _copyShortcut(tester);
      expect((await Clipboard.getData('text/plain'))?.text, 'Original');
      expect(row.note.text, 'Original input note');
      await Clipboard.setData(const ClipboardData(text: 'Reset clipboard'));
      await _rightClick(tester, find.byType(TextField));
      expect(find.text('复制所选文字'), findsOneWidget);
      await tester.tap(find.text('复制所选文字'));
      await tester.pump();
      expect((await Clipboard.getData('text/plain'))?.text, 'Original');
      expect(tester.takeException(), isNull);
    });
  }

  _testWindows('copy action ignores focused inputs outside the owning table', (
    tester,
  ) async {
    final selection = UtenTableTextSelection();
    final outside = TextEditingController(text: 'Other table text');
    addTearDown(outside.dispose);
    late BuildContext tableContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(controller: outside),
              Builder(
                builder: (context) {
                  tableContext = context;
                  return const Text('This table');
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    outside.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();
    expect(selection.copyMenuEntries(tableContext), isEmpty);
  });

  _testWindows(
    'copy action excludes obscured input even with a valid selection',
    (tester) async {
      final selection = UtenTableTextSelection();
      final obscured = TextEditingController(text: 'Secret');
      addTearDown(obscured.dispose);
      late BuildContext tableContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                tableContext = context;
                return TextField(controller: obscured, obscureText: true);
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      obscured.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
      await tester.pump();
      expect(selection.copyMenuEntries(tableContext), isEmpty);
    },
  );

  _testWindows('touch long press still opens the editable row menu', (
    tester,
  ) async {
    final controller = UtenEditableGridController<_Row>(
      initial: [_Row('Alpha goods')],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_page(controller, editing: true));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Alpha goods'));
    await tester.pump();
    expect(find.text('在上方插入空行'), findsOneWidget);
    expect(find.text('复制所选文字'), findsNothing);
  });
}
