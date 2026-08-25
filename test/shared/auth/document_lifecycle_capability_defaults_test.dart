import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';

void main() {
  test('missing purchase and subcontract lifecycle fields fail closed', () {
    final purchase = PurchaseDocDetail.fromJson(const {'id': 'purchase-1'});
    final subcontract = SubcontractDocDetail.fromJson(const {
      'id': 'subcontract-1',
    });

    expect(purchase.canEdit, isFalse);
    expect(purchase.canDelete, isFalse);
    expect(purchase.canReverse, isFalse);
    expect(subcontract.canEdit, isFalse);
    expect(subcontract.canDelete, isFalse);
    expect(subcontract.canReverse, isFalse);
  });

  test('explicit server lifecycle fields remain authoritative', () {
    final purchase = PurchaseDocDetail.fromJson(const {
      'id': 'purchase-1',
      'canEdit': true,
      'canDelete': true,
      'canReverse': false,
    });
    final subcontract = SubcontractDocDetail.fromJson(const {
      'id': 'subcontract-1',
      'canEdit': false,
      'canDelete': false,
      'canReverse': true,
    });

    expect(purchase.canEdit, isTrue);
    expect(purchase.canDelete, isTrue);
    expect(purchase.canReverse, isFalse);
    expect(subcontract.canEdit, isFalse);
    expect(subcontract.canDelete, isFalse);
    expect(subcontract.canReverse, isTrue);
  });

  test('production plan missing allowedActions has no action fallback', () {
    final source = File(
      'lib/features/production/pages/production_plan_detail_page.dart',
    ).readAsStringSync();

    expect(source, contains('return actions.contains(action);'));
    expect(source, isNot(contains('actions.isEmpty ||')));
  });
}
