import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/widgets/outbound_weight_columns.dart';

void main() {
  test(
    'all outbound consumers count identities and sum only compatible unit UUIDs',
    () {
      final entries = outboundProductTotalEntries(const [
        OutboundProductQuantity(
          goodsId: 'a',
          quantity: '0.1',
          unitId: 'piece',
          unitName: '个',
        ),
        OutboundProductQuantity(
          goodsId: 'a',
          quantity: '0.2',
          unitId: 'piece',
          unitName: '个',
        ),
        OutboundProductQuantity(
          goodsId: 'b',
          quantity: '3',
          unitId: 'box',
          unitName: '箱',
        ),
      ]);
      expect(entries[0].value, '2 种');
      expect(entries[1].value, '3 箱 · 0.3 个');
    },
  );
  test(
    'missing unit identities remain separate and unknown quantities never become zero',
    () {
      final entries = outboundProductTotalEntries(const [
        OutboundProductQuantity(
          goodsId: 'a',
          quantity: '5',
          unitId: null,
          unitName: '个',
        ),
        OutboundProductQuantity(
          goodsId: 'b',
          quantity: '7',
          unitId: null,
          unitName: '箱',
        ),
        OutboundProductQuantity(
          goodsId: 'c',
          quantity: null,
          unitId: 'piece',
          unitName: '个',
        ),
      ]);
      expect(entries[1].value, '数量未留存 个 · 5 个 · 7 箱');
    },
  );
  test(
    'missing goods identity is reported without inventing a zero-kind summary',
    () {
      final entries = outboundProductTotalEntries(const [
        OutboundProductQuantity(
          goodsId: null,
          quantity: '5',
          unitId: 'piece',
          unitName: '个',
        ),
      ]);
      expect(entries[0].value, '1 行货品待核对');
    },
  );
}
