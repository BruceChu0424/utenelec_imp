import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/presentation/procurement_delivery_difference_l10n.dart';

void main() {
  for (final entry in const {
    'zh': ['差异数', '订货', '订货明细报表', '保留实际差额', '差异数', '差异数', '订货差异数'],
    'en': [
      'Delivery difference',
      'Orders',
      'Order detail report',
      'preserves the actual difference',
      'Order difference',
      'Quantity difference',
      'Source order difference',
    ],
    'ko': [
      '입고 차이',
      '발주',
      '발주 상세 보고서',
      '실제 차이는 유지',
      '발주 차이',
      '수량 차이',
      '원본 발주 차이',
    ],
  }.entries) {
    testWidgets(
      '${entry.key} localizes the delivery variance and order report',
      (tester) async {
        late ProcurementDeliveryDifferenceL10n copy;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(entry.key),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Builder(
              builder: (context) {
                copy = procurementDeliveryDifferenceL10n(context);
                return Text(copy.label);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(copy.label, entry.value[0]);
        expect(copy.orderLabel, entry.value[1]);
        expect(copy.orderDetailTitle, entry.value[2]);
        expect(copy.hint, contains(entry.value[3]));
        expect(
          copy.labelFor(ProcurementDifferenceScope.request),
          entry.value[4],
        );
        expect(
          copy.labelFor(ProcurementDifferenceScope.workbench),
          entry.value[5],
        );
        expect(
          copy.labelFor(ProcurementDifferenceScope.sourceOrder),
          entry.value[6],
        );
        expect(
          copy.hintFor(ProcurementDifferenceScope.request),
          copy.requestHint,
        );
        expect(
          copy.hintFor(ProcurementDifferenceScope.workbench),
          copy.workbenchHint,
        );
        expect(
          copy.hintFor(ProcurementDifferenceScope.sourceOrder),
          copy.sourceOrderHint,
        );
        expect(find.text(entry.value[0]), findsOneWidget);
      },
    );
  }
}
