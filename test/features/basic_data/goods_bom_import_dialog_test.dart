import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';
import 'package:uten_imp/features/basic_data/pages/import_review_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_import_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_import_dialog.dart';

class _Picker extends FilePicker {
  Future<FilePickerResult?> Function()? select;
  List<PlatformFile>? files;
  bool? multipleRequested;

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
    multipleRequested = allowMultiple;
    return select?.call() ??
        (files == null ? _file() : FilePickerResult(files!));
  }
}

FilePickerResult _file() => FilePickerResult([
  PlatformFile(
    name: 'bom.xlsx',
    size: 4,
    bytes: Uint8List.fromList([0x50, 0x4b, 3, 4]),
  ),
]);

class _Repository extends Fake implements GoodsBomImportRepository {
  int commits = 0;
  Completer<BomImportResult>? pending;
  String fingerprint = 'v1:first';
  ApiException? rejection;
  final submittedFingerprints = <String>[];
  final detectedFiles = <Uint8List>[];
  List<GoodsImportReviewRow> reviewRows = const [];
  final submittedSelections = <Set<String>>[];
  final submittedModes = <BomImportMode>[];
  final events = <String>[];
  final reviewsByFile = <int, List<GoodsImportReviewRow>>{};
  final rejectionsByFile = <int, ApiException>{};

  @override
  Future<BomImportReport> detect(String goodsId, Uint8List bytes) async {
    detectedFiles.add(bytes);
    events.add('detect:${bytes.last}');
    final currentRows = reviewsByFile[bytes.last] ?? reviewRows;
    return BomImportReport(
      totalRows: 1,
      errors: [],
      warnings: [],
      levelCounts: [1],
      readyToImport: 1,
      stateFingerprint: fingerprint,
      reviewRows: currentRows,
      conflictRows: currentRows.where((row) => row.hasConflicts).length,
      fillRows: currentRows.where((row) => !row.hasConflicts).length,
    );
  }

  @override
  Future<BomImportResult> commit(
    String goodsId,
    Uint8List bytes, {
    required BomImportMode mode,
    required String stateFingerprint,
    Set<String> replaceRowKeys = const {},
  }) async {
    commits++;
    submittedFingerprints.add(stateFingerprint);
    submittedSelections.add(Set.of(replaceRowKeys));
    submittedModes.add(mode);
    events.add('commit:${bytes.last}');
    if (rejectionsByFile[bytes.last] case final error?) throw error;
    if (rejection != null) throw rejection!;
    return pending?.future ??
        const BomImportResult(targets: 1, added: 1, removed: 0, levels: 1);
  }
}

