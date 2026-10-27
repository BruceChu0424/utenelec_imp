import 'package:flutter/widgets.dart';

enum ProcurementDifferenceScope { request, order, sourceOrder, workbench }

/// Scoped procurement copy; usable by table hosts without app delegates.
class ProcurementDeliveryDifferenceL10n {
  const ProcurementDeliveryDifferenceL10n({
    required this.label,
    required this.requestLabel,
    required this.workbenchLabel,
    required this.hint,
    required this.requestHint,
    required this.sourceOrderHint,
    required this.sourceOrderLabel,
    required this.workbenchHint,
    required this.orderLabel,
    required this.orderDetailTitle,
  });

  final String label;
  final String requestLabel;
  final String workbenchLabel;
  final String hint;
  final String requestHint;
  final String sourceOrderHint;
  final String sourceOrderLabel;
  final String workbenchHint;
  final String orderLabel;
  final String orderDetailTitle;

  String labelFor(ProcurementDifferenceScope scope) => switch (scope) {
    ProcurementDifferenceScope.request => requestLabel,
    ProcurementDifferenceScope.order => label,
    ProcurementDifferenceScope.sourceOrder => sourceOrderLabel,
    ProcurementDifferenceScope.workbench => workbenchLabel,
  };

  String hintFor(ProcurementDifferenceScope scope) => switch (scope) {
    ProcurementDifferenceScope.request => requestHint,
    ProcurementDifferenceScope.order => hint,
    ProcurementDifferenceScope.sourceOrder => sourceOrderHint,
    ProcurementDifferenceScope.workbench => workbenchHint,
  };
}

ProcurementDeliveryDifferenceL10n procurementDeliveryDifferenceL10n(
  BuildContext context,
) => switch (Localizations.maybeLocaleOf(context)?.languageCode) {
  'en' => const ProcurementDeliveryDifferenceL10n(
    label: 'Delivery difference',
    requestLabel: 'Order difference',
    workbenchLabel: 'Quantity difference',
    hint:
        'Received − returned − ordered. A negative value means outstanding delivery. Closing an order preserves the actual difference. Gifts and settled losses are tracked separately.',
    requestHint:
        'Effective ordered physical quantity − requested physical quantity. A negative value means quantity not yet ordered. Pending orders are excluded; extra gifts follow the document physical quantity rules.',
    sourceOrderHint:
        'Cumulative received − returned − ordered for the linked order line. A negative value means outstanding delivery. This is the current source order difference, not the quantity on this document. Gifts and settled losses are tracked separately.',
    sourceOrderLabel: 'Source order difference',
    workbenchHint:
        'Request: effective ordered physical quantity − requested physical quantity; negative means not yet ordered. Pending orders are excluded; physical quantity includes extra gifts under the document rules. Order: received − returned − ordered; negative means outstanding delivery. Closing an order preserves the actual difference; order gifts and settled losses are tracked separately.',
    orderLabel: 'Orders',
    orderDetailTitle: 'Order detail report',
  ),
  'ko' => const ProcurementDeliveryDifferenceL10n(
    label: '입고 차이',
    requestLabel: '발주 차이',
    workbenchLabel: '수량 차이',
    hint:
        '입고 − 반품 − 발주 수량. 음수는 미입고 수량입니다. 주문을 종료해도 실제 차이는 유지되며, 증정품과 결산 손실은 별도로 확인합니다.',
    requestHint:
        '유효 발주 실물 수량 − 신청 실물 수량. 음수는 미발주 수량입니다. 승인 대기 발주는 제외하며, 추가 증정품은 문서의 실물 수량 규칙을 따릅니다.',
    sourceOrderHint:
        '연결된 발주 행의 누적 입고 − 반품 − 발주 수량. 음수는 미입고 수량입니다. 현재 원본 발주의 차이이며, 이 문서의 수량이 아닙니다. 증정품과 결산 손실은 별도로 확인합니다.',
    sourceOrderLabel: '원본 발주 차이',
    workbenchHint:
        '신청: 유효 발주 실물 수량 − 신청 실물 수량이며 음수는 미발주 수량입니다. 승인 대기는 제외하고 추가 증정품은 실물 수량 규칙을 따릅니다. 발주: 입고 − 반품 − 발주 수량이며 음수는 미입고 수량입니다. 종료 후에도 실제 차이는 유지되며 발주 증정품과 결산 손실은 별도입니다.',
    orderLabel: '발주',
    orderDetailTitle: '발주 상세 보고서',
  ),
  _ => const ProcurementDeliveryDifferenceL10n(
    label: '差异数',
    requestLabel: '差异数',
    workbenchLabel: '差异数',
    hint: '已收－已退－订货。负数表示未到齐；直接结束后仍保留实际差额。赠品和结案损耗单独核对。',
    requestHint: '已生效订货实物数－申请实物数。负数表示尚未下单；待审订货不计入已生效量，额外赠品按单据实物口径计入。',
    sourceOrderHint:
        '关联订货明细的累计已收－已退－订货。负数表示未到齐；显示原订单当前差额，不是本张单据数量。赠品和结案损耗单独核对。',
    sourceOrderLabel: '订货差异数',
    workbenchHint:
        '申请：已生效订货实物数－申请实物数，负数表示尚未下单；不计待审订货，额外赠品按实物口径计入。订货：已收－已退－订货，负数表示未到齐；直接结束保留实际差额，订货赠品和结案损耗单独核对。',
    orderLabel: '订货',
    orderDetailTitle: '订货明细报表',
  ),
};
