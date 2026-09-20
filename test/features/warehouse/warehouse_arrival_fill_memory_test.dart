import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/providers/warehouse_arrival_fill_memory.dart';

void main() {
  test(
    'legacy account-wide shelf values are ignored and never persisted again',
    () {
      final notifier = WarehouseArrivalFillMemoryNotifier();
      final value = notifier.decode({
        'warehouseId': 'warehouse-a',
        'stockPlace': 'OTHER-GOODS-AND-WAREHOUSE',
      });
      expect(value?.warehouseId, 'warehouse-a');
      expect(notifier.encode(value!), {'warehouseId': 'warehouse-a'});
      expect(notifier.encode(WarehouseArrivalFillMemory.empty), isEmpty);
    },
  );
}