Future<void> _open(
  WidgetTester tester,
  _Repository repository, {
  Size size = const Size(800, 600),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomImportRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showGoodsBomImport(
                context,
                ref,
                goodsId: 'parent',
                onImported: () {},
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('选择文件并检测'));
  await tester.pumpAndSettle();
  if (repository.reviewRows.isNotEmpty) {
    expect(find.byType(ImportReviewPage), findsOneWidget);
  } else {
    expect(find.text('导入'), findsOneWidget);
  }
}

const _bomConflict = GoodsImportReviewRow(
  rowKey: 'bom:2',
  rowNum: 2,
  code: 'PART-001',
  name: '支架',
  categoryPath: '',
  seq: '1.2',
  matchType: 'UUID',
  changes: [
    GoodsImportChange(
      field: 'designUsageQty',
      label: '设计使用数量',
      oldValue: '1',
      newValue: '2',
      kind: 'CONFLICT',
    ),
  ],
);

List<PlatformFile> _queueFiles(List<int> markers) => [
  for (final marker in markers)
    PlatformFile(
      name: 'BOM-$marker.xlsx',
      size: 4,
      bytes: Uint8List.fromList([0x50, 0x4b, 3, marker]),
    ),
];

void main() {
  late _Picker picker;
  setUp(() {
    picker = _Picker();
    FilePicker.platform = picker;
  });

  testWidgets(
    'conflict preserves file and requires a fresh detection before another commit',
    (tester) async {
      final repo = _Repository()
        ..rejection = ApiException('CONFLICT', 'BOM已更新，请重新检测');
      await _open(tester, repo);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(repo.submittedFingerprints, ['v1:first']);
      expect(find.text('导入'), findsNothing);
      expect(find.text('重新检测当前文件'), findsOneWidget);
      repo.fingerprint = 'v1:latest';
      repo.rejection = null;
      await tester.tap(find.text('重新检测当前文件'));
      await tester.pumpAndSettle();
      expect(repo.detectedFiles[1], same(repo.detectedFiles[0]));
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(repo.submittedFingerprints, ['v1:first', 'v1:latest']);
    },
  );

  testWidgets(
    'uncertain submission retries the same fingerprint without creating a new detection',
    (tester) async {
      final repo = _Repository()..rejection = NetworkTimeoutException();
      await _open(tester, repo);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      repo.rejection = null;
      await tester.tap(find.text('重试上次提交'));
      await tester.pumpAndSettle();

      expect(repo.detectedFiles, hasLength(1));
      expect(repo.submittedFingerprints, ['v1:first', 'v1:first']);
    },
  );

  testWidgets(
    'choosing another file invalidates the previous successful report immediately',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      final selection = Completer<FilePickerResult?>();
      picker.select = () => selection.future;

      await tester.tap(find.text('重新选择文件'));
      await tester.pump();

      expect(find.text('导入'), findsNothing);
      expect(repo.commits, 0);
      selection.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('导入'), findsNothing);
      expect(find.text('选择文件并检测'), findsOneWidget);
    },
  );

  testWidgets('a committing import cannot be dismissed or submitted twice', (
    tester,
  ) async {
    final repo = _Repository()..pending = Completer<BomImportResult>();
    await _open(tester, repo);
    await tester.tap(find.text('导入'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('导入组件'), findsOneWidget);
    expect(repo.commits, 1);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '正在导入…'))
          .onPressed,
      isNull,
    );

    repo.pending!.complete(
      const BomImportResult(targets: 1, added: 1, removed: 0, levels: 1),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('导入完成'), findsOneWidget);
  });

  testWidgets(
    'component differences open full review and cancel writes nothing',
    (tester) async {
      final repo = _Repository()..reviewRows = [_bomConflict];
      await _open(tester, repo);
      expect(repo.commits, 0);
      expect(find.text('客户型号'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ImportReviewPage), findsNothing);
      expect(repo.commits, 0);
      expect(find.text('核对差异并导入'), findsOneWidget);
    },
  );

  testWidgets('component review submits only selected conflict row keys', (
    tester,
  ) async {
    final repo = _Repository()..reviewRows = [_bomConflict];
    await _open(tester, repo);
    await tester.tap(find.byKey(const ValueKey('import-review-select-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-review-confirm')));
    await tester.pumpAndSettle();
    expect(repo.commits, 1);
    expect(repo.submittedModes, [BomImportMode.merge]);
    expect(repo.submittedSelections, [
      {'bom:2'},
    ]);
  });

  testWidgets(
    'ignoring component conflicts confirms a merge with no replacements',
    (tester) async {
      final repo = _Repository()..reviewRows = [_bomConflict];
      await _open(tester, repo);
      await tester.tap(find.byKey(const ValueKey('import-review-ignore-all')));
      await tester.pumpAndSettle();
      expect(repo.commits, 1);
      expect(repo.submittedModes, [BomImportMode.merge]);
      expect(repo.submittedSelections.single, isEmpty);
    },
  );

  testWidgets(
    'a new file resets the earlier append mode before opening review',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      await tester.ensureVisible(find.text('在现有组件后追加'));
      await tester.tap(find.text('在现有组件后追加'));
      await tester.pumpAndSettle();
      repo.reviewRows = [_bomConflict];
      await tester.ensureVisible(find.text('重新选择文件'));
      await tester.tap(find.text('重新选择文件'));
      await tester.pumpAndSettle();
      expect(find.byType(ImportReviewPage), findsOneWidget);
      expect(repo.commits, 0);
      await tester.tap(find.byKey(const ValueKey('import-review-ignore-all')));
      await tester.pumpAndSettle();
      expect(repo.submittedModes, [BomImportMode.merge]);
    },
  );

  testWidgets(
    'multiple component files run in order and reset mode for each file',
    (tester) async {
      picker.files = _queueFiles([1, 2]);
      final repo = _Repository();
      await _open(tester, repo);
      expect(picker.multipleRequested, isTrue);
      expect(repo.events, ['detect:1']);
      expect(repo.commits, 0);
      await tester.ensureVisible(find.text('在现有组件后追加'));
      await tester.tap(find.text('在现有组件后追加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2', 'commit:2']);
      expect(repo.submittedModes, [BomImportMode.append, BomImportMode.merge]);
      expect(find.text('已完成 2/2 个文件'), findsOneWidget);
    },
  );

  testWidgets(
    'later component review can pause and resume without repeating successes',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()..reviewsByFile[2] = [_bomConflict];
      await _open(tester, repo);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2']);
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
      expect(find.text('已完成 3/3 个文件'), findsOneWidget);
    },
  );

  testWidgets(
    'later component failure stops before the next file and retains bytes',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..rejectionsByFile[2] = ApiException('CONFLICT', 'BOM已更新');
      await _open(tester, repo);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2', 'commit:2']);
      repo.rejectionsByFile.clear();
      await tester.ensureVisible(find.text('重新检测当前文件'));
      await tester.tap(find.text('重新检测当前文件'));
      await tester.pumpAndSettle();
      expect(repo.detectedFiles[2], same(repo.detectedFiles[1]));
      expect(repo.commits, 2);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(repo.events.where((event) => event == 'commit:1'), hasLength(1));
      expect(repo.events.last, 'commit:3');
    },
  );

  testWidgets(
    'uncertain later component retry keeps its fingerprint and selection',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()
        ..reviewsByFile[2] = [_bomConflict]
        ..rejectionsByFile[2] = NetworkTimeoutException();
      await _open(tester, repo);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-review-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-review-confirm')));
      await tester.pumpAndSettle();
      expect(repo.commits, 2);
      expect(repo.detectedFiles, hasLength(2));
      repo
        ..fingerprint = 'v1:unrelated-new-version'
        ..rejectionsByFile.clear();
      await tester.tap(find.text('重试上次提交'));
      await tester.pumpAndSettle();
      expect(repo.submittedFingerprints.sublist(1, 3), [
        'v1:first',
        'v1:first',
      ]);
      expect(repo.submittedSelections.sublist(1, 3), [
        {'bom:2'},
        {'bom:2'},
      ]);
      expect(repo.events.last, 'commit:3');
    },
  );

  testWidgets(
    'canceling the BOM picker preserves an uncertain append attempt',
    (tester) async {
      final repo = _Repository()..rejection = NetworkTimeoutException();
      await _open(tester, repo);
      await tester.ensureVisible(find.text('在现有组件后追加'));
      await tester.tap(find.text('在现有组件后追加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      picker.select = () async => null;
      await tester.tap(find.text('重新选择文件'));
      await tester.pumpAndSettle();
      expect(find.text('重试上次提交'), findsOneWidget);
      repo.rejection = null;
      await tester.tap(find.text('重试上次提交'));
      await tester.pumpAndSettle();
      expect(repo.detectedFiles, hasLength(1));
      expect(repo.submittedModes, [BomImportMode.append, BomImportMode.append]);
      expect(repo.submittedFingerprints, ['v1:first', 'v1:first']);
    },
  );

  testWidgets(
    'narrow large-text component queue keeps pause and close usable',
    (tester) async {
      picker.files = _queueFiles([1, 2, 3]);
      final repo = _Repository()..reviewsByFile[2] = [_bomConflict];
      await _open(tester, repo, size: const Size(390, 844), textScale: 2);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final close = find.text('关闭');
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(repo.events, ['detect:1', 'commit:1', 'detect:2']);
      expect(find.text('打开'), findsOneWidget);
    },
  );
}
