import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_import_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_import_dialog.dart';

class _Picker extends FilePicker {
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
  }) async => select?.call() ?? _file();
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

  @override
  Future<BomImportReport> detect(String goodsId, Uint8List bytes) async {
    detectedFiles.add(bytes);
    return BomImportReport(
      totalRows: 1,
      errors: [],
      warnings: [],
      levelCounts: [1],
      readyToImport: 1,
      stateFingerprint: fingerprint,
    );
  }

  @override
  Future<BomImportResult> commit(
    String goodsId,
    Uint8List bytes, {
    required BomImportMode mode,
    required String stateFingerprint,
  }) async {
    commits++;
    submittedFingerprints.add(stateFingerprint);
    if (rejection != null) throw rejection!;
    return pending?.future ??
        const BomImportResult(targets: 1, added: 1, removed: 0, levels: 1);
  }
}

Future<void> _open(WidgetTester tester, _Repository repository) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomImportRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
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
  expect(find.text('导入'), findsOneWidget);
}

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
}
