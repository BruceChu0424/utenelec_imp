// 导入模式三选一弹窗（2026-10-28）：入口先选「新建货品/修改货品/混合导入」，
// 所选模式贯穿 detect/commit；标题旁的胶囊标注当前模式。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_import_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_import_mode_picker.dart';

class _Picker extends FilePicker {
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
    return FilePickerResult([
      PlatformFile(
        name: '新建货品.xlsx',
        size: 4,
        bytes: Uint8List.fromList([0x50, 0x4b, 3, 4]),
      ),
    ]);
  }
}

class _Repository extends Fake implements GoodsImportRepository {
  final detectedModes = <GoodsImportMode?>[];
  final committedModes = <GoodsImportMode?>[];

  @override
  Future<GoodsImportReport> detect(
    Uint8List bytes, {
    Map<int, String> codeCorrections = const {},
    GoodsImportCorrections cellCorrections = const {},
    Set<int> excludedRowNums = const {},
    GoodsImportMode? mode,
  }) async {
    detectedModes.add(mode);
    return const GoodsImportReport(
      totalRows: 1,
      dataRows: 1,
      errors: [],
      willCreateCategories: [],
      willCreateColors: [],
      willCreateUnits: [],
      readyToImport: 1,
      restorableRows: 0,
      planId: 'plan:1',
      readyRowNums: [2],
      previewRows: [
        GoodsImportProblemRow(
          rowNum: 2,
          code: '',
          name: '新货品',
          categoryPath: '成品 / 开关',
          cells: {'name': '新货品', 'categoryPath': '成品 / 开关'},
        ),
      ],
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
    committedModes.add(mode);
    return const GoodsImportResult(
      batchId: 'batch:1',
      importedCount: 1,
      createdCategories: 0,
      createdColors: 0,
      createdUnits: 0,
      createdCategoryPaths: [],
    );
  }
}

Future<void> _pumpEntry(
  WidgetTester tester,
  _Repository repository, {
  double textScale = 1,
}) async {
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
              onPressed: () => showGoodsImportWithModePicker(context, ref),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    FilePicker.platform = _Picker();
  });

  testWidgets('the chosen mode rides detection and commit', (tester) async {
    final repository = _Repository();
    await _pumpEntry(tester, repository);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('选择导入方式'), findsOneWidget);
    expect(find.text('新建货品'), findsOneWidget);
    expect(find.text('修改货品'), findsOneWidget);
    expect(find.text('混合导入'), findsOneWidget);

    await tester.tap(find.text('新建货品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 导入弹窗已带模式胶囊；后续检测与提交都携带同一模式。
    expect(find.text('导入货品'), findsOneWidget);
    await tester.tap(find.text('选择 Excel 文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认导入 1 条'));
    await tester.pumpAndSettle();

    expect(repository.detectedModes, [GoodsImportMode.createOnly]);
    expect(repository.committedModes, [GoodsImportMode.createOnly]);
  });

  testWidgets('confirming without changing keeps the mixed default', (
    tester,
  ) async {
    final repository = _Repository();
    await _pumpEntry(tester, repository);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择 Excel 文件'));
    await tester.pumpAndSettle();

    expect(repository.detectedModes, [GoodsImportMode.mixed]);
  });

  testWidgets('cancelling the picker never opens the import dialog', (
    tester,
  ) async {
    final repository = _Repository();
    await _pumpEntry(tester, repository);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('导入货品'), findsNothing);
    expect(repository.detectedModes, isEmpty);
  });

  testWidgets(
    'mode selection stays clear and usable on narrow large-text screens',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpEntry(tester, _Repository(), textScale: 2);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('goods-import-mode-MIXED')),
            )
            .properties
            .selected,
        isTrue,
      );
      await tester.ensureVisible(find.text('修改货品'));
      await tester.tap(find.text('修改货品'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('goods-import-mode-UPDATE_ONLY')),
            )
            .properties
            .selected,
        isTrue,
      );
      expect(find.text('同时处理新增和修改'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('选择导入方式'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
