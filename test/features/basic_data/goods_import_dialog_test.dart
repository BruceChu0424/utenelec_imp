import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_drop_target.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';
import 'package:uten_imp/features/basic_data/pages/goods_import_preview_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_import_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_import_dialog.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'importer-a'),
);

class _Picker extends FilePicker {
  int selections = 0;
  List<PlatformFile>? files;
  bool? multipleRequested;
  Future<FilePickerResult?> Function()? select;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    selections++;
    multipleRequested = allowMultiple;
    if (select != null) return select!();
    if (files != null) return FilePickerResult(files!);
    return FilePickerResult([
      PlatformFile(
        name: '货品客户型号.xlsx',
        size: 4,
        bytes: Uint8List.fromList([0x50, 0x4b, 3, 4]),
      ),
    ]);
  }
}

const _conflict = GoodsImportReviewRow(
  rowKey: 'goods:2',
  rowNum: 2,
  code: 'G001',
  name: '机壳',
  categoryPath: '成品-壳体',
  matchType: 'CODE',
  changes: [
    GoodsImportChange(
      field: 'clientModel',
      label: '客户型号',
      oldValue: '111',
      newValue: '222',
      kind: 'CONFLICT',
    ),
  ],
);

const _fill = GoodsImportReviewRow(
  rowKey: 'goods:3',
  rowNum: 3,
  code: 'G002',
  name: '螺丝',
  categoryPath: '原料-紧固件',
  matchType: 'CODE',
  changes: [
    GoodsImportChange(
      field: 'clientModel',
      label: '客户型号',
      oldValue: null,
      newValue: '333',
      kind: 'FILL',
    ),
  ],
);

class _Repository extends Fake implements GoodsImportRepository {
  int detections = 0;
  int commits = 0;
  List<GoodsImportReviewRow> reviewRows = [_conflict, _fill];
  String planId = 'plan:first';
  ApiException? rejection;
  ApiException? detectionRejection;
  Completer<GoodsImportResult>? pending;
  Completer<GoodsImportReport>? pendingDetection;
  final detectedBytes = <Uint8List>[];
  final submittedBytes = <Uint8List>[];
  final submittedPlans = <String>[];
  final submittedSelections = <Set<String>>[];
  final events = <String>[];
  final reviewsByFile = <int, List<GoodsImportReviewRow>>{};
  final restoresByFile = <int, int>{};
  final rejectionsByFile = <int, ApiException>{};
  GoodsImportReport Function(Uint8List, GoodsImportCorrections, Set<int>)?
  reportFor;
  GoodsImportResult Function()? resultFor;
  final detectedCorrections = <GoodsImportCorrections>[];
  final detectedExclusions = <Set<int>>[];
  final submittedCorrections = <GoodsImportCorrections>[];
  final submittedExclusions = <Set<int>>[];
  final detectedModes = <GoodsImportMode?>[];
  final submittedModes = <GoodsImportMode?>[];

  @override
  Future<GoodsImportReport> detect(
    Uint8List bytes, {
    Map<int, String> codeCorrections = const {},
    GoodsImportCorrections cellCorrections = const {},
    Set<int> excludedRowNums = const {},
    GoodsImportMode? mode,
  }) async {
    detections++;
    detectedBytes.add(bytes);
    detectedCorrections.add(freezeGoodsImportCorrections(cellCorrections));
    detectedExclusions.add(Set.of(excludedRowNums));
    detectedModes.add(mode);
    events.add('detect:${bytes.last}');
    if (detectionRejection != null) throw detectionRejection!;
    if (pendingDetection != null) return pendingDetection!.future;
    if (reportFor != null) {
      return reportFor!(bytes, cellCorrections, excludedRowNums);
    }
    final currentRows = reviewsByFile[bytes.last] ?? reviewRows;
    return _report(
      changes: currentRows,
      edits: cellCorrections,
      excluded: excludedRowNums,
      restoreCount: restoresByFile[bytes.last] ?? 0,
      plan: planId,
    );
  }

  @override
  Future<GoodsImportResult> commit(
    Uint8List bytes, {
    required String planId,
    String? filename,
    Set<String> replaceRowKeys = const {},
    Map<int, String> codeCorrections = const {},
    GoodsImportCorrections cellCorrections = const {},
    Set<int> excludedRowNums = const {},
    GoodsImportMode? mode,
  }) async {
    commits++;
    submittedBytes.add(bytes);
    submittedPlans.add(planId);
    submittedSelections.add(Set.of(replaceRowKeys));
    submittedCorrections.add(freezeGoodsImportCorrections(cellCorrections));
    submittedExclusions.add(Set.of(excludedRowNums));
    submittedModes.add(mode);
    events.add('commit:${bytes.last}');
    if (rejectionsByFile[bytes.last] case final error?) throw error;
    if (rejection != null) throw rejection!;
    if (resultFor != null) return resultFor!();
    return pending?.future ??
        const GoodsImportResult(
          batchId: 'batch:1',
          importedCount: 2,
          createdCategories: 0,
          createdColors: 0,
          createdUnits: 0,
          createdCategoryPaths: [],
          filledCount: 1,
          updatedCount: 1,
        );
  }
}

