import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/data_display/uten_review_input_cell.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/goods_import_preview_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

import '../../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_IMPORT_PREVIEW_SCREENSHOT');
final _captureKey = GlobalKey();
const _source = [
  GoodsImportProblemRow(
    rowNum: 2,
    code: '001',
    name: '单联开关',
    categoryPath: '成品 / V3 / 白色',
    cells: {'code': '001', 'name': '单联开关', 'categoryPath': '成品 / V3 / 白色'},
  ),
  GoodsImportProblemRow(
    rowNum: 3,
    code: '002',
    name: '双联开关',
    categoryPath: '成品 / V3 / 黑色',
    cells: {'code': '002', 'name': '双联开关', 'categoryPath': '成品 / V3 / 黑色'},
  ),
  GoodsImportProblemRow(
    rowNum: 4,
    code: '003',
    name: '铜端子',
    categoryPath: '原材料 / 铜件',
    cells: {'code': '003', 'name': '铜端子', 'categoryPath': '原材料 / 铜件'},
  ),
];

const _nameConflict = GoodsImportReviewRow(
  rowKey: 'goods:2',
  rowNum: 2,
  code: '001',
  name: '单联开关',
  categoryPath: '成品 / V3 / 白色',
  matchType: 'UUID',
  changes: [
    GoodsImportChange(
      field: 'name',
      label: '货品名称',
      oldValue: '原名称',
      newValue: '单联开关',
      kind: 'CONFLICT',
    ),
  ],
);

GoodsImportReport _report({
  GoodsImportCorrections corrections = const {},
  Set<int> excluded = const {},
  Set<int> bad = const {},
  List<GoodsImportReviewRow> changes = const [],
  List<GoodsImportError> extraErrors = const [],
  List<GoodsImportProblemRow> source = _source,
}) => GoodsImportReport(
  totalRows: source.length + 1,
  dataRows: source.length,
  errors: [
    ...extraErrors,
    for (final row in bad.difference(excluded))
      GoodsImportError(rowNum: row, column: '货品名称', message: '请填写货品名称'),
  ],
  willCreateCategories: const [],
  willCreateColors: const [],
  willCreateUnits: const [],
  readyToImport: source
      .where(
        (row) => !excluded.contains(row.rowNum) && !bad.contains(row.rowNum),
      )
      .length,
  restorableRows: 0,
  planId: 'plan:${excluded.join(",")}',
  readyRowNums: [
    for (final row in source)
      if (!excluded.contains(row.rowNum) && !bad.contains(row.rowNum))
        row.rowNum,
  ],
  previewRows: [
    for (final row in source)
      if (!excluded.contains(row.rowNum))
        GoodsImportProblemRow(
          rowNum: row.rowNum,
          code: corrections[row.rowNum]?['code'] ?? row.code,
          name: corrections[row.rowNum]?['name'] ?? row.name,
          categoryPath:
              corrections[row.rowNum]?['categoryPath'] ?? row.categoryPath,
          cells: {...row.cells, ...?corrections[row.rowNum]},
          categorySegments:
              corrections[row.rowNum]?.containsKey('categoryPath') == true
              ? const []
              : row.categorySegments,
        ),
  ],
  reviewRows: changes.where((row) => !excluded.contains(row.rowNum)).toList(),
  conflictRows: changes
      .where((row) => row.hasConflicts && !excluded.contains(row.rowNum))
      .length,
);

class _Result {
  GoodsImportPreviewDecision? value;
}

