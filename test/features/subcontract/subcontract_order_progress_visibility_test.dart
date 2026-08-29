import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_order_progress.dart';

void main() {
  test(
    'masked order progress keeps quantities but marks commercial facts hidden',
    () {
      final progress = SubcontractOrderProgress.fromJson(const {
        'orderId': 'order-1',
        'materialRequired': true,
        'materialLines': <Map<String, dynamic>>[],
        'issues': <Map<String, dynamic>>[],
        'receipts': [
          {'id': 'receipt-1', 'totalQty': 8, 'totalLocal': null},
        ],
        'returns': <Map<String, dynamic>>[],
        'wastes': [
          {'id': 'waste-1', 'totalQty': 2, 'deductAmount': null},
        ],
        'supplierLedger': <Map<String, dynamic>>[],
        'apPostedTotal': null,
        'wasteDeductTotal': null,
        'priceMasked': true,
      });

      expect(progress.priceMasked, isTrue);
      expect(progress.receipts.single.totalQty, 8);
      expect(progress.receipts.single.totalLocal, isNull);
      expect(progress.wastes.single.totalQty, 2);
      expect(progress.wastes.single.deductAmount, isNull);
    },
  );
}