Future<void> _open(
  WidgetTester tester,
  _Repository repository, {
  bool expectReview = true,
  bool pick = true,
  Size size = const Size(1440, 900),
  double textScale = 1,
  GoodsImportMode mode = GoodsImportMode.mixed,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsImportRepositoryProvider.overrideWithValue(repository),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showGoodsImportDialog(context, ref, mode: mode),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  if (!pick) return;
  await tester.tap(find.text('选择 Excel 文件'));
  await tester.pumpAndSettle();
  expect(
    find.byType(GoodsImportPreviewPage),
    expectReview ? findsOneWidget : findsNothing,
  );
  expect(repository.commits, 0);
}

List<PlatformFile> _queueFiles(List<int> markers) => [
  for (final marker in markers)
    PlatformFile(
      name: '货品-$marker.xlsx',
      size: 4,
      bytes: Uint8List.fromList([0x50, 0x4b, 3, marker]),
    ),
];

const _firstRow = GoodsImportProblemRow(
  rowNum: 2,
  code: 'G001',
  name: '机壳',
  categoryPath: '成品 / 壳体',
  cells: {'cNumber': '222'},
);
const _secondRow = GoodsImportProblemRow(
  rowNum: 3,
  code: 'G002',
  name: '螺丝',
  categoryPath: '原料 / 紧固件',
  cells: {'cNumber': '333'},
);
const _thirdRow = GoodsImportProblemRow(
  rowNum: 4,
  code: 'G004',
  name: '正常货品',
  categoryPath: '成品',
);

GoodsImportReport _report({
  List<GoodsImportProblemRow> rows = const [_firstRow, _secondRow],
  List<GoodsImportError> errors = const [],
  List<GoodsImportReviewRow> changes = const [],
  GoodsImportCorrections edits = const {},
  Set<int> excluded = const {},
  int restoreCount = 0,
  String plan = 'plan:reviewed',
}) {
  final active = [
    for (final row in rows)
      if (!excluded.contains(row.rowNum))
        GoodsImportProblemRow(
          rowNum: row.rowNum,
          code: edits[row.rowNum]?['code'] ?? row.code,
          name: edits[row.rowNum]?['name'] ?? row.name,
          categoryPath: edits[row.rowNum]?['categoryPath'] ?? row.categoryPath,
          cells: {
            'code': row.code,
            'name': row.name,
            'categoryPath': row.categoryPath,
            ...row.cells,
            ...?edits[row.rowNum],
          },
        ),
  ];
  final activeErrors = errors
      .where((error) => !excluded.contains(error.rowNum))
      .toList();
  final invalid = activeErrors.map((error) => error.rowNum).toSet();
  final ready = active
      .where((row) => !invalid.contains(row.rowNum))
      .map((row) => row.rowNum)
      .toList();
  return GoodsImportReport(
    totalRows: rows.length,
    dataRows: active.length,
    errors: activeErrors,
    willCreateCategories: const [],
    willCreateColors: const [],
    willCreateUnits: const [],
    readyToImport: ready.length,
    restorableRows: restoreCount,
    planId: ready.isEmpty ? null : plan,
    readyRowNums: ready,
    previewRows: active,
    problemRows: active.where((row) => invalid.contains(row.rowNum)).toList(),
    reviewRows: changes.where((row) => ready.contains(row.rowNum)).toList(),
    fillRows: changes
        .where((row) => ready.contains(row.rowNum) && !row.hasConflicts)
        .length,
    conflictRows: changes
        .where((row) => ready.contains(row.rowNum) && row.hasConflicts)
        .length,
  );
}

GoodsImportReport _problemReport({
  required GoodsImportCorrections edits,
  required Set<int> excluded,
}) => _report(
  rows: const [_firstRow, _secondRow, _thirdRow],
  errors: edits[3]?['code'] == 'NEW'
      ? const []
      : const [
          GoodsImportError(rowNum: 2, column: '编号', message: '编号重复'),
          GoodsImportError(rowNum: 3, column: '编号', message: '编号重复'),
        ],
  edits: edits,
  excluded: excluded,
);

GoodsImportResult _completedResult({
  int imported = 0,
  int created = 0,
  int updated = 0,
  int filled = 0,
  int ignored = 0,
  int unchanged = 0,
}) => GoodsImportResult(
  batchId: imported == 0 ? '' : 'batch:completed',
  importedCount: imported,
  createdCategories: 0,
  createdColors: 0,
  createdUnits: 0,
  createdCategoryPaths: const [],
  createdCount: created,
  updatedCount: updated,
  filledCount: filled,
  ignoredCount: ignored,
  unchangedCount: unchanged,
);

Future<void> _tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester, {bool replace = false}) async {
  if (replace &&
      find
          .byKey(const ValueKey('goods-import-replace-selected'))
          .evaluate()
          .isNotEmpty) {
    await _tapKey(tester, 'goods-import-replace-selected');
  }
  await _tapKey(tester, 'goods-import-preview-confirm');
}

