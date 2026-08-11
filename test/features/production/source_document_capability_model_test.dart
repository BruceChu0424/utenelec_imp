import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';

void main() {
  test('purchase detail decodes authoritative production capabilities', () {
    final detail = PurchaseDocDetail.fromJson({
      'id': 'purchase-request-1',
      'productionLinked': true,
      'canEdit': false,
      'canDelete': false,
      'canReverse': false,
      'restrictionReason': '请从生产计划专用流程调整',
    });

    expect(detail.productionLinked, isTrue);
    expect(detail.canEdit, isFalse);
    expect(detail.canDelete, isFalse);
    expect(detail.canReverse, isFalse);
    expect(detail.restrictionReason, contains('生产计划'));
  });

  test('subcontract detail decodes authoritative production capabilities', () {
    final detail = SubcontractDocDetail.fromJson({
      'id': 'subcontract-order-1',
      'productionLinked': true,
      'canEdit': false,
      'canDelete': false,
      'canReverse': true,
      'restrictionReason': '红冲须走守恒校验',
    });

    expect(detail.productionLinked, isTrue);
    expect(detail.canEdit, isFalse);
    expect(detail.canDelete, isFalse);
    expect(detail.canReverse, isTrue);
    expect(detail.restrictionReason, contains('守恒'));
  });

  test('legacy detail payload remains backward compatible', () {
    final purchase = PurchaseDocDetail.fromJson({'id': 'purchase-legacy'});
    final subcontract = SubcontractDocDetail.fromJson({
      'id': 'subcontract-legacy',
    });

    expect(purchase.productionLinked, isFalse);
    expect(purchase.canEdit, isTrue);
    expect(purchase.canDelete, isTrue);
    expect(purchase.canReverse, isTrue);
    expect(subcontract.productionLinked, isFalse);
    expect(subcontract.canEdit, isTrue);
    expect(subcontract.canDelete, isTrue);
    expect(subcontract.canReverse, isTrue);
  });
}
