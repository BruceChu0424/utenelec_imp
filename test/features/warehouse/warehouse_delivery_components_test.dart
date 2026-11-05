import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_picking_fields.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_outbound_table_columns.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_delivery_components_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

WarehouseSalesOutboundDetail detail({
  int revision = 1,
  String processed = '0.10',
  bool sourceCheck = false,
}) => WarehouseSalesOutboundDetail.fromJson({
  'id': 'shipment',
  'warehouseWorkStatus': 'PENDING_PICK',
  'allowedWarehouseTargets': ['SHIPPED'],
  'lines': [
    {
      'id': 'parent',
      'goodsId': 'root',
      'quantity': '100',
      'warehouseChoices': <Map<String, dynamic>>[],
    },
  ],
  'deliveryComponents': [
    for (var i = 0; i < 2; i++)
      {
        'id': 'component-$i',
        'shipmentItemId': 'parent',
        'orderItemId': 'order-line',
        'goodsId': 'part-$i',
        'goodsCode': 'PART-$i',
        'goodsName': '散件$i',
        'quantityExact': '0.10',
        'quantity': 0.1,
        'processedQty': processed,
        'revision': revision,
        'path': ['edge-a', 'edge-$i'],
        'operations': ['LASER'],
        'processingTargets': [
          {
            'path': ['edge-a', 'edge-$i', 'plate'],
            'goodsId': 'laser-plate-$i',
            'code': 'LASER-PLATE-$i',
            'name': '内部激光底板$i',
            'unitName': '片',
            'quantityNumerator': '1',
            'quantityDenominator': '3',
            'operations': ['LASER'],
            'unitPrice': 'SENSITIVE-PRICE-NOT-RETAINED',
          },
        ],
        'warehouseChoices': [
          {
            'warehouseId': 'warehouse',
            'warehouseName': '五金仓',
            'availableQty': sourceCheck ? '0' : '0.10',
            'requiresSourceCheck': sourceCheck,
          },
        ],
      },
  ],
});