Future<void> _editCode(WidgetTester tester, String value) async {
  final cell = find.byKey(const ValueKey('goods-import-code-3'));
  await tester.ensureVisible(cell);
  await tester.enterText(cell, value);
  await _tapKey(tester, 'goods-import-redetect-corrections');
}

void main() {
  late _Picker picker;
  setUp(() {
    picker = _Picker();
    FilePicker.platform = picker;
  });

  testWidgets(
    'multi-file guidance opens at the import title without selecting files',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo, pick: false);
      const note = '可一次选择多个文件，按顺序检测并导入。每个文件独立保存，后续失败或关闭不会撤销已成功的文件。';
      expect(find.textContaining(note), findsNothing);
      final hint = find.byWidgetPredicate(
        (widget) =>
            widget is UtenFieldHintIcon &&
            (widget.info?.contains(note) ?? false),
      );
      expect(hint, findsOneWidget);
      await tester.tap(hint);
      await tester.pumpAndSettle();
      expect(find.textContaining(note), findsOneWidget);
      expect(repo.detections, 0);
      expect(repo.commits, 0);
      expect(picker.selections, 0);
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();
      expect(find.text('选择 Excel 文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'every normal and unchanged row requires full preview confirmation',
    (tester) async {
      final repo = _Repository()..reviewRows = [];
      await _open(tester, repo);
      expect(find.text('机壳'), findsWidgets);
      expect(find.text('螺丝'), findsWidgets);
      expect(repo.commits, 0);
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(repo.submittedSelections.single, isEmpty);
    },
  );

  for (final mode in GoodsImportMode.values) {
    testWidgets('${mode.wireName} is retained through preview and commit', (
      tester,
    ) async {
      final repo = _Repository()..reviewRows = [];
      await _open(tester, repo, mode: mode);
      expect(repo.detectedModes.single, mode);
      expect(repo.commits, 0);
      await _confirm(tester);
      expect(repo.submittedModes.single, mode);
    });
  }

  testWidgets('update mode sends replacement choices without an extra toggle', (
    tester,
  ) async {
    final repo = _Repository();
    await _open(tester, repo, mode: GoodsImportMode.updateOnly);
    await _confirm(tester);
    expect(repo.submittedModes.single, GoodsImportMode.updateOnly);
    expect(repo.submittedSelections.single, {'goods:2'});
  });

  testWidgets(
    'mixed mode creates new goods and applies existing file differences',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) => _report(
          rows: const [_firstRow, _thirdRow],
          changes: const [_conflict],
          edits: edits,
          excluded: excluded,
        );
      repo.resultFor = () =>
          _completedResult(imported: 2, created: 1, updated: 1);
      await _open(tester, repo);
      await _confirm(tester);
      expect(repo.detectedModes.single, GoodsImportMode.mixed);
      expect(repo.submittedModes.single, GoodsImportMode.mixed);
      expect(repo.submittedSelections.single, {'goods:2'});
      expect(repo.submittedExclusions.single, isEmpty);
      expect(repo.submittedBytes.single, same(repo.detectedBytes.single));
      expect(find.text('已写入 2 条货品'), findsOneWidget);
      expect(find.text('新增 1'), findsOneWidget);
      expect(find.text('修改 1'), findsOneWidget);
      expect(find.textContaining('保留原值'), findsNothing);
    },
  );

  testWidgets(
    'explicit keep survives returning and a rejected update submission',
    (tester) async {
      final repo = _Repository()
        ..reviewRows = const [
          _conflict,
          GoodsImportReviewRow(
            rowKey: 'goods:3',
            rowNum: 3,
            code: 'G002',
            name: '螺丝',
            categoryPath: '原料 / 紧固件',
            matchType: 'UUID',
            changes: [
              GoodsImportChange(
                field: 'name',
                label: '货品名称',
                oldValue: '原螺丝',
                newValue: '螺丝',
                kind: 'CONFLICT',
              ),
            ],
          ),
        ];
      await _open(tester, repo, mode: GoodsImportMode.updateOnly);
      await _tapKey(tester, 'goods-import-conflict-2');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看导入预览'));
      await tester.pumpAndSettle();
      void expectChoices() {
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('goods-import-conflict-2')),
            matching: find.text('保留原值'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('goods-import-conflict-3')),
            matching: find.text('替换差异'),
          ),
          findsOneWidget,
        );
      }

      expectChoices();
      repo
        ..planId = 'plan:latest'
        ..rejection = ApiException('CONFLICT', '资料已变化', httpStatus: 409);
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(repo.submittedSelections.single, {'goods:3'});
      expectChoices();
      repo.rejection = null;
      await _confirm(tester);
      expect(repo.submittedPlans, ['plan:first', 'plan:latest']);
      expect(repo.submittedSelections.last, {'goods:3'});
    },
  );

  testWidgets(
    'explicit replacement choices stay within their file in a queue',
    (tester) async {
      picker.files = _queueFiles([1, 2]);
      final repo = _Repository();
      await _open(tester, repo, mode: GoodsImportMode.updateOnly);
      await _tapKey(tester, 'goods-import-conflict-2');
      await _confirm(tester);
      expect(repo.submittedSelections.single, isEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('goods-import-conflict-2')),
          matching: find.text('替换差异'),
        ),
        findsOneWidget,
      );
      await _confirm(tester);
      expect(repo.submittedSelections.last, {'goods:2'});
    },
  );

  for (final scenario in [
    (
      name: 'updated goods',
      result: _completedResult(imported: 2, updated: 2),
      headline: '已写入 2 条货品',
      details: ['修改 2'],
    ),
    (
      name: 'retained conflicts without writes',
      result: _completedResult(ignored: 8),
      headline: '未写入变更',
      details: ['保留原值 8'],
    ),
    (
      name: 'unchanged rows without writes',
      result: _completedResult(unchanged: 8),
      headline: '未写入变更',
      details: ['资料相同 8'],
    ),
    (
      name: 'BOM writes while goods fields are retained',
      result: _completedResult(imported: 7, ignored: 8),
      headline: '已更新 7 条货品的组装信息',
      details: ['保留原值 8'],
    ),
    (
      name: 'overlapping updated and filled counters',
      result: _completedResult(imported: 2, updated: 2, filled: 2),
      headline: '已写入 2 条货品',
      details: ['修改 2', '补齐 2'],
    ),
  ]) {
    testWidgets('result distinguishes ${scenario.name}', (tester) async {
      final repo = _Repository()
        ..reviewRows = []
        ..resultFor = () => scenario.result;
      await _open(tester, repo);
      await _confirm(tester);
      expect(find.text(scenario.headline), findsOneWidget);
      for (final detail in scenario.details) {
        expect(find.text(detail), findsOneWidget);
      }
      expect(find.textContaining('已导入'), findsNothing);
      if (scenario.result.updatedCount == 0) {
        expect(find.textContaining('修改 '), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'mixed conflicts retain original values when keep is explicitly chosen',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      await _tapKey(tester, 'goods-import-keep-selected');
      await _confirm(tester);
      expect(repo.submittedSelections.single, isEmpty);
      expect(repo.submittedPlans.single, 'plan:first');
    },
  );

  testWidgets(
    'the reviewed conflict selection is sent with the exact detected plan',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      await _confirm(tester, replace: true);
      expect(repo.detections, 1);
      expect(repo.submittedSelections.single, {'goods:2'});
      expect(repo.submittedBytes.single, same(repo.detectedBytes.single));
    },
  );

  testWidgets(
    'cancel preview performs no writes and can reopen retained rows',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(repo.commits, 0);
      expect(find.byType(GoodsImportPreviewPage), findsNothing);
      await tester.tap(find.text('查看导入预览'));
      await tester.pumpAndSettle();
      expect(find.byType(GoodsImportPreviewPage), findsOneWidget);
      expect(repo.detections, 1);
      await _confirm(tester);
      expect(repo.commits, 1);
    },
  );

  testWidgets(
    'fill-only files require their own explicit full-page confirmation',
    (tester) async {
      final repo = _Repository()..reviewRows = [_fill];
      await _open(tester, repo);
      expect(repo.commits, 0);
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(repo.submittedSelections.single, isEmpty);
    },
  );

  testWidgets(
    'valid rows import first and corrected rows never replay successful rows',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) =>
            _problemReport(edits: edits, excluded: excluded);
      await _open(tester, repo);
      expect(repo.commits, 0);
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(repo.submittedExclusions.first, {2, 3});
      expect(repo.detectedExclusions.last, {4});
      expect(find.byType(GoodsImportPreviewPage), findsOneWidget);
      await _editCode(tester, 'NEW');
      expect(repo.commits, 1);
      await _confirm(tester);
      expect(repo.commits, 2);
      expect(repo.submittedExclusions.last, {4});
      expect(repo.submittedCorrections.last, {
        3: {'code': 'NEW'},
      });
      expect(repo.submittedBytes.last, same(repo.submittedBytes.first));
      expect(find.text('导入完成'), findsOneWidget);
    },
  );

  testWidgets(
    'corrections and processed exclusions never leak into the next file',
    (tester) async {
      picker.files = _queueFiles([4, 5]);
      final repo = _Repository()
        ..reportFor = (bytes, edits, excluded) => bytes.last == 5
            ? _report(edits: edits, excluded: excluded)
            : _problemReport(edits: edits, excluded: excluded);
      await _open(tester, repo);
      await _editCode(tester, 'NEW');
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(find.byType(GoodsImportPreviewPage), findsOneWidget);
      expect(repo.detectedCorrections.last, isEmpty);
      expect(repo.detectedExclusions.last, isEmpty);
      await _confirm(tester);
      expect(repo.commits, 2);
      expect(repo.submittedCorrections.first, {
        3: {'code': 'NEW'},
      });
      expect(repo.submittedCorrections.last, isEmpty);
      expect(repo.submittedExclusions.last, isEmpty);
    },
  );

  testWidgets(
    'rejected cell correction remains editable and cannot reuse the old valid plan',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) {
          if (edits[3]?['code'] == 'INVALID') {
            throw ApiException('VALIDATION_FAILED', '编号无效');
          }
          return _problemReport(edits: edits, excluded: excluded);
        };
      await _open(tester, repo);
      await _editCode(tester, 'INVALID');
      expect(find.text('编号无效'), findsWidgets);
      expect(repo.commits, 0);
      final confirm = tester.widget<UtenButton>(
        find.byKey(const ValueKey('goods-import-preview-confirm')),
      );
      expect(confirm.onPressed, isNull);
      await _editCode(tester, 'NEW');
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(repo.submittedCorrections.single, {
        3: {'code': 'NEW'},
      });
    },
  );

  testWidgets(
    'edits survive returning to the dialog and are redetected before confirmation',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) =>
            _problemReport(edits: edits, excluded: excluded);
      await _open(tester, repo);
      await tester.enterText(
        find.byKey(const ValueKey('goods-import-code-3')),
        'NEW',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(repo.commits, 0);
      await tester.tap(find.text('查看导入预览'));
      await tester.pumpAndSettle();
      expect(find.text('NEW'), findsWidgets);
      expect(repo.detectedCorrections.last, {
        3: {'code': 'NEW'},
      });
      expect(repo.commits, 0);
      await _confirm(tester);
      expect(repo.commits, 1);
    },
  );

  testWidgets(
    'numeric errors are repaired in the same preview before importing',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) => _report(
          rows: const [
            GoodsImportProblemRow(
              rowNum: 2,
              code: 'P1',
              name: '插座',
              categoryPath: '成品',
              cells: {'price': 'abc'},
            ),
          ],
          errors: edits[2]?['price'] == '12.50'
              ? const []
              : const [
                  GoodsImportError(
                    rowNum: 2,
                    column: '价格',
                    message: '价格必须是有效数字',
                  ),
                ],
          edits: edits,
          excluded: excluded,
        );
      await _open(tester, repo, size: const Size(2400, 1000));
      final cell = find.byKey(const ValueKey('goods-import-price-2'));
      await tester.ensureVisible(cell);
      await tester.enterText(cell, '12.50');
      await _tapKey(tester, 'goods-import-redetect-corrections');
      expect(repo.commits, 0);
      await _confirm(tester);
      expect(repo.submittedCorrections.single, {
        2: {'price': '12.50'},
      });
    },
  );

  testWidgets(
    'network uncertainty freezes the corrected selected plan and original bytes',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) =>
            _problemReport(edits: edits, excluded: excluded);
      await _open(tester, repo);
      await _editCode(tester, 'NEW');
      repo.rejection = NetworkTimeoutException();
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(find.text('重试上次提交'), findsOneWidget);
      final choose = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '重新选择'),
      );
      expect(choose.onPressed, isNull);
      await tester.tap(find.text('重新选择'));
      await tester.pumpAndSettle();
      expect(picker.selections, 1);
      final beforeRetry = repo.detections;
      repo.rejection = null;
      await tester.tap(find.text('重试上次提交'));
      await tester.pumpAndSettle();
      expect(repo.detections, beforeRetry);
      expect(repo.submittedPlans[1], repo.submittedPlans[0]);
      expect(repo.submittedCorrections[1], repo.submittedCorrections[0]);
      expect(repo.submittedExclusions[1], repo.submittedExclusions[0]);
      expect(repo.submittedBytes[1], same(repo.submittedBytes[0]));
    },
  );

  testWidgets(
    'a consumed-plan 409 after a lost successful response keeps the original submission frozen',
    (tester) async {
      var serverWrites = 0;
      final repo = _Repository();
      repo.reportFor = (_, edits, excluded) => _report(
        rows: const [_firstRow, _secondRow, _thirdRow],
        changes: const [_conflict, _fill],
        edits: edits,
        excluded: excluded,
        plan: 'plan:selected-snapshot',
      );
      repo.resultFor = () {
        if (serverWrites == 0) {
          serverWrites++;
          throw NetworkTimeoutException();
        }
        throw ApiException('CONFLICT', '检测计划已使用，请重新检测', httpStatus: 409);
      };
      await _open(tester, repo);
      await _editCode(tester, 'NEW');
      final unselected = find.byKey(
        const ValueKey('goods-import-preview-row-4'),
      );
      await tester.tap(
        find
            .descendant(of: unselected, matching: find.byType(Checkbox))
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      await _confirm(tester, replace: true);
      expect(serverWrites, 1);
      expect(repo.commits, 1);
      expect(repo.submittedCorrections.single, {
        3: {'code': 'NEW'},
      });
      expect(repo.submittedExclusions.single, {4});
      expect(repo.submittedSelections.single, {'goods:2'});
      final detectionsBeforeRetry = repo.detections;
      await tester.tap(find.text('重试上次提交'));
      await tester.pumpAndSettle();
      expect(repo.commits, 2);
      expect(serverWrites, 1);
      expect(repo.detections, detectionsBeforeRetry);
      expect(find.text('提交结果待核对，请查看修改历史确认结果。'), findsOneWidget);
      expect(find.text('重试上次提交'), findsOneWidget);
      expect(find.text('重新检测当前文件'), findsNothing);
      expect(find.text('查看导入预览'), findsNothing);
      expect(find.byType(GoodsImportPreviewPage), findsNothing);
      final choose = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '重新选择'),
      );
      expect(choose.onPressed, isNull);
      await tester.tap(find.text('重新选择'));
      await tester.pumpAndSettle();
      expect(picker.selections, 1);
      final drop = tester.widget<UtenDropTarget>(find.byType(UtenDropTarget));
      expect(drop.enabled, isFalse);
      drop.onFiles(_queueFiles([8]));
      await tester.pumpAndSettle();
      expect(repo.detections, detectionsBeforeRetry);
      expect(repo.commits, 2);
      expect(repo.submittedBytes[1], same(repo.submittedBytes[0]));
      expect(repo.submittedPlans, [
        'plan:selected-snapshot',
        'plan:selected-snapshot',
      ]);
      expect(repo.submittedCorrections[1], repo.submittedCorrections[0]);
      expect(repo.submittedExclusions[1], repo.submittedExclusions[0]);
      expect(repo.submittedSelections[1], repo.submittedSelections[0]);
      expect(repo.submittedModes[1], repo.submittedModes[0]);
    },
  );

  testWidgets(
    'uncertain partial retry preserves temporary exclusions and retains remaining rows',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) =>
            _problemReport(edits: edits, excluded: excluded);
      await _open(tester, repo);
      repo.rejection = NetworkTimeoutException();
      await _confirm(tester);
      expect(repo.submittedExclusions.single, {2, 3});
      repo.rejection = null;
      await tester.tap(find.text('重试上次提交'));
      await tester.pumpAndSettle();
      expect(repo.submittedExclusions, [
        {2, 3},
        {2, 3},
      ]);
      expect(repo.detectedExclusions.last, {4});
      expect(find.byType(GoodsImportPreviewPage), findsOneWidget);
      expect(find.byKey(const ValueKey('goods-import-code-3')), findsOneWidget);
    },
  );

  testWidgets(
    'rejected code refreshes its row and preserves edits and permanent exclusions',
    (tester) async {
      var codeBecameOccupied = false;
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) => _report(
          rows: const [
            _firstRow,
            _secondRow,
            _thirdRow,
            GoodsImportProblemRow(
              rowNum: 5,
              code: 'G005',
              name: '稍后导入的货品',
              categoryPath: '成品',
            ),
          ],
          errors: codeBecameOccupied && edits[3]?['code'] != 'AVAILABLE'
              ? const [
                  GoodsImportError(
                    rowNum: 3,
                    column: '编号',
                    message: '编号 NEW 已占用，请更换编号',
                  ),
                ]
              : const [],
          edits: edits,
          excluded: excluded,
          plan: codeBecameOccupied ? 'plan:latest' : 'plan:first',
        );
      await _open(tester, repo);
      Future<void> toggleRow(int row) async {
        final target = find.byKey(ValueKey('goods-import-preview-row-$row'));
        await tester.tap(
          find
              .descendant(of: target, matching: find.byType(Checkbox))
              .hitTestable(),
        );
        await tester.pumpAndSettle();
      }

      // Permanently remove row 4, then leave row 5 out of this submission only.
      for (final row in [2, 3, 5]) {
        await toggleRow(row);
      }
      await _tapKey(tester, 'goods-import-remove-selected');
      await _editCode(tester, 'NEW');
      await _tapKey(tester, 'goods-import-select-ready');
      await toggleRow(5);
      repo.resultFor = () {
        codeBecameOccupied = true;
        throw ApiException('CONFLICT', '编号已占用', httpStatus: 409);
      };
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(repo.submittedExclusions.single, {4, 5});
      expect(repo.detectedExclusions.last, {4});
      expect(repo.detectedCorrections.last, {
        3: {'code': 'NEW'},
      });
      expect(repo.detectedBytes.last, same(repo.submittedBytes.single));
      expect(find.byType(GoodsImportPreviewPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('goods-import-preview-row-4')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('goods-import-preview-row-5')),
        findsOneWidget,
      );
      final failedCell = tester.widget<UtenInput>(
        find.byKey(const ValueKey('goods-import-code-3')),
      );
      expect(failedCell.controller!.text, 'NEW');
      expect(failedCell.errorMessage, '编号 NEW 已占用，请更换编号');
      final validCell = tester.widget<UtenInput>(
        find.byKey(const ValueKey('goods-import-code-2')),
      );
      expect(validCell.errorMessage, isNull);
      expect(find.text('1 处待修正'), findsOneWidget);
      expect(find.text('可导入 2 条'), findsOneWidget);

      repo.resultFor = null;
      await _editCode(tester, 'AVAILABLE');
      expect(repo.commits, 1);
      await _confirm(tester);
      expect(repo.commits, 2);
      expect(repo.submittedPlans, ['plan:first', 'plan:latest']);
      expect(repo.submittedExclusions.last, {4});
      expect(repo.submittedCorrections.last, {
        3: {'code': 'AVAILABLE'},
      });
    },
  );

  testWidgets(
    'a concurrent write requires a fresh detection and another confirmation',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      repo
        ..planId = 'plan:latest'
        ..rejection = ApiException('CONFLICT', '资料已变更，请重新检测');
      await _confirm(tester, replace: true);
      expect(repo.commits, 1);
      expect(repo.detections, 2);
      expect(find.byType(GoodsImportPreviewPage), findsOneWidget);
      expect(repo.detectedBytes.last, same(repo.detectedBytes.first));
      repo.rejection = null;
      await _confirm(tester, replace: true);
      expect(repo.submittedPlans, ['plan:first', 'plan:latest']);
    },
  );

  testWidgets('a pending commit locks dismissal and shows loading feedback', (
    tester,
  ) async {
    final repo = _Repository()..pending = Completer<GoodsImportResult>();
    await _open(tester, repo);
    await tester.tap(
      find.byKey(const ValueKey('goods-import-preview-confirm')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(repo.commits, 1);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    repo.pending!.complete(
      const GoodsImportResult(
        batchId: 'batch:1',
        importedCount: 2,
        createdCategories: 0,
        createdColors: 0,
        createdUnits: 0,
        createdCategoryPaths: [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);
    expect(repo.commits, 1);
  });

  testWidgets('detection errors retain the exact file and can retry', (
    tester,
  ) async {
    final repo = _Repository()
      ..detectionRejection = ApiException('RATE_LIMITED', '当前已有商品导入任务，请稍后重试');
    await _open(tester, repo, expectReview: false);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('当前已有商品导入任务，请稍后重试'), findsOneWidget);
    repo.detectionRejection = null;
    await tester.tap(find.text('重新检测当前文件'));
    await tester.pumpAndSettle();
    expect(repo.detectedBytes.last, same(repo.detectedBytes.first));
    expect(picker.selections, 1);
    expect(repo.commits, 0);
    await _confirm(tester);
    expect(repo.commits, 1);
  });

  testWidgets('empty file read failures can recover with another selection', (
    tester,
  ) async {
    picker.files = [
      PlatformFile(name: 'empty.xlsx', size: 0, bytes: Uint8List(0)),
    ];
    final repo = _Repository();
    await _open(tester, repo, expectReview: false);
    expect(repo.detections, 0);
    expect(repo.commits, 0);
    picker.files = _queueFiles([1]);
    await tester.tap(find.text('选择 Excel 文件'));
    await tester.pumpAndSettle();
    await _confirm(tester);
    expect(repo.commits, 1);
  });

  testWidgets('old responses without full preview rows fail closed', (
    tester,
  ) async {
    final repo = _Repository()
      ..reportFor = (_, _, _) => const GoodsImportReport(
        totalRows: 2,
        dataRows: 2,
        errors: [],
        willCreateCategories: [],
        willCreateColors: [],
        willCreateUnits: [],
        readyToImport: 2,
        restorableRows: 0,
        planId: 'legacy:plan',
      );
    await _open(tester, repo, expectReview: false);
    expect(find.text('未取得完整货品预览，请重新检查文件'), findsWidgets);
    expect(find.text('查看导入预览'), findsNothing);
    expect(repo.commits, 0);
  });

  testWidgets(
    'each file in a queue requires its own confirmation including normal files',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..reviewRows = []
        ..restoresByFile[2] = 1;
      await _open(tester, repo);
      expect(picker.multipleRequested, isTrue);
      expect(repo.events, ['detect:1']);
      await _confirm(tester);
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2']);
      expect(find.text('将恢复 1 条'), findsOneWidget);
      await _confirm(tester);
      expect(repo.events.last, 'detect:3');
      expect(repo.commits, 2);
      await _confirm(tester);
      expect(repo.submittedBytes.map((bytes) => bytes.last), [1, 2, 3]);
      expect(find.text('已完成 3 个文件'), findsOneWidget);
    },
  );

  testWidgets(
    'a later rejected file preserves earlier successes and rechecks itself',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..reviewRows = []
        ..rejectionsByFile[2] = ApiException('CONFLICT', '资料已变更');
      await _open(tester, repo);
      await _confirm(tester);
      await _confirm(tester);
      expect(repo.commits, 2);
      expect(find.text('已完成 1/3 个文件', skipOffstage: false), findsOneWidget);
      repo.rejectionsByFile.clear();
      expect(find.byType(GoodsImportPreviewPage), findsOneWidget);
      expect(repo.detectedBytes.last, same(repo.detectedBytes[1]));
      await _confirm(tester);
      expect(repo.commits, 3);
      await _confirm(tester);
      expect(repo.events.where((event) => event == 'commit:1'), hasLength(1));
      expect(find.text('已完成 3 个文件'), findsOneWidget);
    },
  );

  testWidgets(
    'reselecting pending files retains previously completed results',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()..reviewRows = [];
      await _open(tester, repo);
      await _confirm(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      picker.files = _queueFiles([4]);
      await tester.tap(find.text('重新选择'));
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      await _confirm(tester);
      expect(repo.submittedBytes.map((bytes) => bytes.last), [1, 4]);
      expect(repo.events.where((event) => event == 'detect:3'), isEmpty);
      expect(find.text('已完成 2 个文件'), findsOneWidget);
    },
  );

  testWidgets(
    'dropped files preserve order and require individual confirmation',
    (tester) async {
      final repo = _Repository()..reviewRows = [];
      await _open(tester, repo, pick: false);
      tester
          .widget<UtenDropTarget>(find.byType(UtenDropTarget))
          .onFiles(_queueFiles([1, 2]));
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1']);
      await _confirm(tester);
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2']);
      await _confirm(tester);
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2', 'commit:2']);
    },
  );

  testWidgets(
    'successful rows stay excluded when the following detection fails',
    (tester) async {
      var failed = false;
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) {
          if (excluded.contains(4) && !failed) {
            failed = true;
            throw NetworkTimeoutException();
          }
          return _problemReport(edits: edits, excluded: excluded);
        };
      await _open(tester, repo);
      await _confirm(tester);
      expect(repo.commits, 1);
      expect(find.byType(GoodsImportPreviewPage), findsNothing);
      await tester.tap(find.text('重新检测当前文件'));
      await tester.pumpAndSettle();
      expect(repo.detectedExclusions, [
        <int>{},
        {2, 3},
        {4},
        {4},
      ]);
      expect(find.byType(GoodsImportPreviewPage), findsOneWidget);
      expect(repo.commits, 1);
      expect(find.byKey(const ValueKey('goods-import-code-3')), findsOneWidget);
    },
  );

  testWidgets(
    'identity changes remove the private preview and import dialog without writes',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(GoodsImportPreviewPage)),
      );
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'importer-b',
      );
      await tester.pumpAndSettle();
      expect(find.byType(GoodsImportPreviewPage), findsNothing);
      expect(find.text('导入货品'), findsNothing);
      expect(find.text('机壳'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      expect(repo.commits, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late cell validation cannot restore a preview after identity changes',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(GoodsImportPreviewPage)),
      );
      repo.pendingDetection = Completer<GoodsImportReport>();
      await tester.enterText(
        find.byKey(const ValueKey('goods-import-code-3')),
        'NEW',
      );
      await tester.tap(
        find.byKey(const ValueKey('goods-import-redetect-corrections')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(repo.detections, 2);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'importer-b',
      );
      await tester.pumpAndSettle();
      repo.pendingDetection!.complete(
        _report(
          edits: {
            3: {'code': 'NEW'},
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GoodsImportPreviewPage), findsNothing);
      expect(find.text('导入货品'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      expect(repo.commits, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow large-text preview can return and close a partially completed queue',
    (tester) async {
      picker.files = _queueFiles([1, 2]);
      final repo = _Repository()..reviewRows = [];
      await _open(tester, repo, size: const Size(390, 844), textScale: 2);
      expect(tester.takeException(), isNull);
      await _confirm(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('已完成 1/2 个文件'), findsOneWidget);
      final close = find.byIcon(Icons.close_rounded);
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      expect(find.text('打开'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
