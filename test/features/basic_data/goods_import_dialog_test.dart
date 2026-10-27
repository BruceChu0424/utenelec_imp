import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/components/inputs/uten_drop_target.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';
import 'package:uten_imp/features/basic_data/pages/import_review_page.dart';
import 'package:uten_imp/features/basic_data/pages/goods_import_problems_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_import_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_import_dialog.dart';

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

  @override
  Future<GoodsImportReport> detect(
    Uint8List bytes, {
    Map<int, String> codeCorrections = const {},
    GoodsImportCorrections cellCorrections = const {},
    Set<int> excludedRowNums = const {},
  }) async {
    detections++;
    detectedBytes.add(bytes);
    detectedCorrections.add(freezeGoodsImportCorrections(cellCorrections));
    detectedExclusions.add(Set.of(excludedRowNums));
    events.add('detect:${bytes.last}');
    if (detectionRejection != null) throw detectionRejection!;
    if (reportFor != null) {
      return reportFor!(bytes, cellCorrections, excludedRowNums);
    }
    final currentRows = reviewsByFile[bytes.last] ?? reviewRows;
    return GoodsImportReport(
      totalRows: 3,
      dataRows: 2,
      errors: const [],
      willCreateCategories: const [],
      willCreateColors: const [],
      willCreateUnits: const [],
      readyToImport: 2,
      restorableRows: restoresByFile[bytes.last] ?? 0,
      planId: planId,
      reviewRows: currentRows,
      fillRows: currentRows.where((row) => !row.hasConflicts).length,
      conflictRows: currentRows.where((row) => row.hasConflicts).length,
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
  }) async {
    commits++;
    submittedBytes.add(bytes);
    submittedPlans.add(planId);
    submittedSelections.add(Set.of(replaceRowKeys));
    submittedCorrections.add(freezeGoodsImportCorrections(cellCorrections));
    submittedExclusions.add(Set.of(excludedRowNums));
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [goodsImportRepositoryProvider.overrideWithValue(repository)],
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
              onPressed: () => showGoodsImportDialog(context, ref),
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
    find.byType(ImportReviewPage),
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

Future<void> _replace(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('import-review-select-all')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('import-review-confirm')));
  await tester.pumpAndSettle();
}

GoodsImportReport _problemReport({
  required List<int> ready,
  bool fixed = false,
}) => GoodsImportReport(
  totalRows: 4,
  dataRows: 3,
  errors: fixed
      ? const []
      : const [
          GoodsImportError(rowNum: 2, column: '编号', message: '编号重复'),
          GoodsImportError(rowNum: 3, column: '编号', message: '编号重复'),
        ],
  willCreateCategories: const [],
  willCreateColors: const [],
  willCreateUnits: const [],
  readyToImport: ready.length,
  restorableRows: 0,
  planId: ready.isEmpty ? null : 'plan:${ready.join(",")}',
  readyRowNums: ready,
  problemRows: fixed
      ? const []
      : const [
          GoodsImportProblemRow(
            rowNum: 2,
            code: 'DUP',
            name: '机壳',
            categoryPath: '成品',
          ),
          GoodsImportProblemRow(
            rowNum: 3,
            code: 'DUP',
            name: '配件',
            categoryPath: '成品',
          ),
        ],
);

