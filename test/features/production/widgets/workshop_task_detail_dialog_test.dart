import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/models/production_flow_stage.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/widgets/workshop_task_detail_dialog.dart';
import 'package:uten_imp/features/production/widgets/workshop_task_material_table.dart';

const _previewBoundary = Key('workshop-task-detail-preview');
const _generatePreviews = bool.fromEnvironment(
  'UPDATE_WORKSHOP_DETAIL_PREVIEWS',
);

void main() {
  setUpAll(() async {
    // Real Chinese glyphs make layout checks and optional previews reflect the app.
    final fontLoader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'));
    await fontLoader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'desktop presents task facts and hides zero secondary quantities',
    (tester) async {
      await _pumpDialog(tester, size: const Size(1440, 960));

      expect(find.text('V5一开单控功能件'), findsOneWidget);
      expect(find.text('ZX00000339'), findsOneWidget);
      expect(find.text('计划：SJ20261011000054'), findsOneWidget);
      expect(find.text('已报工'), findsOneWidget);
      expect(find.text('待报工'), findsOneWidget);
      expect(find.textContaining('其中超产'), findsNothing);
      expect(find.textContaining('公共超产实收'), findsNothing);
      expect(find.textContaining('草稿待审核'), findsNothing);
      expect(find.text('V5一开单控10A后座（带UTEN）'), findsOneWidget);
      expect(find.text('V5一开压板'), findsNothing);
      expect(find.text('展开查看全部物料（共 4 项）'), findsOneWidget);
      _expectQuantityColumns(tester, columns: 4);
      expect(tester.takeException(), isNull);
      await _writePreview(tester, 'desktop');
    },
  );

  for (final width in [375.0, 768.0]) {
    testWidgets(
      '$width wide dialog shows two quantity columns and usable actions',
      (tester) async {
        var reports = 0;
        var records = 0;
        await _pumpDialog(
          tester,
          size: Size(width, 812),
          onReport: () => reports++,
          onRecord: () => records++,
        );

        _expectQuantityColumns(tester, columns: 2);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('报工'));
        await tester.pump();
        await tester.tap(find.text('查看用料记录'));
        await tester.pump();
        expect(reports, 1);
        expect(records, 1);
        expect(tester.takeException(), isNull);
        if (width == 375) {
          final close = tester.getRect(find.text('关闭'));
          final plan = tester.getRect(find.text('查看生产计划'));
          final record = tester.getRect(find.text('查看用料记录'));
          final report = tester.getRect(find.byType(FilledButton).last);
          expect(close.center.dy, plan.center.dy);
          expect(plan.center.dy, record.center.dy);
          expect(report.top, greaterThan(record.bottom));
          expect(report.width, greaterThan(280));
          await _writePreview(tester, 'mobile');
        } else {
          await _writePreview(tester, 'tablet');
        }
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(WorkshopTaskDetailDialog), findsNothing);
      },
    );
  }

  testWidgets('dark theme remains readable with the same facts and actions', (
    tester,
  ) async {
    await _pumpDialog(tester, size: const Size(1440, 960), dark: true);
    final context = tester.element(find.byType(WorkshopTaskDetailDialog));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(find.text('11000 个'), findsWidgets);
    expect(find.text('报工'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _writePreview(tester, 'dark');
  });

  for (final width in [375.0, 768.0, 1440.0]) {
    testWidgets(
      '$width wide long facts and large quantities at 1.4 text scale',
      (tester) async {
        var reports = 0;
        await _pumpDialog(
          tester,
          size: Size(width, width == 375 ? 812 : 960),
          textScale: 1.4,
          task: _task(
            longNames: true,
            plannedQty: 123456789012.1234,
            reportedQty: 12345678901.1234,
            actualSurplusReportedQty: 12345.5,
            actualSurplusInboundQty: 123.5,
          ),
          draftReportedQty: 99999999,
          onReport: () => reports++,
        );

        expect(find.textContaining('其中超产'), findsOneWidget);
        expect(find.textContaining('公共超产实收'), findsOneWidget);
        expect(find.textContaining('草稿待审核'), findsOneWidget);
        _expectQuantityColumns(tester, columns: width == 375 ? 1 : 2);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('报工'));
        await tester.pump();
        expect(reports, 1);
        expect(tester.takeException(), isNull);
        if (width == 375) await _writePreview(tester, 'mobile-large');
      },
    );
  }

  testWidgets(
    'long material content scrolls while footer actions remain visible',
    (tester) async {
      var reports = 0;
      await _pumpDialog(
        tester,
        size: const Size(375, 812),
        textScale: 1.4,
        materialCount: 12,
        onReport: () => reports++,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('物料 1'), findsOneWidget);
      expect(find.text('物料 12'), findsNothing);
      final expandMaterials = find.byKey(
        const Key('workshop-task-material-toggle-all'),
      );
      await tester.ensureVisible(expandMaterials);
      await tester.tap(expandMaterials);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('物料 12'));
      await tester.pumpAndSettle();
      expect(find.text('物料 12'), findsOneWidget);
      await tester.tap(find.text('报工'));
      await tester.pump();
      expect(reports, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

void _expectQuantityColumns(WidgetTester tester, {required int columns}) {
  final rects = [
    for (final id in ['planned', 'reported', 'remaining', 'inbound'])
      tester.getRect(find.byKey(ValueKey('workshop-detail-quantity-$id'))),
  ];
  if (columns == 1) {
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].top, greaterThan(rects[i - 1].top));
      expect(rects[i].left, rects[0].left);
    }
    return;
  }
  expect(rects[0].top, rects[1].top);
  if (columns == 4) {
    expect(rects[0].top, rects[3].top);
  } else {
    expect(rects[2].top, greaterThan(rects[0].top));
    expect(rects[2].top, rects[3].top);
    expect(rects[0].left, rects[2].left);
  }
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  required Size size,
  bool dark = false,
  double textScale = 1,
  ProductionExecutionWorkbenchSegment? task,
  double draftReportedQty = 0,
  int materialCount = 4,
  VoidCallback? onReport,
  VoidCallback? onRecord,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final segment = task ?? _task(materialCount: materialCount);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
          _MaterialRepository(materialCount: materialCount),
        ),
      ],
      child: MaterialApp(
        theme: _withTestFonts(buildLightTheme()),
        darkTheme: _withTestFonts(buildDarkTheme()),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(key: _previewBoundary, child: child!),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => WorkshopTaskDetailDialog(
                    task: segment,
                    stage: const ProductionFlowStage(
                      route: ProductionFlowRoute.make,
                      key: 'MAKE_IN_PROGRESS',
                      label: '生产中 · 可报工',
                      tone: ProductionFlowTone.active,
                      stepIndex: 4,
                      stepCount: 6,
                    ),
                    routeBadge: const UtenStatusBadge(
                      icon: Icons.all_inclusive_rounded,
                      label: '持续生产',
                      type: UtenStatusBadgeType.fuchsia,
                    ),
                    remainingReportQty: segment.remainingReportQty,
                    draftReportedQty: draftReportedQty,
                    materialSummary: Text('已领 $materialCount/$materialCount 种'),
                    materials: [
                      WorkshopTaskMaterialTable(
                        segmentId: segment.segmentId,
                        unitFallback: segment.productUnitName,
                        compact: true,
                      ),
                    ],
                    actions: [
                      TextButton(onPressed: () {}, child: const Text('查看生产计划')),
                      TextButton(
                        onPressed: onRecord ?? () {},
                        child: const Text('查看用料记录'),
                      ),
                      FilledButton.icon(
                        onPressed: onReport ?? () {},
                        icon: const Icon(Icons.fact_check_outlined),
                        label: const Text('报工'),
                      ),
                    ],
                  ),
                ),
                child: const Text('打开车间任务'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开车间任务'));
  await tester.pumpAndSettle();
}

