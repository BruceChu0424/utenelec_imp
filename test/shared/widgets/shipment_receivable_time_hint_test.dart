import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/shared/models/shipment_receivable_position.dart';
import 'package:uten_imp/shared/widgets/shipment_receivable_position_view.dart';

void main() {
  final instant = DateTime.utc(2026, 11, 5, 8, 13);
  final samples = {
    'UTC instant': instant,
    'Denver UTC-07:00 input': DateTime.parse('2026-11-05T01:13:00-07:00'),
    'device-local DateTime instant': DateTime.fromMillisecondsSinceEpoch(
      instant.millisecondsSinceEpoch,
    ),
  };
  for (final sample in samples.entries) {
    testWidgets('shipment read hint converts ${sample.key} to Beijing once', (
      tester,
    ) async {
      final value = ShipmentReceivablePosition(
        state: 'READY',
        complete: true,
        currencyName: '人民币',
        shipmentOriginal: '1000',
        formalReceivableOriginal: '1000',
        cashReceivedOriginal: '400',
        prepaymentAppliedOriginal: '0',
        confirmedPaidOriginal: '400',
        balanceOriginal: '600',
        readAt: sample.value,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ShipmentReceivablePositionView(value: value)),
        ),
      );
      await tester.pumpAndSettle();
      final hint = tester
          .widgetList<UtenFieldHintIcon>(find.byType(UtenFieldHintIcon))
          .map((widget) => widget.info ?? '')
          .singleWhere((text) => text.contains('本次读取：'));
      expect(hint, contains('本次读取：2026-11-05 16:13(北京)'));
      expect('北京'.allMatches(hint), hasLength(1));
      expect(hint, isNot(contains('01:13')));
      expect(shipmentPaidLabel(value), contains('400'));
      expect(shipmentDebtLabel(value), contains('600'));
      expect(value.readAt, same(sample.value));
      expect(tester.takeException(), isNull);
    });
  }
}
