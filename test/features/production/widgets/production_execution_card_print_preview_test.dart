import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/models/production_work_card.dart';
import 'package:uten_imp/features/production/widgets/production_execution_card_print_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds an A4 PDF from confirmed persisted work-card facts', () async {
    final bytes = await buildProductionExecutionCardPdf(_confirmedView());

    expect(ascii.decode(bytes.take(4).toList()), '%PDF');
    expect(bytes.length, greaterThan(10000));
    final qaOutput = Platform.environment['UTEN_PDF_QA_OUTPUT'];
    if (qaOutput != null && qaOutput.trim().isNotEmpty) {
      final file = File(qaOutput);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: true);
    }
  });

  test('rejects draft or empty package projections', () async {
    const invalid = ProductionWorkCardView(
      planId: 'plan-1',
      packageId: 'package-1',
      packageStatus: 'DRAFT',
      executionModelVersion: 1,
      packageLockVersion: 0,
      warehouseId: 'warehouse-1',
      generatedAt: '2026-08-02T09:00:00Z',
      namePolicy: 'CURRENT_MASTER_DATA',
    );

    await expectLater(
      buildProductionExecutionCardPdf(invalid),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'labels linear and exact work-card usage without implying exact math',
    () {
      const linear = ProductionWorkCardMaterial(
        demandId: 'linear-demand',
        goodsId: 'material-1',
        perProductQty: 2,
        requiredQty: 20,
        stockAllocatedQty: 20,
        shortageQty: 0,
        supplyRoute: 'BUY',
        demandStatus: 'ALLOCATED',
      );
      const exact = ProductionWorkCardMaterial(
        demandId: 'exact-demand',
        goodsId: 'material-2',
        perProductQty: 0.333334,
        requiredQty: 2,
        stockAllocatedQty: 2,
        shortageQty: 0,
        supplyRoute: 'BUY',
        demandStatus: 'ALLOCATED',
        requirementMode: 'EXACT_SNAPSHOT',
      );

      expect(formatProductionWorkCardMaterialUsage(linear), '单支用量 2');
      expect(
        formatProductionWorkCardMaterialUsage(exact),
        '按包/批(本段平均) 0.333334',
      );
    },
  );

  test('builds a two-plan batch and exact single-segment PDF', () async {
    final first = _confirmedView();
    final second = _confirmedView(
      planId: 'plan-2',
      planBillNo: 'PP-002',
      packageId: 'package-2',
      segmentId: 'segment-2',
      segmentCode: 'SEG-002',
    );

    final batch = await buildProductionExecutionCardBatchPdf([first, second]);
    final one = await buildProductionExecutionCardPdf(
      first,
      segmentIds: const {'segment-1'},
    );

    expect(ascii.decode(batch.take(4).toList()), '%PDF');
    expect(ascii.decode(one.take(4).toList()), '%PDF');
    expect(batch.length, greaterThan(one.length));
    await expectLater(
      buildProductionExecutionCardPdf(
        first,
        segmentIds: const {'missing-segment'},
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      buildProductionExecutionCardPdf(first, segmentIds: const {}),
      throwsA(isA<StateError>()),
    );
  });

  test('batch printing fails closed for invalid or duplicate facts', () async {
    final valid = _confirmedView();
    final draft = _confirmedView(
      planId: 'plan-draft',
      planBillNo: 'PP-DRAFT',
      packageId: 'package-draft',
      segmentId: 'segment-draft',
      segmentCode: 'SEG-DRAFT',
      packageStatus: 'DRAFT',
    );
    final unknown = _confirmedView(cardStatus: 'FUTURE_STATUS');
    final samePlanOtherPackage = _confirmedView(
      packageId: 'package-other',
      segmentId: 'segment-other',
      segmentCode: 'SEG-OTHER',
    );
    final duplicateSegment = _confirmedView(
      planId: 'plan-other',
      planBillNo: 'PP-OTHER',
      packageId: 'package-other',
    );

    await expectLater(
      buildProductionExecutionCardBatchPdf(const []),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      buildProductionExecutionCardBatchPdf([valid, draft]),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      buildProductionExecutionCardBatchPdf([valid, valid]),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      buildProductionExecutionCardBatchPdf([unknown]),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      buildProductionExecutionCardBatchPdf([valid, samePlanOtherPackage]),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      buildProductionExecutionCardBatchPdf([valid, duplicateSegment]),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      buildProductionExecutionCardBatchPdf([
        for (var index = 0; index < 51; index++)
          _confirmedView(
            planId: 'plan-$index',
            planBillNo: 'PP-$index',
            packageId: 'package-$index',
            segmentId: 'segment-$index',
            segmentCode: 'SEG-$index',
          ),
      ]),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      buildProductionExecutionCardPdf(
        _confirmedView(cardCount: 2),
        segmentIds: const {'segment-1-1', 'missing-segment'},
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('builds a long-table batch PDF for render QA', () async {
    final bytes = await buildProductionExecutionCardBatchPdf([
      _confirmedView(materialCount: 60),
      _confirmedView(
        planId: 'plan-zero',
        planBillNo: 'PP-ZERO',
        packageId: 'package-zero',
        segmentId: 'segment-zero',
        segmentCode: 'SEG-ZERO',
        zeroMaterial: true,
      ),
    ]);

    expect(ascii.decode(bytes.take(4).toList()), '%PDF');
    expect(bytes.length, greaterThan(30000));
    final qaOutput = Platform.environment['UTEN_PDF_BATCH_QA_OUTPUT'];
    if (qaOutput != null && qaOutput.trim().isNotEmpty) {
      final file = File(qaOutput);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: true);
    }
  });

  testWidgets(
    'preview retries and reloads before one-card and whole-plan printing',
    (tester) async {
      var loadCount = 0;
      final printedNames = <String>[];
      final printedBytes = <List<int>>[];
      final view = _confirmedView();

      Future<List<ProductionWorkCardView>> loader() async {
        loadCount++;
        if (loadCount == 1) throw StateError('首次读取失败');
        return [view];
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showProductionExecutionCardBatchPrintPreview(
                  context,
                  loader: loader,
                  printer: (bytes, filename) async {
                    printedNames.add(filename);
                    printedBytes.add(bytes);
                    return true;
                  },
                ),
                child: const Text('打开打印预览'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开打印预览'));
      await tester.pumpAndSettle();
      expect(find.text('首次读取失败'), findsOneWidget);

      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(loadCount, 2);
      expect(find.textContaining('1 张生产计划、1 张执行工卡。'), findsOneWidget);
      expect(find.text('已齐套待派工'), findsOneWidget);
      expect(find.textContaining('仍须仓库实际发料完成后'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('production-work-card-print-segment-1')),
      );
      await tester.pumpAndSettle();
      expect(loadCount, 3);
      expect(printedNames.single, contains('SEG-001'));
      expect(ascii.decode(printedBytes.single.take(4).toList()), '%PDF');

      await tester.tap(find.text('打印全部（1 张工卡）'));
      await tester.pumpAndSettle();
      expect(loadCount, 4);
      expect(printedNames, hasLength(2));
      expect(printedNames.last, contains('PP-001'));
      expect(ascii.decode(printedBytes.last.take(4).toList()), '%PDF');
    },
  );

  testWidgets('two-plan batch reloads once and calls printer once', (
    tester,
  ) async {
    var loadCount = 0;
    var printCount = 0;
    String? printedName;
    final views = [
      _confirmedView(),
      _confirmedView(
        planId: 'plan-2',
        planBillNo: 'PP-002',
        packageId: 'package-2',
        segmentId: 'segment-2',
        segmentCode: 'SEG-002',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showProductionExecutionCardBatchPrintPreview(
                context,
                loader: () async {
                  loadCount++;
                  return views;
                },
                printer: (bytes, filename) async {
                  printCount++;
                  printedName = filename;
                  expect(ascii.decode(bytes.take(4).toList()), '%PDF');
                  return true;
                },
              ),
              child: const Text('打开两计划批量打印'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开两计划批量打印'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 张生产计划 · 2 张执行工卡'), findsOneWidget);
    await tester.tap(find.text('打印全部（2 张工卡）'));
    await tester.pumpAndSettle();
    expect(loadCount, 2);
    expect(printCount, 1);
    expect(printedName, contains('批量2张计划_2张工卡'));
  });

  testWidgets('completed cards are marked archival only', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showProductionExecutionCardPrintPreview(
                context,
                loader: () async => _confirmedView(cardStatus: 'COMPLETED'),
                printer: (_, _) async => true,
              ),
              child: const Text('打开已完成工卡'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开已完成工卡'));
    await tester.pumpAndSettle();
    expect(find.text('已完成 · 仅供存档'), findsOneWidget);
    expect(find.textContaining('不得再次作为开工'), findsOneWidget);
  });

  testWidgets('pre-print invalidation never calls printer', (tester) async {
    var loadCount = 0;
    var printCount = 0;
    Future<ProductionWorkCardView> loader() async {
      loadCount++;
      return loadCount == 1
          ? _confirmedView()
          : _confirmedView(cardStatus: 'FUTURE_STATUS');
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showProductionExecutionCardPrintPreview(
                  context,
                  loader: loader,
                  printer: (_, _) async {
                    printCount++;
                    return true;
                  },
                ),
                child: const Text('打开失效测试'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开失效测试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打印全部（1 张工卡）'));
    await tester.pumpAndSettle();
    expect(loadCount, 2);
    expect(printCount, 0);
  });

  testWidgets('printer cancellation reports an incomplete flow', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          builder: (context, child) => Stack(
            children: [
              child!,
              const Align(
                alignment: Alignment.topCenter,
                child: AppNotificationHost(),
              ),
            ],
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showProductionExecutionCardPrintPreview(
                  context,
                  loader: () async => _confirmedView(),
                  printer: (_, _) async => false,
                ),
                child: const Text('打开取消打印测试'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开取消打印测试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打印全部（1 张工卡）'));
    await tester.pumpAndSettle();
    expect(find.text('打印流程未完成'), findsOneWidget);
  });
}

ProductionWorkCardView _confirmedView({
  String planId = 'plan-1',
  String planBillNo = 'PP-001',
  String packageId = 'package-1',
  String segmentId = 'segment-1',
  String segmentCode = 'SEG-001',
  String packageStatus = 'CONFIRMED',
  String cardStatus = 'READY',
  int materialCount = 1,
  int cardCount = 1,
  bool zeroMaterial = false,
}) => ProductionWorkCardView(
  planId: planId,
  planBillNo: planBillNo,
  planBillDate: '2026-08-02',
  deliveryDate: '2026-08-08',
  packageId: packageId,
  packageStatus: packageStatus,
  executionModelVersion: 1,
  packageLockVersion: 3,
  confirmedAt: '2026-08-02T08:30:00Z',
  approverName: '审核员',
  warehouseId: 'warehouse-1',
  warehouseCode: 'WH-01',
  warehouseName: '原料仓',
  generatedAt: '2026-08-02T09:00:00Z',
  namePolicy: 'CURRENT_MASTER_DATA',
  cards: List.generate(cardCount, (cardIndex) {
    final number = cardIndex + 1;
    return ProductionWorkCard(
      segmentId: cardCount == 1 ? segmentId : '$segmentId-$number',
      segmentCode: cardCount == 1 ? segmentCode : '$segmentCode-$number',
      sourcePlanItemId: 'item-1',
      sourceLineNo: 1,
      productNo: 'FLOW-${number.toString().padLeft(3, '0')}',
      productGoodsId: 'product-$number',
      productCode: 'P-${number.toString().padLeft(3, '0')}',
      productName: '测试产品 $number',
      productSpec: 'M8 x 30',
      productColorName: '黑色',
      productUnitName: '支',
      plannedQty: 10,
      status: cardStatus,
      materialRequirementMode: zeroMaterial ? 'ZERO_MATERIAL' : 'DEMANDED',
      zeroMaterialReason: zeroMaterial ? 'DIRECT_MAKE' : null,
      workshopName: '注塑车间',
      teamName: '一班',
      responsibleEmployeeName: '负责人',
      planBeginDate: '2026-08-03',
      planEndDate: '2026-08-05',
      salesOrderNo: 'SO-001',
      requestNote: '优先生产',
      drawBillNos: zeroMaterial ? null : 'DRAW-001',
      materials: List.generate(zeroMaterial ? 0 : materialCount, (
        materialIndex,
      ) {
        final materialNumber = materialIndex + 1;
        final code = materialNumber.toString().padLeft(3, '0');
        return ProductionWorkCardMaterial(
          demandId: 'demand-$number-$materialNumber',
          goodsId: 'material-$number-$materialNumber',
          goodsCode: 'M-$code',
          goodsName: '长名称测试物料 $materialNumber',
          spec: 'ABS 规格 $materialNumber',
          colorName: materialIndex.isEven ? '本色' : '黑色',
          unitName: 'kg',
          perProductQty: 2,
          requiredQty: 20,
          stockAllocatedQty: 20,
          shortageQty: 0,
          supplyRoute: 'BUY',
          demandStatus: 'ALLOCATED',
        );
      }),
    );
  }),
);
