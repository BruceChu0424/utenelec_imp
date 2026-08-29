import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}

ProductionWorkCardView _confirmedView() => const ProductionWorkCardView(
  planId: 'plan-1',
  planBillNo: 'PP-001',
  planBillDate: '2026-08-02',
  deliveryDate: '2026-08-08',
  packageId: 'package-1',
  packageStatus: 'CONFIRMED',
  executionModelVersion: 1,
  packageLockVersion: 3,
  confirmedAt: '2026-08-02T08:30:00Z',
  approverName: '审核员',
  warehouseId: 'warehouse-1',
  warehouseCode: 'WH-01',
  warehouseName: '原料仓',
  generatedAt: '2026-08-02T09:00:00Z',
  namePolicy: 'CURRENT_MASTER_DATA',
  cards: [
    ProductionWorkCard(
      segmentId: 'segment-1',
      segmentCode: 'SEG-001',
      sourcePlanItemId: 'item-1',
      sourceLineNo: 1,
      productNo: 'FLOW-001',
      productGoodsId: 'product-1',
      productCode: 'P-001',
      productName: '测试产品',
      productSpec: 'M8 x 30',
      productColorName: '黑色',
      productUnitName: '支',
      plannedQty: 10,
      status: 'READY',
      workshopName: '注塑车间',
      teamName: '一班',
      responsibleEmployeeName: '负责人',
      planBeginDate: '2026-08-03',
      planEndDate: '2026-08-05',
      salesOrderNo: 'SO-001',
      requestNote: '优先生产',
      drawBillNos: 'DRAW-001',
      materials: [
        ProductionWorkCardMaterial(
          demandId: 'demand-1',
          goodsId: 'material-1',
          goodsCode: 'M-001',
          goodsName: '测试物料',
          spec: 'ABS',
          colorName: '本色',
          unitName: 'kg',
          perProductQty: 2,
          requiredQty: 20,
          stockAllocatedQty: 20,
          shortageQty: 0,
          supplyRoute: 'BUY',
          demandStatus: 'ALLOCATED',
        ),
      ],
    ),
  ],
);
