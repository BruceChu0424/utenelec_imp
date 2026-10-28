import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';
import 'package:uten_imp/features/basic_data/pages/goods_import_preview_page.dart';

const _rows = [
  GoodsImportProblemRow(
    rowNum: 2,
    code: 'DUPLICATE',
    name: '',
    categoryPath: '成品 / 测试',
    categorySegments: ['成品', '测试'],
    cells: {'cNumber': 'ORIGINAL'},
  ),
  GoodsImportProblemRow(
    rowNum: 3,
    code: 'VALID',
    name: '正常货品',
    categoryPath: '成品 / 测试',
    categorySegments: ['成品', '测试'],
    cells: {'cNumber': 'MODEL'},
  ),
];

GoodsImportReport _report(GoodsImportCorrections corrections) {
  final rows = [
    for (final row in _rows)
      GoodsImportProblemRow(
        rowNum: row.rowNum,
        code: corrections[row.rowNum]?['code'] ?? row.code,
        name: corrections[row.rowNum]?['name'] ?? row.name,
        categoryPath: row.categoryPath,
        categorySegments: row.categorySegments,
        cells: {...row.cells, ...?corrections[row.rowNum]},
      ),
  ];
  final errors = [
    if (rows.first.name.isEmpty)
      const GoodsImportError(rowNum: 2, column: '货品名称', message: '请填写货品名称'),
    if (rows.first.code == 'DUPLICATE')
      const GoodsImportError(rowNum: 2, column: '编号', message: '编号已存在，请更换编号'),
  ];
  return GoodsImportReport(
    totalRows: 3,
    dataRows: 2,
    errors: errors,
    willCreateCategories: const [],
    willCreateColors: const [],
    willCreateUnits: const [],
    readyToImport: errors.isEmpty ? 2 : 1,
    restorableRows: 0,
    planId: 'preview',
    readyRowNums: [if (errors.isEmpty) 2, 3],
    previewRows: rows,
  );
}

Finder _field(String field, int row) =>
    find.byKey(ValueKey('goods-import-$field-$row'));

GoodsImportReport _separateErrorReport(GoodsImportCorrections corrections) {
  const source = [
    GoodsImportProblemRow(
      rowNum: 2,
      code: 'VALID-2',
      name: '',
      categoryPath: '成品 / 测试',
      categorySegments: ['成品', '测试'],
    ),
    GoodsImportProblemRow(
      rowNum: 3,
      code: 'FL001R',
      name: '重号货品',
      categoryPath: '成品 / 测试',
      categorySegments: ['成品', '测试'],
    ),
    GoodsImportProblemRow(
      rowNum: 4,
      code: 'VALID-4',
      name: '正常货品',
      categoryPath: '成品 / 测试',
      categorySegments: ['成品', '测试'],
    ),
  ];
  final rows = [
    for (final row in source)
      GoodsImportProblemRow(
        rowNum: row.rowNum,
        code: corrections[row.rowNum]?['code'] ?? row.code,
        name: corrections[row.rowNum]?['name'] ?? row.name,
        categoryPath: row.categoryPath,
        categorySegments: row.categorySegments,
        cells: {...row.cells, ...?corrections[row.rowNum]},
      ),
  ];
  final errors = [
    if (rows[0].name.isEmpty)
      const GoodsImportError(rowNum: 2, column: '货品名称', message: '请填写货品名称'),
    if (rows[1].code == 'FL001R')
      const GoodsImportError(rowNum: 3, column: '编号', message: '编号已存在，请更换编号'),
  ];
  final invalid = errors.map((error) => error.rowNum).toSet();
  final ready = [
    for (final row in rows)
      if (!invalid.contains(row.rowNum)) row.rowNum,
  ];
  return GoodsImportReport(
    totalRows: 4,
    dataRows: 3,
    errors: errors,
    willCreateCategories: const [],
    willCreateColors: const [],
    willCreateUnits: const [],
    readyToImport: ready.length,
    restorableRows: 0,
    planId: 'sequential',
    readyRowNums: ready,
    previewRows: rows,
  );
}

Finder _editable(String field, int row) => find.descendant(
  of: _field(field, row),
  matching: find.byType(EditableText),
);