void main() {
  late _Picker picker;
  setUp(() {
    picker = _Picker();
    FilePicker.platform = picker;
  });

  testWidgets('corrections and processed rows never leak into the next file', (
    tester,
  ) async {
    picker.files = _queueFiles([4, 5]);
    final repo = _Repository()
      ..reportFor = (bytes, edits, _) {
        if (bytes.last == 5 || edits[3]?['code'] == 'NEW') {
          return _problemReport(ready: [2, 3], fixed: true);
        }
        return _problemReport(ready: []);
      };
    await _open(tester, repo, expectReview: false);
    await tester.enterText(
      find.byKey(const ValueKey('goods-import-code-3')),
      'NEW',
    );
    await tester.tap(
      find.byKey(const ValueKey('goods-import-redetect-corrections')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(repo.commits, 2);
    expect(repo.submittedCorrections.first, {
      3: {'code': 'NEW'},
    });
    expect(repo.submittedCorrections.last, isEmpty);
    expect(repo.submittedExclusions.last, isEmpty);
    expect(repo.detectedExclusions.last, isEmpty);
  });

  testWidgets(
    'uncertain partial submission freezes corrections and exclusions',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, excluded) {
          if (edits[3]?['code'] != 'NEW' && excluded.isEmpty) {
            return _problemReport(ready: []);
          }
          return GoodsImportReport(
            totalRows: 4,
            dataRows: 3,
            errors: const [
              GoodsImportError(rowNum: 2, column: '价格', message: '价格无效'),
            ],
            willCreateCategories: const [],
            willCreateColors: const [],
            willCreateUnits: const [],
            readyToImport: excluded.isEmpty ? 2 : 0,
            restorableRows: 0,
            planId: excluded.isEmpty ? 'partial-plan' : null,
            readyRowNums: excluded.isEmpty ? const [3, 4] : const [],
            problemRows: const [
              GoodsImportProblemRow(
                rowNum: 2,
                code: 'P',
                name: '机壳',
                categoryPath: '成品',
              ),
            ],
          );
        };
      await _open(tester, repo, expectReview: false);
      await tester.enterText(
        find.byKey(const ValueKey('goods-import-code-3')),
        'NEW',
      );
      await tester.tap(
        find.byKey(const ValueKey('goods-import-redetect-corrections')),
      );
      await tester.pumpAndSettle();
      repo.rejection = NetworkTimeoutException();
      await tester.tap(find.byKey(const ValueKey('goods-import-import-ready')));
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      expect(repo.detections, 2);
      picker.select = () async => null;
      await tester.tap(find.text('重新选择'));
      await tester.pumpAndSettle();
      repo.rejection = null;
      await tester.tap(find.text('重试上次提交'));
      await tester.pumpAndSettle();
      expect(repo.commits, 2);
      expect(repo.submittedPlans, ['partial-plan', 'partial-plan']);
      expect(repo.submittedCorrections, [
        {
          3: {'code': 'NEW'},
        },
        {
          3: {'code': 'NEW'},
        },
      ]);
      expect(repo.submittedExclusions, [<int>{}, <int>{}]);
      expect(repo.detectedExclusions.last, {3, 4});
      expect(find.byType(GoodsImportProblemsPage), findsOneWidget);
    },
  );

  testWidgets(
    'a rejected correction stays editable and cannot use the old valid plan',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, edits, _) {
          if (edits[3]?['code'] == 'INVALID') {
            throw ApiException('VALIDATION_FAILED', '编号无效');
          }
          if (edits[3]?['code'] == 'NEW') {
            return _problemReport(ready: [2, 3, 4], fixed: true);
          }
          return _problemReport(ready: [4]);
        };
      await _open(tester, repo, expectReview: false);
      await tester.enterText(
        find.byKey(const ValueKey('goods-import-code-3')),
        'INVALID',
      );
      await tester.tap(
        find.byKey(const ValueKey('goods-import-redetect-corrections')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GoodsImportProblemsPage), findsOneWidget);
      expect(find.text('编号无效'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('goods-import-import-ready')),
        findsNothing,
      );
      expect(repo.commits, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      picker.select = () async => null;
      await tester.tap(find.text('重新选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入问题修复'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('goods-import-code-3')),
        'NEW',
      );
      await tester.tap(
        find.byKey(const ValueKey('goods-import-redetect-corrections')),
      );
      await tester.pumpAndSettle();
      expect(repo.commits, 0);
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      expect(repo.submittedCorrections.single, {
        3: {'code': 'NEW'},
      });
    },
  );

  testWidgets('detect opens full review and replaces only selected conflicts', (
    tester,
  ) async {
    final repo = _Repository();
    await _open(tester, repo);
    await _replace(tester);
    expect(repo.detections, 1);
    expect(repo.commits, 1);
    expect(repo.submittedSelections, [
      {'goods:2'},
    ]);
  });

  testWidgets('valid rows import first and corrected rows never replay them', (
    tester,
  ) async {
    final repo = _Repository()
      ..reportFor = (bytes, edits, excluded) => edits[3]?['code'] == 'G003'
          ? _problemReport(ready: [2, 3], fixed: true)
          : _problemReport(ready: excluded.contains(4) ? [] : [4]);
    await _open(tester, repo, expectReview: false);
    expect(find.byType(GoodsImportProblemsPage), findsOneWidget);
    expect(repo.commits, 0);
    await tester.tap(find.byKey(const ValueKey('goods-import-import-ready')));
    await tester.pumpAndSettle();
    expect(repo.commits, 1);
    expect(repo.detectedExclusions.last, {4});
    expect(find.byType(GoodsImportProblemsPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('goods-import-import-ready')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey('goods-import-code-3')),
      'G003',
    );
    await tester.tap(
      find.byKey(const ValueKey('goods-import-redetect-corrections')),
    );
    await tester.pumpAndSettle();
    expect(repo.commits, 1);
    expect(find.byType(GoodsImportProblemsPage), findsNothing);
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(repo.commits, 2);
    expect(repo.submittedExclusions, [
      <int>{},
      {4},
    ]);
    expect(repo.submittedCorrections.last, {
      3: {'code': 'G003'},
    });
    expect(repo.submittedBytes.last, same(repo.submittedBytes.first));
    expect(find.text('已完成 1/1 个文件'), findsOneWidget);
  });

  testWidgets(
    'problem edits survive return but do not write before redetection',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, _, _) => _problemReport(ready: []);
      await _open(tester, repo, expectReview: false);
      await tester.enterText(
        find.byKey(const ValueKey('goods-import-code-3')),
        'NEW',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(repo.commits, 0);
      expect(repo.detections, 1);
      await tester.tap(find.text('导入问题修复'));
      await tester.pumpAndSettle();
      expect(find.text('NEW'), findsOneWidget);
      expect(repo.detectedCorrections.single, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('goods-import-redetect-corrections')),
      );
      await tester.pumpAndSettle();
      expect(repo.detectedCorrections.last, {
        3: {'code': 'NEW'},
      });
      expect(repo.commits, 0);
    },
  );

  testWidgets(
    'successful rows remain excluded after the next detection fails',
    (tester) async {
      var failed = false;
      final repo = _Repository()
        ..reportFor = (_, _, excluded) {
          if (excluded.isNotEmpty && !failed) {
            failed = true;
            throw NetworkTimeoutException();
          }
          return _problemReport(ready: excluded.isEmpty ? [4] : []);
        };
      await _open(tester, repo, expectReview: false);
      await tester.tap(find.byKey(const ValueKey('goods-import-import-ready')));
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      expect(find.byType(GoodsImportProblemsPage), findsNothing);
      await tester.tap(find.text('重新检测当前文件'));
      await tester.pumpAndSettle();
      expect(repo.detectedExclusions, [
        <int>{},
        {4},
        {4},
      ]);
      expect(repo.commits, 1);
      expect(find.byType(GoodsImportProblemsPage), findsOneWidget);
    },
  );

  testWidgets('problem table repairs another cell before importing that row', (
    tester,
  ) async {
    final repo = _Repository()
      ..reportFor = (_, edits, _) {
        if (edits[2]?['price'] == '12.50') {
          return _problemReport(ready: [2], fixed: true);
        }
        return const GoodsImportReport(
          totalRows: 1,
          dataRows: 1,
          errors: [
            GoodsImportError(rowNum: 2, column: '价格', message: '价格必须是有效数字'),
          ],
          willCreateCategories: [],
          willCreateColors: [],
          willCreateUnits: [],
          readyToImport: 0,
          restorableRows: 0,
          planId: null,
          problemRows: [
            GoodsImportProblemRow(
              rowNum: 2,
              code: 'P1',
              name: '插座',
              categoryPath: '成品',
              cells: {
                'code': 'P1',
                'name': '插座',
                'categoryPath': '成品',
                'price': 'abc',
              },
            ),
          ],
        );
      };
    await _open(tester, repo, expectReview: false, size: const Size(1800, 900));
    expect(find.text('价格必须是有效数字', findRichText: true), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('goods-import-price-2')),
      '12.50',
    );
    await tester.tap(
      find.byKey(const ValueKey('goods-import-redetect-corrections')),
    );
    await tester.pumpAndSettle();
    expect(repo.detectedCorrections.last, {
      2: {'price': '12.50'},
    });
    expect(repo.commits, 0);
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(repo.commits, 1);
    expect(repo.submittedCorrections.single, {
      2: {'price': '12.50'},
    });
  });

  testWidgets(
    'problem table actions stay reachable on a narrow large-text screen',
    (tester) async {
      final repo = _Repository()
        ..reportFor = (_, _, _) => _problemReport(ready: [4]);
      await _open(
        tester,
        repo,
        expectReview: false,
        size: const Size(390, 844),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('goods-import-import-ready')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find
            .byKey(const ValueKey('goods-import-redetect-corrections'))
            .hitTestable(),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(repo.commits, 0);
    },
  );

  testWidgets('detection failure stays visible and retries the retained file', (
    tester,
  ) async {
    final repo = _Repository()
      ..detectionRejection = ApiException('RATE_LIMITED', '当前已有商品导入任务，请稍后重试');
    await _open(tester, repo, expectReview: false);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('当前已有商品导入任务，请稍后重试'), findsOneWidget);
    expect(repo.commits, 0);
    repo.detectionRejection = null;
    await tester.tap(find.text('重新检测当前文件'));
    await tester.pumpAndSettle();
    expect(picker.selections, 1);
    expect(repo.detectedBytes.last, same(repo.detectedBytes.first));
    expect(find.byType(ImportReviewPage), findsOneWidget);
    await _replace(tester);
    expect(repo.commits, 1);
  });

  testWidgets(
    'file read failure stays visible and a new selection can import',
    (tester) async {
      picker.files = [
        PlatformFile(name: 'empty.xlsx', size: 0, bytes: Uint8List(0)),
      ];
      final repo = _Repository();
      await _open(tester, repo, expectReview: false);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('所选 Excel 文件为空，请重新选择'), findsOneWidget);
      expect(find.text('重新检测当前文件'), findsNothing);
      expect(repo.detections, 0);
      expect(repo.commits, 0);
      picker.files = _queueFiles([1]);
      await tester.tap(find.text('选择 Excel 文件'));
      await tester.pumpAndSettle();
      await _replace(tester);
      expect(repo.detections, 1);
      expect(repo.commits, 1);
    },
  );

  testWidgets(
    'ignore all still commits additions and fills without conflicts',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      await tester.tap(find.byKey(const ValueKey('import-review-ignore-all')));
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      expect(repo.submittedSelections.single, isEmpty);
      expect(repo.submittedPlans, ['plan:first']);
    },
  );

  testWidgets('cancel review performs zero writes and keeps detection report', (
    tester,
  ) async {
    final repo = _Repository();
    await _open(tester, repo);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(repo.commits, 0);
    expect(find.byType(ImportReviewPage), findsNothing);
    expect(find.text('核对差异并导入'), findsOneWidget);
  });

  testWidgets('fill-only detection requires explicit full-page confirmation', (
    tester,
  ) async {
    final repo = _Repository()..reviewRows = [_fill];
    await _open(tester, repo);
    expect(find.text('确认补齐并导入'), findsOneWidget);
    expect(repo.commits, 0);
    await tester.tap(find.byKey(const ValueKey('import-review-confirm')));
    await tester.pumpAndSettle();
    expect(repo.commits, 1);
    expect(repo.submittedSelections.single, isEmpty);
  });

  testWidgets('a concurrent change requires redetection of the exact file', (
    tester,
  ) async {
    final repo = _Repository()
      ..rejection = ApiException('CONFLICT', '资料已变更，请重新检测');
    await _open(tester, repo);
    await _replace(tester);
    expect(repo.commits, 1);
    expect(find.text('核对差异并导入'), findsNothing);
    expect(find.text('重新检测当前文件'), findsOneWidget);
    repo
      ..planId = 'plan:latest'
      ..rejection = null;
    await tester.tap(find.text('重新检测当前文件'));
    await tester.pumpAndSettle();
    expect(repo.detections, 2);
    expect(picker.selections, 1);
    expect(repo.detectedBytes[1], same(repo.detectedBytes[0]));
    expect(repo.commits, 1);
    expect(find.byType(ImportReviewPage), findsOneWidget);
    await _replace(tester);
    expect(repo.submittedPlans, ['plan:first', 'plan:latest']);
  });

  testWidgets('uncertain retry preserves the original plan and row decision', (
    tester,
  ) async {
    final repo = _Repository()..rejection = NetworkTimeoutException();
    await _open(tester, repo);
    await _replace(tester);
    expect(repo.commits, 1);
    expect(find.text('重试上次提交'), findsOneWidget);
    repo.rejection = null;
    await tester.tap(find.text('重试上次提交'));
    await tester.pumpAndSettle();
    expect(repo.detections, 1);
    expect(repo.submittedPlans, ['plan:first', 'plan:first']);
    expect(repo.submittedSelections, [
      {'goods:2'},
      {'goods:2'},
    ]);
    expect(repo.submittedBytes[1], same(repo.submittedBytes[0]));
  });

  testWidgets('an accepted review locks dismissal until the commit finishes', (
    tester,
  ) async {
    final repo = _Repository()..pending = Completer<GoodsImportResult>();
    await _open(tester, repo);
    await tester.tap(find.byKey(const ValueKey('import-review-select-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-review-confirm')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(repo.commits, 1);
    expect(find.text('导入货品'), findsOneWidget);
    expect(find.text('确认导入'), findsNothing);
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
    expect(repo.commits, 1);
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets(
    'a mixed restoration and conflict shows the restore report before review',
    (tester) async {
      final repo = _Repository()..restoresByFile[4] = 1;
      await _open(tester, repo, expectReview: false);
      expect(find.textContaining('1 条编号与已删除货品相同'), findsOneWidget);
      expect(find.byType(ImportReviewPage), findsNothing);
      expect(repo.commits, 0);
      await tester.tap(find.text('核对差异并导入'));
      await tester.pumpAndSettle();
      expect(find.byType(ImportReviewPage), findsOneWidget);
      expect(repo.commits, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.textContaining('1 条编号与已删除货品相同'), findsOneWidget);
      expect(repo.commits, 0);
      await tester.tap(find.text('核对差异并导入'));
      await tester.pumpAndSettle();
      await _replace(tester);
      expect(repo.commits, 1);
    },
  );

  testWidgets(
    'a later file that restores deleted goods requires its own confirmation',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..reviewRows = []
        ..restoresByFile[2] = 1;
      await _open(tester, repo, expectReview: false);
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2']);
      expect(find.textContaining('1 条编号与已删除货品相同'), findsOneWidget);
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      expect(repo.events, [
        'detect:1',
        'commit:1',
        'detect:2',
        'commit:2',
        'detect:3',
        'commit:3',
      ]);
    },
  );

  testWidgets('multiple files detect only after the previous file commits', (
    tester,
  ) async {
    picker.files = _queueFiles([1, 2, 3]);
    final repo = _Repository()..reviewRows = [];
    await _open(tester, repo, expectReview: false);
    expect(picker.multipleRequested, isTrue);
    expect(repo.events, ['detect:1']);
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(repo.events, [
      'detect:1',
      'commit:1',
      'detect:2',
      'commit:2',
      'detect:3',
      'commit:3',
    ]);
    expect(find.text('已完成 3/3 个文件'), findsOneWidget);
    expect(repo.submittedBytes.map((bytes) => bytes.last), [1, 2, 3]);
  });

  testWidgets(
    'later conflict pauses at its file and can resume the remaining queue',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..reviewRows = []
        ..reviewsByFile[2] = [_conflict];
      await _open(tester, repo, expectReview: false);
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2']);
      expect(find.textContaining('货品-2.xlsx'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      expect(find.text('已完成 1/3 个文件'), findsOneWidget);
      await tester.tap(find.text('核对差异并导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-review-ignore-all')));
      await tester.pumpAndSettle();
      expect(repo.events, [
        'detect:1',
        'commit:1',
        'detect:2',
        'commit:2',
        'detect:3',
        'commit:3',
      ]);
      expect(repo.submittedSelections[1], isEmpty);
    },
  );

  testWidgets(
    'a failed later file retains successful outcomes and rechecks itself',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..reviewRows = []
        ..rejectionsByFile[2] = ApiException('CONFLICT', '资料已变更');
      await _open(tester, repo, expectReview: false);
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2', 'commit:2']);
      expect(find.text('已完成 1/3 个文件'), findsOneWidget);
      repo.rejectionsByFile.clear();
      await tester.ensureVisible(find.text('重新检测当前文件'));
      await tester.tap(find.text('重新检测当前文件'));
      await tester.pumpAndSettle();
      expect(repo.commits, 2);
      expect(repo.detectedBytes[2], same(repo.detectedBytes[1]));
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      expect(repo.events.where((event) => event == 'commit:1'), hasLength(1));
      expect(repo.events.last, 'commit:3');
      expect(find.text('已完成 3/3 个文件'), findsOneWidget);
    },
  );

  testWidgets(
    'reselecting replaces only pending files and retains prior successes',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..reviewRows = []
        ..reviewsByFile[2] = [_conflict];
      await _open(tester, repo, expectReview: false);
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      picker.files = _queueFiles([4]);
      await tester.tap(find.text('重新选择'));
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      expect(find.text('已完成 1/2 个文件'), findsOneWidget);
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      expect(repo.submittedBytes.map((bytes) => bytes.last), [1, 4]);
      expect(repo.events.where((event) => event == 'detect:3'), isEmpty);
      expect(find.text('已完成 2/2 个文件'), findsOneWidget);
    },
  );

  testWidgets('dropping files queues every workbook in its original order', (
    tester,
  ) async {
    final repo = _Repository()..reviewRows = [];
    await _open(tester, repo, pick: false);
    tester
        .widget<UtenDropTarget>(find.byType(UtenDropTarget))
        .onFiles(_queueFiles([1, 2]));
    await tester.pumpAndSettle();
    expect(repo.events, ['detect:1']);
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(repo.events, ['detect:1', 'commit:1', 'detect:2', 'commit:2']);
  });

  testWidgets(
    'canceling a replacement picker retains an uncertain submission',
    (tester) async {
      final repo = _Repository()..rejection = NetworkTimeoutException();
      await _open(tester, repo);
      await _replace(tester);
      picker.select = () async => null;
      await tester.tap(find.text('重新选择'));
      await tester.pumpAndSettle();
      expect(find.text('重试上次提交'), findsOneWidget);
      repo.rejection = null;
      await tester.tap(find.text('重试上次提交'));
      await tester.pumpAndSettle();
      expect(repo.detections, 1);
      expect(repo.submittedPlans, ['plan:first', 'plan:first']);
      expect(repo.submittedSelections, [
        {'goods:2'},
        {'goods:2'},
      ]);
    },
  );

  testWidgets(
    'narrow large-text queue can close after a later review is paused',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..reviewRows = []
        ..reviewsByFile[2] = [_conflict];
      await _open(
        tester,
        repo,
        expectReview: false,
        size: const Size(390, 844),
        textScale: 2,
      );
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('已完成 1/3 个文件'), findsOneWidget);
      final close = find.byIcon(Icons.close_rounded);
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2']);
      expect(find.text('打开'), findsOneWidget);
    },
  );
}
