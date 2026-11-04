import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_quality_slice_table.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_allocation_view.dart';

Map<String, dynamic> _slice(String remaining) => {
  'passEventId': 'pass-exact',
  'inspectionItemId': 'line-exact',
  'goodsId': 'goods-exact',
  'receivedBaseQty': 1,
  'qualityPassedBaseQty': 1,
  'warehouseStockedBaseQty': 0,
  'releasedBaseQty': 1,
  'stockedForReleaseBaseQty': 0,
  'remainingBaseQty': 1,
  for (final key in [
    'receivedBaseQty',
    'qualityPassedBaseQty',
    'releasedBaseQty',
    'remainingBaseQty',
  ])
    '${key}Exact': remaining,
  'warehouseStockedBaseQtyExact': '0',
  'stockedForReleaseBaseQtyExact': '0',
  'warehouseId': 'warehouse-exact',
  'placeHint': 'EXACT-01',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'source alias and submitted quantity retain 40/24 decimal ownership beyond binary precision',
    () {
      const cap = '9007199254740993.000000000000000000000002';
      final slice = WarehouseQualityReleasedSlice.fromJson(_slice(cap));
      final draft = WarehouseQualitySliceDraft(slice);
      addTearDown(draft.dispose);
      expect(draft.quantity.text, cap);
      draft.quantity.text = '9007199254740993.000000000000000000000001';
      expect(draft.validate(), isNull);
      final body = draft.toConfirmItem().toJson();
      expect(body['baseQty'], draft.quantity.text);
      expect(body['expectedRemainingBaseQty'], cap);
      draft.quantity.text = '9007199254740993.000000000000000000000003';
      expect(draft.quantityError, contains('不得超过'));
    },
  );
  test(
    'one quantum is accepted while over-capacity and a 25th effective decimal are rejected',
    () {
      const one = '0.000000000000000000000001';
      final draft = WarehouseQualitySliceDraft(
        WarehouseQualityReleasedSlice.fromJson(_slice(one)),
      );
      addTearDown(draft.dispose);
      expect(draft.validate(), isNull);
      expect(draft.toConfirmItem().baseQty, one);
      draft.quantity.text = '0.000000000000000000000002';
      expect(draft.quantityError, contains('不得超过'));
      draft.quantity.text = '0.0000000000000000000000001';
      expect(draft.quantityError, contains('24位'));
    },
  );
  test(
    'legacy numeric-only remaining cannot authorize a new exact stock-in',
    () {
      final json = _slice('3')..removeWhere((key, _) => key.endsWith('Exact'));
      final draft = WarehouseQualitySliceDraft(
        WarehouseQualityReleasedSlice.fromJson(json),
      );
      addTearDown(draft.dispose);
      draft.quantity.text = '1';
      expect(draft.quantityError, contains('精确资料'));
      expect(() => draft.toConfirmItem(), throwsFormatException);
    },
  );
  test(
    'unknown command recovery retains decimal strings, legacy number scalars and the same key',
    () {
      for (final quantity in <Object>['1.000000000000000000000001', 1.25]) {
        final original = {
          'idempotencyKey': 'original-only',
          'items': [
            {
              'passEventId': 'pass-exact',
              'baseQty': quantity,
              'expectedRemainingBaseQty': quantity,
              'warehouseId': 'warehouse-exact',
              'place': 'EXACT-01',
            },
          ],
        };
        final restored = WarehouseIqcStockInConfirmCommand.fromDraft(original);
        expect(jsonEncode(restored.toJson()), jsonEncode(original));
        expect(restored.items.single.baseQty.runtimeType, quantity.runtimeType);
      }
    },
  );
  test(
    'shared allocation preview and summary preserve tiny residue instead of epsilon zero',
    () {
      final allocations = [
        WarehouseInboundAllocation.fromJson({
          'kind': 'PUBLIC',
          'qty': 1,
          'qtyExact': '1',
          'baseUnitName': 'PCS',
        }),
      ];
      final result = warehouseInboundAllocationPreview(
        allocations,
        '1.000000000000000000000001',
      );
      expect(result, hasLength(2));
      expect(result.last.kind, WarehouseInboundAllocationKind.unknown);
      expect(result.last.quantityText, '0.000000000000000000000001');
      expect(
        warehouseInboundAllocationSummaryText(result, warehouseQualityQuantity),
        contains('0.000000000000000000000001'),
      );
    },
  );
  test(
    'warehouse projection keeps physical decimal quantity and original destination rules',
    () {
      final allocations = [
        WarehouseInboundAllocation.fromJson({
          'kind': 'EXACT_ANALYSIS',
          'qty': 1,
          'qtyExact': '0.03',
          'targetWarehouseId': 'old-main',
          'warehouseMatches': true,
        }),
      ];
      final result = warehouseInboundAllocationForWarehouse(
        allocations,
        '0.3',
        unitRate: '0.1',
        actualWarehouseId: 'new-main',
      );
      expect(result.single.quantityText, '0.03');
      expect(result.single.isCrossWarehouse, isTrue);
      expect(result.single.kind, WarehouseInboundAllocationKind.publicStock);
    },
  );
}