void _expectTextbox(
  WidgetTester tester,
  String field,
  int row,
  EditableTextState original,
  int originalNode,
) {
  final current = tester.state<EditableTextState>(_editable(field, row));
  expect(current, same(original));
  expect(current.widget.focusNode.hasPrimaryFocus, isTrue);
  expect(tester.testTextInput.hasAnyClients, isTrue);
  final node = tester.getSemantics(_editable(field, row));
  final data = node.getSemanticsData();
  final children = <String>[];
  node.visitChildren((child) {
    children.add('${child.id}:${child.getSemanticsData().label}');
    return true;
  });
  debugPrint(
    'PREVIEW_TEXTBOX $field/$row original=$originalNode node=${node.id} focused=${data.flagsCollection.isFocused} label=${data.label} hint=${data.hint} value=${data.value} children=$children traversalOwner=${data.traversalParentIdentifier}',
  );
  expect(data.flagsCollection.isTextField, isTrue);
  expect(data.flagsCollection.isFocused, ui.Tristate.isTrue);
  expect(
    node.id,
    originalNode,
    reason:
        'A visible tooltip or old/new review text must not change the native textbox identity.',
  );
  expect(
    children,
    isEmpty,
    reason: 'The real preview textbox must not own tooltip overlay text.',
  );
  expect(
    data.traversalParentIdentifier,
    isNull,
    reason:
        'A native textbox must not own an OverlayPortal tooltip through virtual traversal children (Web aria-owns).',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'repairing a name then clearing another erroneous code keeps the second keyboard client',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final drafts = <GoodsImportCorrections>[];
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            home: GoodsImportPreviewPage(
              report: _separateErrorReport({}),
              filename: '三个导入行.xlsx',
              mode: GoodsImportMode.mixed,
              detect: (corrections, _) async =>
                  _separateErrorReport(corrections),
              onDraftChanged: (corrections, _) => drafts.add(corrections),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('可导入 1 条'), findsOneWidget);
        await mouse.addPointer(location: Offset.zero);
        for (final step in [('name', 2, '修正名称'), ('code', 3, '')]) {
          await tester.ensureVisible(_field(step.$1, step.$2));
          await tester.pumpAndSettle();
          final original = tester.state<EditableTextState>(
            _editable(step.$1, step.$2),
          );
          final id = tester.getSemantics(_editable(step.$1, step.$2)).id;
          final target = tester.getCenter(_field(step.$1, step.$2));
          await mouse.moveTo(target);
          await tester.pump(const Duration(milliseconds: 350));
          await mouse.down(target);
          await mouse.up();
          await tester.pump(const Duration(milliseconds: 250));
          _expectTextbox(tester, step.$1, step.$2, original, id);
          tester.testTextInput.enterText(step.$3);
          await tester.pump(const Duration(milliseconds: 800));
          await tester.pumpAndSettle();
          _expectTextbox(tester, step.$1, step.$2, original, id);
          expect(drafts.last[step.$2]![step.$1], step.$3);
          expect(original.widget.controller.text, step.$3);
          expect(
            find.text('可导入 ${step.$1 == 'name' ? 2 : 3} 条'),
            findsOneWidget,
          );
        }
        expect(find.text('自动编号'), findsAtLeastNWidgets(1));
        expect(tester.takeException(), isNull);
      } finally {
        await mouse.removePointer();
        semantics.dispose();
      }
    },
  );
  for (final field in ['name', 'code', 'cNumber']) {
    for (final semanticFocus in [false, true]) {
      testWidgets(
        'real preview $field uses a live stable textbox semanticFocus=$semanticFocus',
        (tester) async {
          tester.view.physicalSize = const Size(1600, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final semantics = tester.ensureSemantics();
          final drafts = <GoodsImportCorrections>[];
          TestGesture? mouse;
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildLightTheme().copyWith(
                  platform: TargetPlatform.windows,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
                home: GoodsImportPreviewPage(
                  report: _report({}),
                  filename: '错误修正.xlsx',
                  mode: GoodsImportMode.mixed,
                  detect: (corrections, _) async => _report(corrections),
                  onDraftChanged: (corrections, _) => drafts.add(corrections),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.ensureVisible(_field(field, 2));
            await tester.pumpAndSettle();
            final original = tester.state<EditableTextState>(
              _editable(field, 2),
            );
            final originalNode = tester.getSemantics(_editable(field, 2)).id;
            if (semanticFocus) {
              tester.binding.renderViews.single.owner!.semanticsOwner!
                  .performAction(originalNode, ui.SemanticsAction.focus);
            } else {
              mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
              final target = tester.getCenter(_field(field, 2));
              await mouse.addPointer(location: Offset.zero);
              await mouse.moveTo(target);
              await tester.pump(const Duration(milliseconds: 350));
              if (field == 'name' || field == 'code') {
                expect(
                  find.text(field == 'name' ? '请填写货品名称' : '编号已存在，请更换编号'),
                  findsOneWidget,
                  reason:
                      'Unfocused error details must remain available on hover.',
                );
              }
              await mouse.down(target);
              await mouse.up();
            }
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump();
            if (field == 'name' || field == 'code') {
              final error = field == 'name' ? '请填写货品名称' : '编号已存在，请更换编号';
              expect(
                find.text(error),
                findsNothing,
                reason:
                    'Focus must not open or retain an overlay while the native textbox activates.',
              );
              expect(
                tester
                    .getSemantics(_editable(field, 2))
                    .getSemanticsData()
                    .hint,
                error,
                reason:
                    'The error must remain on the textbox for the Web aria-description.',
              );
            }
            _expectTextbox(tester, field, 2, original, originalNode);
            tester.testTextInput.enterText('KEYBOARD-$field');
            await tester.pump(const Duration(milliseconds: 800));
            await tester.pumpAndSettle();
            _expectTextbox(tester, field, 2, original, originalNode);
            expect(drafts.last[2]![field], 'KEYBOARD-$field');
            expect(original.widget.controller.text, 'KEYBOARD-$field');
            if (field == 'code') {
              tester.testTextInput.enterText('');
              await tester.pump(const Duration(milliseconds: 800));
              await tester.pumpAndSettle();
              _expectTextbox(tester, field, 2, original, originalNode);
              expect(drafts.last[2]!['code'], '');
              expect(original.widget.controller.text, isEmpty);
              expect(find.text('自动编号'), findsAtLeastNWidgets(1));
            }
            expect(tester.takeException(), isNull);
          } finally {
            await mouse?.removePointer();
            semantics.dispose();
          }
        },
      );
    }
  }
}
