import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/providers/inbound_warehouse_fill_memory.dart';

void main() {
  test('采购/委外与产成品共用一个选仓记忆类，按来源分键且沿用历史偏好键', () {
    expect(InboundFillScope.procurement.prefKey, 'warehouse.arrivalFill');
    expect(InboundFillScope.finished.prefKey, 'production.finishedArrivalFill');
    expect(
      InboundWarehouseFillMemoryNotifier(InboundFillScope.finished).prefKey,
      'production.finishedArrivalFill',
    );
    expect(
      identical(
        inboundWarehouseFillMemoryProvider(InboundFillScope.procurement),
        inboundWarehouseFillMemoryProvider(InboundFillScope.finished),
      ),
      isFalse,
    );
  });

  test('旧 JSON 里的库位等字段忽略且不再写回；空值不记', () {
    final notifier = InboundWarehouseFillMemoryNotifier(
      InboundFillScope.procurement,
    );
    final value = notifier.decode({
      'warehouseId': ' warehouse-a ',
      'stockPlace': 'OTHER-GOODS-AND-WAREHOUSE',
    });
    expect(value?.warehouseId, 'warehouse-a');
    expect(notifier.encode(value!), {'warehouseId': 'warehouse-a'});
    expect(notifier.encode(InboundWarehouseFillMemory.empty), isEmpty);
    expect(notifier.decode({'warehouseId': '  '})?.warehouseId, isNull);
    expect(notifier.decode('not-a-map'), isNull);
  });
}
