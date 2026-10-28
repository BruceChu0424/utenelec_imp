import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:ui' as ui;
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_hints.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Fields {
  final controllers = {
    'name': TextEditingController(),
    'code': TextEditingController(text: 'DUPLICATE'),
    'model': TextEditingController(text: 'MODEL'),
  };
  final errors = ValueNotifier(<String, String?>{
    'name': '请填写货品名称',
    'code': '编号已存在，请更换编号',
  });
  final changes = <(String, String)>[];
  bool clearErrorOnInput = false;

  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    errors.dispose();
  }
}

Future<void> _pumpFields(
  WidgetTester tester,
  _Fields fields, {
  bool inTable = true,
}) async {
  tester.view.physicalSize = const Size(1200, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final selected = ValueNotifier(<String>{});
  addTearDown(selected.dispose);
  Widget input(String key) => Semantics(
    label: key,
    child: UtenInput(
      key: ValueKey('input-$key'),
      controller: fields.controllers[key],
      errorMessage: fields.errors.value[key],
      onChanged: (value) {
        fields.changes.add((key, value));
        if (fields.clearErrorOnInput) {
          fields.errors.value = {...fields.errors.value}..remove(key);
        }
      },
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: fields.errors,
          builder: (_, _, _) => inTable
              ? ValueListenableBuilder(
                  valueListenable: selected,
                  builder: (_, ids, _) => MasterDataTableView<String>(
                    columns: [
                      for (final key in fields.controllers.keys)
                        MasterColumnDef(
                          key: key,
                          label: key,
                          width: 240,
                          minimumWidthOf: (_) => 100,
                          value: (_) => fields.controllers[key]!.text,
                          cellBuilderHandlesSemantics: true,
                          cellBuilder: (_, _) => input(key),
                        ),
                    ],
                    items: const ['one'],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: true,
                    idOf: (row) => row,
                    selectedIds: ids,
                    onSelectedIdsChanged: (next) => selected.value = next,
                    showFullscreenToggle: false,
                  ),
                )
              : Row(
                  children: [
                    for (final key in fields.controllers.keys)
                      Expanded(
                        child: UtenTableCellInputTheme(
                          child: UtenTableCellHints(child: input(key)),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _editable(String key) => find.descendant(
  of: find.byKey(ValueKey('input-$key')),
  matching: find.byType(EditableText),
);

Future<void> _pointAtAndClick(
  WidgetTester tester,
  String key,
  PointerDeviceKind kind,
) async {
  final target = tester.getCenter(find.byKey(ValueKey('input-$key')));
  final pointer = await tester.createGesture(kind: kind);
  await pointer.addPointer(location: Offset.zero);
  await pointer.moveTo(target);
  await tester.pump(const Duration(milliseconds: 350));
  await pointer.down(target);
  await pointer.up();
  await tester.pump(const Duration(milliseconds: 200));
  await pointer.removePointer();
  await tester.pump();
}

void _expectLiveKeyboardClient(
  WidgetTester tester,
  String key,
  EditableTextState original, {
  int? originalSemanticsId,
}) {
  final state = tester.state<EditableTextState>(_editable(key));
  expect(
    state,
    same(original),
    reason: 'Hint layers must retain the original EditableTextState.',
  );
  if (originalSemanticsId != null) {
    final node = tester.getSemantics(_editable(key));
    final data = node.getSemanticsData();
    final children = <String>[];
    node.visitChildren((child) {
      children.add('${child.id}:${child.getSemanticsData().label}');
      return true;
    });
    debugPrint(
      'SEMANTIC_NODE $key original=$originalSemanticsId current=${node.id} value=${data.value} hint=${data.hint} focused=${data.flagsCollection.isFocused} children=$children',
    );
    expect(data.flagsCollection.isTextField, isTrue);
    expect(
      data.flagsCollection.isFocused,
      ui.Tristate.isTrue,
      reason:
          'The native textbox node itself must carry focus for Flutter Web to activate its input bridge.',
    );
    expect(
      node.id,
      originalSemanticsId,
      reason:
          'The native textbox semantic identity must not change when its tooltip appears.',
    );
    expect(
      children,
      isEmpty,
      reason:
          'Tooltip content must not become owned children of a native textbox.',
    );
  }
  expect(
    state.widget.focusNode.hasPrimaryFocus,
    isTrue,
    reason: 'A pointer click must focus the actual editor.',
  );
  expect(FocusManager.instance.primaryFocus, same(state.widget.focusNode));
  expect(tester.testTextInput.isRegistered, isTrue);
  expect(
    tester.testTextInput.hasAnyClients,
    isTrue,
    reason: 'The real keyboard client must stay connected.',
  );
}

void main() {
  testWidgets(
    'focused error keeps its hint without a popup and blur restores hover disclosure',
    (tester) async {
      final fields = _Fields();
      addTearDown(fields.dispose);
      final semantics = tester.ensureSemantics();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      try {
        await _pumpFields(tester, fields);
        final original = tester.state<EditableTextState>(_editable('name'));
        final id = tester.getSemantics(_editable('name')).id;
        await _pointAtAndClick(tester, 'name', PointerDeviceKind.mouse);
        _expectLiveKeyboardClient(
          tester,
          'name',
          original,
          originalSemanticsId: id,
        );
        expect(find.text('请填写货品名称'), findsNothing);
        expect(
          tester.getSemantics(_editable('name')).getSemanticsData().hint,
          '请填写货品名称',
        );
        tester.testTextInput.enterText('仍待服务端检查');
        await tester.pumpAndSettle();
        expect(find.text('请填写货品名称'), findsNothing);
        original.widget.focusNode.unfocus();
        await tester.pumpAndSettle();
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('input-name'))),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('请填写货品名称'), findsOneWidget);
        expect(
          tester.state<EditableTextState>(_editable('name')),
          same(original),
        );
        expect(tester.getSemantics(_editable('name')).id, id);
        expect(tester.takeException(), isNull);
      } finally {
        await mouse.removePointer();
        semantics.dispose();
      }
    },
  );

  for (final key in ['name', 'code', 'model']) {
    testWidgets(
      'browser-equivalent semantic focus connects the real $key keyboard client',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final fields = _Fields();
        addTearDown(fields.dispose);
        try {
          await _pumpFields(tester, fields);
          final original = tester.state<EditableTextState>(_editable(key));
          final node = tester.getSemantics(_editable(key));
          final data = node.getSemanticsData();
          debugPrint(
            'SEMANTIC_FOCUS $key id=${node.id} value=${data.value} hint=${data.hint} flags=${data.flagsCollection} actions=${data.actions}',
          );
          tester.binding.renderViews.single.owner!.semanticsOwner!
              .performAction(node.id, ui.SemanticsAction.focus);
          await tester.pumpAndSettle();
          _expectLiveKeyboardClient(
            tester,
            key,
            original,
            originalSemanticsId: node.id,
          );
          tester.testTextInput.enterText('语义键盘-$key');
          await tester.pumpAndSettle();
          expect(fields.controllers[key]!.text, '语义键盘-$key');
          expect(fields.changes, [(key, '语义键盘-$key')]);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    for (final key in ['name', 'code', 'model']) {
      testWidgets(
        '$kind pointer opens a live keyboard client for $key without enterText focus shortcuts',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final fields = _Fields();
          addTearDown(fields.dispose);
          try {
            await _pumpFields(tester, fields);
            final original = tester.state<EditableTextState>(_editable(key));
            final originalSemanticsId = tester.getSemantics(_editable(key)).id;
            await _pointAtAndClick(tester, key, kind);
            _expectLiveKeyboardClient(
              tester,
              key,
              original,
              originalSemanticsId: originalSemanticsId,
            );
            tester.testTextInput.enterText('键盘输入-$key');
            await tester.pumpAndSettle();
            _expectLiveKeyboardClient(
              tester,
              key,
              original,
              originalSemanticsId: originalSemanticsId,
            );
            expect(fields.controllers[key]!.text, '键盘输入-$key');
            expect(fields.changes, [(key, '键盘输入-$key')]);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  for (final inTable in [false, true]) {
    testWidgets(
      'adding and clearing an error keeps pointer focus and keyboard connection table=$inTable',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final fields = _Fields()..errors.value = {};
        addTearDown(fields.dispose);
        try {
          await _pumpFields(tester, fields, inTable: inTable);
          final original = tester.state<EditableTextState>(_editable('name'));
          final originalSemanticsId = tester.getSemantics(_editable('name')).id;
          await _pointAtAndClick(tester, 'name', PointerDeviceKind.mouse);
          _expectLiveKeyboardClient(
            tester,
            'name',
            original,
            originalSemanticsId: originalSemanticsId,
          );
          fields.errors.value = {'name': '请填写货品名称'};
          await tester.pumpAndSettle();
          _expectLiveKeyboardClient(
            tester,
            'name',
            original,
            originalSemanticsId: originalSemanticsId,
          );
          fields.clearErrorOnInput = true;
          tester.testTextInput.enterText('修正名称');
          await tester.pumpAndSettle();
          _expectLiveKeyboardClient(
            tester,
            'name',
            original,
            originalSemanticsId: originalSemanticsId,
          );
          expect(fields.controllers['name']!.text, '修正名称');
          expect(fields.changes, [('name', '修正名称')]);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
}
