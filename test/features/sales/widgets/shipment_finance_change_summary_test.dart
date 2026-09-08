import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/widgets/shipment_finance_change_summary.dart';

void main() {
  testWidgets('review differences keep decimal text and stable row identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShipmentFinanceChangeSummary(
            previous: jsonEncode({
              'header': {'billingMode': 'CHARGED'},
              'items': [
                {
                  'id': 'row',
                  'lineNo': 1,
                  'price': '1234567890123.4567',
                  'qty': '2.0000',
                },
              ],
            }),
            current: jsonEncode({
              'header': {'billingMode': 'CHARGED'},
              'items': [
                {
                  'id': 'row',
                  'lineNo': 1,
                  'price': '1234567890123.4568',
                  'qty': '3.0000',
                },
              ],
            }),
          ),
        ),
      ),
    );
    expect(find.text('以前：1234567890123.4567'), findsOneWidget);
    expect(find.text('本次：1234567890123.4568'), findsOneWidget);
    expect(find.text('以前：2.0000'), findsOneWidget);
    expect(find.text('本次：3.0000'), findsOneWidget);
    expect(find.text('新增明细'), findsNothing);
  });
  test('an unreadable snapshot cannot enter actionable review', () {
    expect(readableShipmentReviewSnapshot(null), isFalse);
    expect(readableShipmentReviewSnapshot('{broken'), isFalse);
    expect(readableShipmentReviewSnapshot('{"header":{},"items":[]}'), isTrue);
  });
}