ThemeData _withTestFonts(ThemeData theme) {
  // Flutter's test renderer substitutes Ahem for unspecified font families.
  // Preserve the app's colors, sizes and weights while explicitly using its
  // Chinese family for component styles that rely on system fallback at runtime.
  ButtonStyle? withFont(ButtonStyle? style) => style?.copyWith(
    textStyle: WidgetStateProperty.resolveWith(
      (states) =>
          style.textStyle?.resolve(states)?.copyWith(fontFamily: 'NotoSansSC'),
    ),
  );
  return theme.copyWith(
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: theme.dialogTheme.titleTextStyle?.copyWith(
        fontFamily: 'NotoSansSC',
      ),
      contentTextStyle: theme.dialogTheme.contentTextStyle?.copyWith(
        fontFamily: 'NotoSansSC',
      ),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: theme.chipTheme.labelStyle?.copyWith(
        fontFamily: 'NotoSansSC',
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: withFont(theme.filledButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: withFont(theme.textButtonTheme.style),
    ),
  );
}

Future<void> _writePreview(WidgetTester tester, String suffix) async {
  if (!_generatePreviews) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_previewBoundary),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final output = File('build/task-detail-preview-$suffix.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _MaterialRepository extends ProductionExecutionWorkbenchRepository {
  _MaterialRepository({required this.materialCount}) : super(ApiClient(Dio()));

  final int materialCount;

  @override
  Future<List<ProductionWorkshopTaskMaterial>> workshopTaskMaterials(
    String segmentId,
  ) async {
    const names = ['V5一开单控10A后座（带UTEN）', 'V5一开压板', 'V5开关打子', 'V5开关滑杆组件'];
    const codes = ['V50014', 'V50010', 'V50026', 'V5ZJ001'];
    return [
      for (var index = 0; index < materialCount; index++)
        ProductionWorkshopTaskMaterial.fromJson({
          'demandId': 'demand-$index',
          'goodsName': materialCount == 4 ? names[index] : '物料 ${index + 1}',
          'goodsCode': materialCount == 4 ? codes[index] : 'V5M$index',
          'colorName': '深灰色',
          'unitName': '个',
          'supplyRoute': index == 3 ? 'SUBCONTRACT' : 'MAKE',
          'directSupply': false,
          'requiredQty': 11000,
          'issuedQty': 11000,
          'shortageQty': 0,
          'warehouseAvailableQty': 11000,
          'state': 'ISSUED',
        }),
    ];
  }
}

ProductionExecutionWorkbenchSegment _task({
  bool longNames = false,
  int materialCount = 4,
  double plannedQty = 11000,
  double reportedQty = 0,
  double actualSurplusReportedQty = 0,
  double actualSurplusInboundQty = 0,
}) => ProductionExecutionWorkbenchSegment(
  segmentId: 'segment-1',
  planId: 'plan-1',
  planNo: 'SJ20261011000054',
  segmentCode: 'ZX00000339',
  plannedQty: plannedQty,
  reportedQty: reportedQty,
  remainingReportQty: plannedQty - reportedQty,
  fqcPendingQty: 0,
  fqcPassedQty: 0,
  fqcFailedQty: 0,
  finishedInboundPendingQty: 0,
  inboundQty: 0,
  segmentStatus: 'IN_PROGRESS',
  materialStatus: 'READY',
  preparationStatus: 'READY',
  materialReady: true,
  warehouseReady: true,
  issued: true,
  canDispatch: false,
  canStart: false,
  canReport: true,
  canBatchReport: true,
  lockVersion: 1,
  zeroMaterial: false,
  actualSurplusReportedQty: actualSurplusReportedQty,
  actualSurplusInboundQty: actualSurplusInboundQty,
  continuousSupply: true,
  startRoute: 'CONTINUOUS',
  materialKindCount: materialCount,
  materialIssuedKindCount: materialCount,
  materialSupportedOutputQty: plannedQty,
  workshopName: longNames ? '装配第一车间长名称生产线负责部门及下属制造车间' : '装配第一车间',
  responsibleEmployeeName: longNames ? '负责人姓名较长且存在多位共同负责人甲乙丙丁' : '石磊',
  productCode: 'V5G001',
  productName: longNames ? 'V5一开单控功能件用于多种型号产品的特别长名称带附件与颜色规格说明' : 'V5一开单控功能件',
  productColorName: '深灰色',
  productUnitName: '个',
);
