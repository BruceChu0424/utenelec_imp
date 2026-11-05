import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/delivery/order_delivery_plan.dart';
import 'package:uten_imp/shared/delivery/order_delivery_repository.dart';

void main() {
  test(
    'unknown and malformed plan fields remain read-only without throwing or erasing raw evidence',
    () {
      final valid = OrderDeliveryPlan.assembled().toJson();
      final cases = <Map<String, dynamic>>[
        {...valid, 'version': '1'},
        {...valid, 'version': 1.5},
        {...valid, 'version': 1.0},
        {...valid, 'version': 2},
        {...valid, 'mode': 'FUTURE'},
        {...valid, 'packaging': 'FUTURE'},
        {
          ...valid,
          'nodeModes': [
            {
              'path': [123],
              'mode': 'WHOLE',
            },
          ],
        },
        {
          ...valid,
          'nodeModes': [
            {
              'path': ['edge'],
              'mode': 'FUTURE',
            },
          ],
        },
        {
          ...valid,
          'processes': [
            {
              'path': ['edge'],
              'operation': 'LASER',
              'required': false,
            },
          ],
        },
        {
          ...valid,
          'processes': [
            {
              'path': ['edge'],
              'operation': 'FUTURE',
              'required': true,
            },
          ],
        },
        {...valid, 'processes': 'unknown-wire'},
      ];
      for (final raw in cases) {
        final plan = OrderDeliveryPlan.read(raw)!;
        expect(plan.supported, isFalse);
        expect(plan.toJson(), raw);
        expect(() => plan.label, returnsNormally);
        expect(() => plan.summary, returnsNormally);
      }
    },
  );

  final payload = <String, dynamic>{
    'version': 1,
    'mode': 'BOM',
    'packaging': 'BULK',
    'nodeModes': [
      {
        'path': ['edge-a', 'edge-b'],
        'mode': 'CHILDREN',
      },
    ],
    'processes': [
      {
        'path': ['edge-a', 'edge-b', 'edge-c'],
        'operation': 'LASER',
        'required': true,
      },
    ],
    'bomFingerprint': 'server-fingerprint',
    'futureEvidence': {'revision': 7},
  };

  test(
    'draft and clone retain delivery edge paths, exact evidence, and independent edits',
    () {
      final row = SalesGridRow(amountUsesDiscount: true)
        ..deliveryPlan = OrderDeliveryPlan.read(payload)
        ..documentItemId = 'existing-line';
      final restored = SalesGridRow.fromDraft(row.exportDraft());
      final copied = row.clone();
      addTearDown(() {
        row.dispose();
        restored.dispose();
        copied.dispose();
      });
      expect(restored.deliveryPlan!.toJson(), payload);
      expect(copied.deliveryPlan!.toJson(), payload);
      expect(copied.documentItemId, isNull);
      copied.deliveryPlan = copied.deliveryPlan!.setNode([
        'other-edge',
      ], 'CHILDREN');
      expect(row.deliveryPlan!.modeAt(['other-edge']), 'WHOLE');
      expect(restored.deliveryPlan!.bomFingerprint, 'server-fingerprint');
      final exported = restored.deliveryPlan!.toJson();
      (exported['futureEvidence'] as Map)['revision'] = 99;
      expect(restored.deliveryPlan!.toJson()['futureEvidence'], {
        'revision': 7,
      });
    },
  );

  test('detail keeps saved plan and legacy missing plan remains assembled', () {
    final item = SalesDocItem.fromJson({'id': 'line', 'deliveryPlan': payload});
    expect(item.deliveryPlan!.toJson(), payload);
    expect(
      orderDeliveryLabel(SalesDocItem.fromJson({'id': 'old'}).deliveryPlan),
      '整装交付',
    );
    expect(
      OrderDeliveryPlan.read({...payload, 'version': 2})!.supported,
      isFalse,
    );
  });

  test(
    'BOM shipment draft capacity does not masquerade as root reserved stock',
    () {
      final plan = {...payload, 'mode': 'BOM'};
      final line = ShippableLine.fromJson({
        'orderItemId': 'line',
        'orderId': 'order',
        'reservedQty': 0,
        'deliveryPlan': plan,
        'deliveryDraftQty': 75,
        'deliveryDraftQtyExact': '75',
        'physicalReadinessUnknown': true,
        'writable': true,
      });
      expect(line.reservedQty, 0);
      expect(line.availableShipmentQty, 75);
      expect(line.physicalReadinessUnknown, isTrue);
      final progress = OrderPlanProgressLine.fromJson({
        'orderItemId': 'line',
        'shippableQty': 0,
        'deliveryPlan': plan,
        'deliveryDraftQty': 75,
        'deliveryDraftQtyExact': '75',
      });
      expect(progress.shippableQty, 0);
      expect(progress.availableShipmentQty, 75);
    },
  );

  test(
    'server missing children and assembly/process constraints stay explicit',
    () {
      final node = OrderDeliveryBomNode.fromJson({
        'path': ['edge-a'],
        'goodsId': 'goods-a',
        'name': '必须装好的组件',
        'childrenState': 'MISSING',
        'mandatoryAssembly': true,
        'requiredOperations': ['LASER'],
        'children': <Map<String, dynamic>>[],
      });
      expect(node.path, ['edge-a']);
      expect(node.hasChildren, isTrue);
      expect(node.cannotSplit, '此组件必须保持组装');
      expect(node.requiredOperations, ['LASER']);
      final unknown = OrderDeliveryBomNode.fromJson({
        'path': <String>[],
        'goodsId': 'g',
      });
      expect(unknown.childrenState, 'MISSING');
      expect(unknown.cannotSplit, contains('未提供'));
    },
  );
}
