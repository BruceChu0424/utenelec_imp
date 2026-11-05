import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_analysis_ownership_overlay.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

Map<String, dynamic> plan() => {
  'version': 1,
  'mode': 'BOM',
  'packaging': 'BULK',
  'bomFingerprint': 'frozen-bom',
  'nodeModes': [
    {
      'path': ['edge-a'],
      'mode': 'CHILDREN',
    },
  ],
  'processes': [
    {
      'path': ['edge-a', 'edge-b'],
      'operation': 'LASER',
      'required': true,
    },
  ],
};

void main() {
  test('candidate grouping retains delivery path and unit conversion', () {
    final page = MaterialAnalysisSalesCandidatePage.fromJson({
      'items': [
        {
          'orderId': 'order',
          'orderNo': 'XD-1',
          'lines': [
            {
              'salesOrderItemId': 'line',
              'unitRate': 12,
              'qty': 100,
              'deliveryPlan': plan(),
            },
          ],
        },
      ],
    });
    final row = page.lines.single;
    expect(row.unitRate, 12);
    expect(row.deliveryPlan!.bomFingerprint, 'frozen-bom');
    expect(row.deliveryPlan!.processes.single['path'], ['edge-a', 'edge-b']);
    expect(row.orderNo, 'XD-1');
  });

  test(
    'delivery parent is never a root production task even with stale readiness',
    () {
      final root = ProductionMaterialAnalysisProduct.fromJson({
        'analysisLineId': 'root',
        'deliveryPlan': plan(),
        'canSchedule': true,
        'readyNowQty': 100,
        'maxSchedulableQty': 100,
      });
      expect(root.isDeliveryContext, isTrue);
      expect(root.canSchedule, isFalse);
      expect(root.maxSchedulableQty, 0);
      expect(
        ProductionMaterialAnalysisProduct.fromJson({
          'analysisLineId': 'legacy',
          'readyNowQty': 2,
        }).canSchedule,
        isTrue,
      );
    },
  );

  test('ownership refresh preserves frozen delivery facts and processing', () {
    final current = ProductionMaterialAnalysisView.fromJson({
      'analysisId': 'analysis',
      'version': 7,
      'fingerprint': 'snapshot',
      'products': [
        {'analysisLineId': 'source', 'goodsId': 'g', 'deliveryPlan': plan()},
      ],
      'materials': [
        {
          'materialLineId': 'parent',
          'goodsId': 'g',
          'deliveryContext': true,
          'actionable': true,
          'deliveryOperations': ['LASER'],
        },
        {
          'materialLineId': 'child',
          'goodsId': 'g',
          'deliveryFrontier': true,
          'actionable': true,
          'requiredQty': 300,
          'deliveryOperations': ['LASER'],
        },
      ],
    });
    final fresh = ProductionMaterialAnalysisView.fromJson({
      'analysisId': 'analysis',
      'materials': [
        {'materialLineId': 'other', 'goodsId': 'g', 'owningWarehouseId': 'new'},
      ],
    });
    final merged = current.withOwnershipFrom(fresh);
    expect(merged.version, 7);
    expect(merged.products.single.deliveryPlan!.bomFingerprint, 'frozen-bom');
    expect(merged.materials.first.deliveryContext, isTrue);
    expect(merged.materials.first.actionable, isFalse);
    expect(merged.materials.last.deliveryFrontier, isTrue);
    expect(merged.materials.last.requiredQty, 300);
    expect(merged.materials.last.deliveryOperations, ['LASER']);
    expect(merged.materials.last.owningWarehouseId, 'new');
  });
}