Future<void> _open(
  WidgetTester tester, {
  GoodsImportReport? report,
  GoodsImportMode mode = GoodsImportMode.createOnly,
  GoodsImportPreviewDetector? detect,
  _Result? result,
  void Function(GoodsImportCorrections, Set<int>)? onDraft,
  Size size = const Size(1440, 900),
  double scale = 1,
  bool dark = false,
  double zoom = 1,
  bool inheritedPageGutter = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final theme = (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
    platform: TargetPlatform.windows,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: _capture ? auditScreenshotTheme(theme) : theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: UtenDisplayZoomBox(
          fontFactor: zoom,
          child: RepaintBoundary(key: _captureKey, child: child!),
        ),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final value = await Navigator.of(context)
                  .push<GoodsImportPreviewDecision>(
                    MaterialPageRoute(
                      builder: (_) {
                        final page = GoodsImportPreviewPage(
                          report: report ?? _report(),
                          filename: 'V3系列导入.xlsx',
                          mode: mode,
                          detect:
                              detect ??
                              (corrections, excluded) async => _report(
                                corrections: corrections,
                                excluded: excluded,
                              ),
                          onDraftChanged: onDraft ?? (_, _) {},
                        );
                        return inheritedPageGutter
                            ? UtenContentContainer.wide(
                                selectable: false,
                                child: page,
                              )
                            : page;
                      },
                    ),
                  );
              if (result != null) result.value = value;
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

MasterDataTableView<GoodsImportProblemRow> _table(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('goods-import-preview-table')));
UtenCategoryTreeView<ProductCategoryNode> _tree(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('goods-import-category-tree')));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final scenario in [
    (const Size(1440, 900), 1.0),
    (const Size(1024, 900), 1.0),
    (const Size(390, 900), 1.0),
    (const Size(1440, 900), 2.0),
  ]) {
    testWidgets(
      '${scenario.$1.width}px at ${scenario.$2} zoom aligns back and hierarchy without duplicate host gutters',
      (tester) async {
        Rect? standaloneTable;
        for (final inherited in [false, true]) {
          await tester.pumpWidget(const SizedBox.shrink());
          await _open(
            tester,
            size: scenario.$1,
            zoom: scenario.$2,
            inheritedPageGutter: inherited,
          );
          final gutter =
              UtenContentContainer.gutterForWidth(
                scenario.$1.width / scenario.$2,
                fontZoom: scenario.$2,
              ) *
              scenario.$2;
          final back = find.descendant(
            of: find.byType(UtenBackButton),
            matching: find.byType(IconButton),
          );
          expect(tester.getRect(back).left, closeTo(gutter, .01));
          final table = tester.getRect(
            find.byKey(const ValueKey('goods-import-preview-table')),
          );
          expect(table.height, greaterThan(0));
          if (standaloneTable == null) {
            standaloneTable = table;
          } else {
            expect(
              table,
              standaloneTable,
              reason:
                  'An existing page gutter must not shrink or move the table twice',
            );
          }
          expect(_table(tester).items.length, _source.length);
          final open = find.byKey(
            const ValueKey('goods-import-open-categories'),
          );
          if (open.evaluate().isNotEmpty) {
            await tester.ensureVisible(open);
            await tester.tap(open);
            await tester.pumpAndSettle();
          }
          final tree = find.byKey(const ValueKey('goods-import-category-tree'));
          expect(tester.getRect(tree).left, closeTo(gutter, .01));
          expect(_tree(tester).nodes, isNotEmpty);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
  testWidgets(
    'identity and BOM errors appear in their read-only single-line cells',
    (tester) async {
      const source = [
        GoodsImportProblemRow(
          rowNum: 2,
          code: '001',
          name: '开关',
          categoryPath: '成品',
          cells: {'goodsId': 'not-a-uuid', 'bomRef': '#REF!'},
        ),
      ];
      await _open(
        tester,
        report: _report(
          source: source,
          bad: {2},
          extraErrors: const [
            GoodsImportError(rowNum: 2, column: '货品UUID', message: '系统标识格式不正确'),
            GoodsImportError(
              rowNum: 2,
              column: '组装信息ID',
              message: '组装信息ID格式不正确',
            ),
          ],
        ),
      );
      final columns = _table(tester).columns;
      expect(
        columns.firstWhere((column) => column.key == 'goodsId').defaultVisible,
        isTrue,
      );
      expect(
        columns.firstWhere((column) => column.key == 'bomRef').defaultVisible,
        isTrue,
      );
      final identity = tester.widget<Text>(find.text('not-a-uuid'));
      expect(identity.maxLines, 1);
      expect(
        identity.style!.color,
        Theme.of(tester.element(find.text('not-a-uuid'))).colorScheme.error,
      );
      expect(
        find.byKey(const ValueKey('goods-import-goodsId-2')),
        findsNothing,
      );
    },
  );
  testWidgets(
    'resolved category names retain slashes and distinct hierarchy identities',
    (tester) async {
      const source = [
        GoodsImportProblemRow(
          rowNum: 2,
          code: '001',
          name: '开关',
          categoryPath: '成品-20A/45A',
          categorySegments: ['成品', '20A/45A'],
        ),
        GoodsImportProblemRow(
          rowNum: 3,
          code: '002',
          name: '另一开关',
          categoryPath: '成品-20A / 45A',
          categorySegments: ['成品-20A', '45A'],
        ),
      ];
      await _open(tester, report: _report(source: source));
      final nodes = _tree(tester).nodes;
      expect(nodes.map((node) => node.name), ['成品', '成品-20A']);
      expect(nodes.first.children.single.name, '20A/45A');
      expect(nodes.last.children.single.name, '45A');
      expect(
        nodes.first.children.single.id,
        isNot(nodes.last.children.single.id),
      );
      _tree(tester).onNodeTap!(nodes.first.children.single);
      await tester.pumpAndSettle();
      expect(_table(tester).items.single.rowNum, 2);
    },
  );

  testWidgets('large previews retain every source row and category count', (
    tester,
  ) async {
    final source = [
      for (var i = 0; i < 2000; i++)
        GoodsImportProblemRow(
          rowNum: i + 2,
          code: '$i',
          name: '货品$i',
          categoryPath: '成品 / 系列${i % 20}',
          categorySegments: ['成品', '系列${i % 20}'],
        ),
    ];
    await _open(tester, report: _report(source: source));
    expect(_table(tester).items.length, 2000);
    expect(_table(tester).selectedIds.length, 2000);
    expect(_tree(tester).nodes.single.goodsCount, 2000);
    expect(_tree(tester).nodes.single.children.length, 20);
    expect(
      _tree(
        tester,
      ).nodes.single.children.every((node) => node.goodsCount == 100),
      isTrue,
    );
  });
  testWidgets('all clean rows require a selectable full-page confirmation', (
    tester,
  ) async {
    final result = _Result();
    await _open(tester, result: result);
    expect(find.text('确认新建货品'), findsOneWidget);
    expect(_table(tester).items.length, 3);
    expect(_table(tester).selectedIds, {'2', '3', '4'});
    final input = find.byKey(const ValueKey('goods-import-name-2'));
    expect(tester.widget<UtenInput>(input).label, isNull);
    final decorator = tester.widget<InputDecorator>(
      find.descendant(of: input, matching: find.byType(InputDecorator)),
    );
    expect(
      decorator.decoration.floatingLabelBehavior,
      FloatingLabelBehavior.never,
    );
    expect(
      tester.getSize(input).height,
      lessThanOrEqualTo(
        UtenEditableGridCellSpec.heightOf(tester.element(input)) + 1,
      ),
    );
    expect(_table(tester).columns.map((column) => column.key).toList(), [
      'rowNum',
      'result',
      'code',
      'name',
      'categoryPath',
    ]);
    expect(_tree(tester).nodes.map((node) => node.name), ['成品', '原材料']);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'goods-import-preview-desktop',
      );
    }
    await tester.tap(
      find.byKey(const ValueKey('goods-import-preview-confirm')),
    );
    await tester.pumpAndSettle();
    expect(result.value!.report.previewRows.length, 3);
    expect(result.value!.excludedRowNums, isEmpty);
    expect(result.value!.replaceRowKeys, isEmpty);
  });

  testWidgets(
    'good and bad rows coexist and only the bad cell carries an error',
    (tester) async {
      await _open(tester, report: _report(bad: {3}));
      expect(_table(tester).items.length, 3);
      expect(_table(tester).selectedIds, {'2', '4'});
      final bad = tester.widget<UtenInput>(
        find.byKey(const ValueKey('goods-import-name-3')),
      );
      final good = tester.widget<UtenInput>(
        find.byKey(const ValueKey('goods-import-name-2')),
      );
      expect(bad.errorMessage, '请填写货品名称');
      expect(good.errorMessage, isNull);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'goods-import-preview-errors',
        );
      }
    },
  );

  testWidgets(
    'category edits immediately rebuild the involved ancestors and recheck',
    (tester) async {
      var detections = 0;
      GoodsImportCorrections? draft;
      await _open(
        tester,
        onDraft: (value, _) => draft = value,
        detect: (corrections, excluded) async {
          detections++;
          return _report(corrections: corrections, excluded: excluded);
        },
      );
      final input = find.byKey(const ValueKey('goods-import-categoryPath-2'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '成品 / 新系列 / 红色');
      await tester.pump();
      expect(draft![2]!['categoryPath'], '成品 / 新系列 / 红色');
      final finished = _tree(tester).nodes.first.children;
      expect(finished.map((node) => node.name), contains('新系列'));
      expect(
        finished.firstWhere((node) => node.name == '新系列').children.single.name,
        '红色',
      );
      expect(detections, 0);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(detections, 1);
      expect(_table(tester).items.single.rowNum, 2);
    },
  );

  testWidgets(
    'batch removal changes the signed exclusions and never writes goods',
    (tester) async {
      Set<int>? exclusions;
      await _open(
        tester,
        detect: (corrections, excluded) async {
          exclusions = excluded;
          return _report(corrections: corrections, excluded: excluded);
        },
      );
      _table(tester).onSelectedIdsChanged!({'2', '3'});
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('goods-import-remove-selected')),
      );
      await tester.pumpAndSettle();
      expect(exclusions, {2, 3});
      expect(_table(tester).items.single.rowNum, 4);
      expect(_tree(tester).nodes.single.name, '原材料');
    },
  );

  testWidgets(
    'removing rows updates counts and errors before the server recheck returns',
    (tester) async {
      final pending = Completer<GoodsImportReport>();
      await _open(
        tester,
        report: _report(bad: {3}),
        detect: (_, _) => pending.future,
      );
      _table(tester).onSelectedIdsChanged!({'3', '4'});
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('goods-import-remove-selected')),
      );
      await tester.pump();
      expect(find.text('共 1 条'), findsOneWidget);
      expect(find.text('可导入 1 条'), findsOneWidget);
      expect(find.text('1 处待修正'), findsNothing);
      pending.complete(_report(excluded: {3, 4}));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'subset confirmation locks selection and keeps temporary exclusions separate',
    (tester) async {
      final pending = Completer<GoodsImportReport>();
      final result = _Result();
      await _open(
        tester,
        result: result,
        detect: (_, excluded) {
          expect(excluded, {3, 4});
          return pending.future;
        },
      );
      _table(tester).onSelectedIdsChanged!({'2'});
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('goods-import-preview-confirm')),
      );
      await tester.pump();
      _table(tester).onSelectedIdsChanged!({'3'});
      await tester.pump();
      expect(_table(tester).selectedIds, {'2'});
      pending.complete(_report(excluded: {3, 4}));
      await tester.pumpAndSettle();
      expect(result.value!.excludedRowNums, {3, 4});
      expect(result.value!.removedRowNums, isEmpty);
      expect(result.value!.hasRemaining, isTrue);
      expect(result.value!.report.readyRowNums, [2]);
    },
  );

  testWidgets('a changed selected plan retains every unselected source row', (
    tester,
  ) async {
    const change = GoodsImportReviewRow(
      rowKey: 'goods:2',
      rowNum: 2,
      code: '001',
      name: '单联开关',
      categoryPath: '成品 / V3 / 白色',
      matchType: 'UUID',
      changes: [
        GoodsImportChange(
          field: 'name',
          label: '货品名称',
          oldValue: '已被他人修改',
          newValue: '单联开关',
          kind: 'CONFLICT',
        ),
      ],
    );
    final result = _Result();
    await _open(
      tester,
      result: result,
      detect: (_, excluded) async =>
          _report(excluded: excluded, changes: [change]),
    );
    _table(tester).onSelectedIdsChanged!({'2'});
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('goods-import-preview-confirm')),
    );
    await tester.pumpAndSettle();
    expect(result.value, isNull);
    expect(_table(tester).items.length, 3);
    expect(find.text('货品资料已有变化，请重新核对后确认'), findsOneWidget);
  });

  testWidgets(
    'conflict replacement is explicit and keeps server row identities',
    (tester) async {
      final result = _Result();
      await _open(
        tester,
        result: result,
        mode: GoodsImportMode.mixed,
        report: _report(changes: const [_nameConflict]),
      );
      expect(find.text('保留原值'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('原名称')).style!.decoration,
        TextDecoration.none,
      );
      await tester.tap(
        find.byKey(const ValueKey('goods-import-replace-selected')),
      );
      await tester.pumpAndSettle();
      expect(find.text('替换差异'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('原名称')).style!.decoration,
        TextDecoration.lineThrough,
      );
      await tester.tap(
        find.byKey(const ValueKey('goods-import-preview-confirm')),
      );
      await tester.pumpAndSettle();
      expect(result.value!.replaceRowKeys, {'goods:2'});
    },
  );

  for (final narrow in [false, true]) {
    testWidgets(
      'update mode visibly reviews original and imported names and applies changes by default ${narrow ? "narrow" : "desktop"}',
      (tester) async {
        final result = _Result();
        await _open(
          tester,
          result: result,
          mode: GoodsImportMode.updateOnly,
          report: _report(
            source: [_source.first],
            changes: const [_nameConflict],
          ),
          size: narrow ? const Size(390, 1100) : const Size(1440, 900),
          scale: narrow ? 2 : 1,
        );
        final input = find.byKey(const ValueKey('goods-import-name-2'));
        await tester.ensureVisible(
          find.ancestor(of: input, matching: find.byType(UtenReviewInputCell)),
        );
        await tester.pumpAndSettle();
        expect(find.text('确认修改货品'), findsOneWidget);
        expect(find.text('原值'), findsOneWidget);
        expect(find.text('导入值'), findsOneWidget);
        expect(find.text('原值').hitTestable(), findsOneWidget);
        expect(find.text('导入值').hitTestable(), findsOneWidget);
        expect(find.text('原名称'), findsOneWidget);
        expect(tester.widget<UtenInput>(input).controller!.text, '单联开关');
        expect(
          tester.widget<Text>(find.text('原名称')).style!.decoration,
          TextDecoration.lineThrough,
        );
        expect(
          tester.getRect(find.text('原名称')).bottom,
          lessThanOrEqualTo(tester.getRect(input).top),
        );
        expect(
          _table(tester).columns
              .firstWhere((column) => column.key == 'result')
              .value(_table(tester).items.single),
          '替换差异',
        );
        expect(tester.takeException(), isNull);
        final confirm = find.byKey(
          const ValueKey('goods-import-preview-confirm'),
        );
        // At large text sizes the floating action group scrolls independently
        // from the table. Bring its confirm action fully into that viewport.
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(confirm).bottom,
          lessThanOrEqualTo(tester.view.physicalSize.height),
        );
        expect(find.text('原值').hitTestable(), findsOneWidget);
        expect(find.text('导入值').hitTestable(), findsOneWidget);
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'goods-import-update-old-new-${narrow ? "narrow-200" : "desktop"}',
          );
        }
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(result.value!.replaceRowKeys, {'goods:2'});
      },
    );
  }

  testWidgets(
    'update mode explicit keep survives rechecking and can be changed in bulk',
    (tester) async {
      final result = _Result();
      await _open(
        tester,
        result: result,
        mode: GoodsImportMode.updateOnly,
        report: _report(
          source: [_source.first],
          changes: const [_nameConflict],
        ),
        detect: (corrections, excluded) async => _report(
          source: [_source.first],
          corrections: corrections,
          excluded: excluded,
          changes: const [_nameConflict],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('goods-import-conflict-2')));
      await tester.pumpAndSettle();
      expect(find.text('保留原值'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('goods-import-redetect-corrections')),
      );
      await tester.pumpAndSettle();
      expect(find.text('保留原值'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('原名称')).style!.decoration,
        TextDecoration.none,
      );
      await tester.tap(
        find.byKey(const ValueKey('goods-import-replace-selected')),
      );
      await tester.pumpAndSettle();
      expect(find.text('替换差异'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('goods-import-keep-selected')),
      );
      await tester.pumpAndSettle();
      expect(find.text('保留原值'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('goods-import-preview-confirm')),
      );
      await tester.pumpAndSettle();
      expect(result.value!.replaceRowKeys, isEmpty);
    },
  );

  testWidgets(
    'color and unit identity changes show the server original labels',
    (tester) async {
      await _open(
        tester,
        mode: GoodsImportMode.updateOnly,
        size: const Size(2400, 1000),
        report: _report(
          source: const [
            GoodsImportProblemRow(
              rowNum: 2,
              code: '001',
              name: '单联开关',
              categoryPath: '成品',
              cells: {'colorName': '梦幻金', 'unitName': '个'},
            ),
          ],
          changes: const [
            GoodsImportReviewRow(
              rowKey: 'goods:2',
              rowNum: 2,
              code: '001',
              name: '单联开关',
              categoryPath: '成品',
              matchType: 'UUID',
              changes: [
                GoodsImportChange(
                  field: 'colorId',
                  label: '主颜色',
                  oldValue: '灰色',
                  newValue: '梦幻金',
                  kind: 'CONFLICT',
                ),
                GoodsImportChange(
                  field: 'unitId',
                  label: '单位',
                  oldValue: '只',
                  newValue: '个',
                  kind: 'CONFLICT',
                ),
              ],
            ),
          ],
        ),
      );
      expect(find.text('原值'), findsNWidgets(2));
      expect(find.text('导入值'), findsNWidgets(2));
      for (final field in ['colorName', 'unitName']) {
        final cell = tester.widget<UtenInput>(
          find.byKey(ValueKey('goods-import-$field-2')),
        );
        expect(cell.controller!.text, field == 'colorName' ? '梦幻金' : '个');
      }
      for (final original in ['灰色', '只']) {
        expect(find.text(original), findsOneWidget);
        expect(find.byTooltip(original), findsOneWidget);
        expect(
          tester.widget<Text>(find.text(original)).style!.decoration,
          TextDecoration.lineThrough,
        );
      }
      await tester.tap(find.byKey(const ValueKey('goods-import-conflict-2')));
      await tester.pumpAndSettle();
      expect(find.text('保留原值'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('灰色')).style!.decoration,
        TextDecoration.none,
      );
    },
  );

  for (final size in [
    const Size(390, 900),
    const Size(768, 900),
    const Size(1440, 900),
  ]) {
    testWidgets('${size.width} width with 200% text keeps actions reachable', (
      tester,
    ) async {
      await _open(tester, size: size, scale: 2, dark: true);
      final confirm = find.byKey(
        const ValueKey('goods-import-preview-confirm'),
      );
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(confirm.hitTestable(), findsOneWidget);
      expect(tester.widget<UtenButton>(confirm).onPressed, isNotNull);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'goods-import-preview-${size.width.toInt()}-dark-200',
        );
      }
    });
  }
}
