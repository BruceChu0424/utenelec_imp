import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';

void main() {
  test('goods policy percentages accept numeric and exact text responses', () {
    for (final asText in [false, true]) {
      final detail = GoodsDetail.fromJson({
        'id': 'goods',
        'subcontractAllowedLossPct': asText ? '7.25' : 7.25,
        'purchaseAllowedOverReceiptPct': asText ? '8.125' : 8.125,
      });
      expect(detail.subcontractAllowedLossPct, 7.25);
      expect(detail.subcontractAllowedLossPctText, '7.25');
      expect(detail.purchaseAllowedOverReceiptPct, 8.125);
      expect(detail.purchaseAllowedOverReceiptPctText, '8.125');
    }
  });

  test('exact policy companions preserve digits beyond the legacy double', () {
    const exact = '7.250000000000000000000001';
    final detail = GoodsDetail.fromJson({
      'id': 'goods',
      'subcontractAllowedLossPct': 7.25,
      'subcontractAllowedLossPctExact': exact,
      'purchaseAllowedOverReceiptPct': 7.25,
      'purchaseAllowedOverReceiptPctExact': exact,
    });
    expect(detail.subcontractAllowedLossPctText, exact);
    expect(detail.purchaseAllowedOverReceiptPctText, exact);
  });

  test('missing policy data stays unknown and malformed data is rejected', () {
    final empty = GoodsDetail.fromJson({'id': 'goods'});
    expect(empty.subcontractAllowedLossPct, isNull);
    expect(empty.subcontractAllowedLossPctText, isNull);
    expect(empty.purchaseAllowedOverReceiptPct, isNull);
    expect(empty.purchaseAllowedOverReceiptPctText, isNull);
    for (final value in ['not-a-decimal', double.infinity]) {
      expect(
        () => GoodsDetail.fromJson({
          'id': 'goods',
          'subcontractAllowedLossPct': value,
          'purchaseAllowedOverReceiptPct': value,
        }),
        throwsFormatException,
      );
    }
  });
}
