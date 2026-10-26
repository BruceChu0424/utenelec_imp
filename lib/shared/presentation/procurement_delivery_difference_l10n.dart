import 'package:flutter/widgets.dart';

/// Scoped procurement copy; usable by table hosts without app delegates.
class ProcurementDeliveryDifferenceL10n {
  const ProcurementDeliveryDifferenceL10n({
    required this.label,
    required this.hint,
    required this.orderLabel,
    required this.orderDetailTitle,
  });

  final String label;
  final String hint;
  final String orderLabel;
  final String orderDetailTitle;
}

ProcurementDeliveryDifferenceL10n procurementDeliveryDifferenceL10n(
  BuildContext context,
) => switch (Localizations.maybeLocaleOf(context)?.languageCode) {
  'en' => const ProcurementDeliveryDifferenceL10n(
    label: 'Delivery difference',
    hint:
        'Received − returned − ordered. A negative value means outstanding delivery. Closing an order preserves the actual difference. Gifts and settled losses are tracked separately.',
    orderLabel: 'Orders',
    orderDetailTitle: 'Order detail report',
  ),
  'ko' => const ProcurementDeliveryDifferenceL10n(
    label: '입고 차이',
    hint:
        '입고 − 반품 − 발주 수량. 음수는 미입고 수량입니다. 주문을 종료해도 실제 차이는 유지되며, 증정품과 결산 손실은 별도로 확인합니다.',
    orderLabel: '발주',
    orderDetailTitle: '발주 상세 보고서',
  ),
  _ => const ProcurementDeliveryDifferenceL10n(
    label: '差异数',
    hint: '已收－已退－订货。负数表示未到齐；直接结束后仍保留实际差额。赠品和结案损耗单独核对。',
    orderLabel: '订货',
    orderDetailTitle: '订货明细报表',
  ),
};