void main() {
  test(
    'component choice prefers exact availability beyond JSON number precision',
    () {
      final component = WarehouseDeliveryComponent.fromJson({
        'id': 'component-exact',
        'shipmentItemId': 'parent',
        'goodsId': 'synthetic-part',
        'quantityExact': '9007199254740993.0002',
        'warehouseChoices': [
          {
            'warehouseId': 'warehouse',
            'warehouseName': '合成仓',
            'availableQty': 9007199254740994.0,
            'availableQtyExact': '9007199254740993.0001',
          },
        ],
      });
      final choice = component.warehouseChoices.single;
      expect(choice.availableQty, '9007199254740993.0001');
      expect(choice.label, contains('9007199254740993.0001'));
      expect(choice.canFulfill, isFalse);
      expect(choice.selectableForComponent, isFalse);
      final legacy = WarehouseSalesWarehouseChoice.fromJson({
        'warehouseId': 'legacy-warehouse',
        'warehouseName': '旧成品仓',
        'availableQty': '0.10',
        'canFulfill': true,
      });
      expect(legacy.availableQty, '0.10');
      expect(legacy.canFulfill, isTrue);
    },
  );

  test(
    'component private-source check permits a choice without inventing public stock; ordinary goods remain strict',
    () {
      final source = detail(sourceCheck: true);
      final draft = WarehouseSalesPickingDraft(source);
      addTearDown(draft.dispose);
      final choice = source.deliveryComponents.first.warehouseChoices.single;
      expect(choice.availableQty, '0');
      expect(choice.canFulfill, isFalse);
      expect(choice.selectableForComponent, isTrue);
      expect(choice.label, contains('可用预览 0'));
      expect(choice.label, contains('本单权益待核对'));
      expect(choice.label, isNot(contains('可发')));
      expect(draft.validate(), isTrue);
      expect(
        draft.deliveryComponentsPayload.map((row) => row['warehouseId']),
        everyElement('warehouse'),
      );
      final ordinary = WarehouseSalesWarehouseChoice.fromJson({
        'warehouseId': 'warehouse',
        'warehouseName': '成品仓',
        'availableQty': '0',
        'requiredQty': '1',
        'canFulfill': false,
      });
      expect(ordinary.canFulfill, isFalse);
      expect(ordinary.requiresSourceCheck, isFalse);
      expect(ordinary.label, contains('不足'));
    },
  );

  testWidgets(
    'narrow warehouse table edits component locations without changing the complete payload',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = detail();
      final draft = WarehouseSalesPickingDraft(source);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [currentPermissionsProvider.overrideWithValue(const {})],
          child: MaterialApp(
            home: Scaffold(
              body: WarehouseDeliveryComponentsTabs(
                commercial: const Text('订单产品100个'),
                details: [source],
                draftOf: (_) => draft,
                onChanged: () {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('实际交付散件 (2)'));
      await tester.pumpAndSettle();
      expect(find.text('散件0'), findsWidgets);
      expect(find.textContaining('内部激光底板0 / 1/3 片 / 激光加工'), findsWidgets);
      expect(find.textContaining('SENSITIVE-PRICE-NOT-RETAINED'), findsNothing);
      expect(
        source.deliveryComponents.first.processingTargets.single.data,
        isNot(contains('unitPrice')),
      );
      draft.componentPlaces['component-0']!.text = 'A-01';
      expect(draft.deliveryComponentsPayload, hasLength(2));
      expect(draft.deliveryComponentsPayload.first['stockPlace'], 'A-01');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      draft.dispose();
    },
  );

  test(
    'BOM commercial parent does not require finished stock and all component inputs survive drafts',
    () {
      final source = detail();
      final draft = WarehouseSalesPickingDraft(source);
      final restored = WarehouseSalesPickingDraft(source);
      addTearDown(() {
        draft.dispose();
        restored.dispose();
      });
      expect(draft.weights, isEmpty);
      expect(draft.lineWarehouses, isEmpty);
      expect(draft.stockPlaces, isEmpty);
      draft.changeComponentWarehouse('component-0', 'warehouse');
      draft.componentPlaces['component-0']!.text = 'A-01';
      draft.componentPlaces['component-1']!.text = 'A-02';
      expect(draft.validate(), isTrue);
      restored.restoreInput(draft.captureInput());
      expect(restored.deliveryComponentsPayload, [
        {
          'componentId': 'component-0',
          'warehouseId': 'warehouse',
          'stockPlace': 'A-01',
        },
        {
          'componentId': 'component-1',
          'warehouseId': 'warehouse',
          'stockPlace': 'A-02',
        },
      ]);
      expect(
        restored.deliveryComponentsPayload,
        hasLength(source.deliveryComponents.length),
      );
    },
  );

  test(
    'processing blocks shipment; evidence refresh retains inputs and changes review snapshot',
    () {
      final incomplete = WarehouseSalesPickingDraft(detail(processed: '0.09'));
      final changed = WarehouseSalesPickingDraft(detail(revision: 2));
      addTearDown(() {
        incomplete.dispose();
        changed.dispose();
      });
      expect(incomplete.validate(), isFalse);
      expect(incomplete.componentErrors, hasLength(2));
      incomplete.componentPlaces['component-0']!.text = 'A-01';
      changed.restoreInput(incomplete.captureInput());
      expect(changed.componentPlaces['component-0']!.text, 'A-01');
      final invalid = incomplete.captureInput();
      ((invalid['components'] as List).first as Map)['quantity'] = '99';
      expect(() => changed.restoreInput(invalid), throwsFormatException);
      expect(
        warehouseSalesOutboundReviewSnapshot(detail()),
        isNot(warehouseSalesOutboundReviewSnapshot(detail(revision: 2))),
      );
      expect(
        warehouseDeliveryQuantityCovers('0.09999999999999999999', '0.10'),
        isFalse,
      );
    },
  );
}
