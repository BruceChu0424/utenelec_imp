import 'package:flutter/material.dart';

import '../../components/data_display/uten_detail_summary_card.dart';
import '../../components/layout/uten_collapsible_content.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/responsive/compact_presentation.dart';
import '../../core/utils/china_datetime.dart';
import '../formatters/money_display.dart';
import '../models/shipment_receivable_position.dart';
import '../auth/permissions.dart';

bool canViewShipmentReceivableMoney(
  Set<String> permissions, {
  bool administrator = false,
}) =>
    administrator ||
    permissions.contains(Perm.salesShipmentFinanceView) ||
    permissions.contains(Perm.salesOrderFinanceView) ||
    permissions.contains(Perm.financeViewAll) ||
    permissions.contains(Perm.salesOrderPriceView);

const shipmentReceivableHint =
    '仅看这张出货单的货款。已收=已确认收款+已实际抵扣预收；'
    '退减、退货抵销及尚未抵扣的订单预收不算已收。银行手续费和净到账在原收款单分别保留。'
    '部分付款后仍按本批还欠继续联系客户，收到尾款后回本批登记。'
    '到货后付尾款等约定请核对原单据备注或结款方式；未到账仍还欠。'
    '还欠为0表示已结清，可由收款、实际抵扣预收或正式退减形成，不表示全部现金收齐。'
    '这里显示本次核对的结果；财务更新后，催款前请刷新核对本批还欠。';

String shipmentPositionMoney(
  ShipmentReceivablePosition value,
  String? amount,
) => financeMoneyWithUnitSuffix(amount, currencyName: value.currencyName);
String shipmentPaidLabel(ShipmentReceivablePosition value) => value.ready
    ? shipmentPositionMoney(value, value.confirmedPaidOriginal)
    : value.unavailableLabel;
String shipmentDebtLabel(ShipmentReceivablePosition value) => value.ready
    ? shipmentPositionMoney(value, value.balanceOriginal)
    : value.unavailableLabel;

/// One shipment's current money, embedded in its document's summary card.
/// Historical release evidence belongs to the separate audit reference section.
class ShipmentReceivablePositionView extends StatefulWidget {
  const ShipmentReceivablePositionView({super.key, required this.value});
  final ShipmentReceivablePosition value;
  @override
  State<ShipmentReceivablePositionView> createState() =>
      _ShipmentReceivablePositionViewState();
}

class _ShipmentReceivablePositionViewState
    extends State<ShipmentReceivablePositionView> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final theme = Theme.of(context);
    final readHint = [
      shipmentReceivableHint,
      if (value.readAt != null)
        '本次读取：${ChinaDateTime.formatInstant(value.readAt!)}',
      ...value.warnings,
    ].join('\n');
    Widget metric(
      String label,
      String amount,
      String hint, {
      bool danger = false,
    }) => UtenSummaryField(
      label: label,
      value: amount,
      info: hint,
      emphasis: true,
      danger: danger,
      inline: false,
    );
    Widget detail(String label, String? amount, String info) =>
        UtenSummaryField(
          label: label,
          value: shipmentPositionMoney(value, amount),
          info: info,
          inline: false,
        );
    return Column(
      key: const ValueKey('shipment-receivable-position'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Theme(
          data: UtenCompactPresentation.of(context)
              ? theme.copyWith(
                  textTheme: theme.textTheme.copyWith(
                    titleLarge: theme.textTheme.titleMedium,
                  ),
                )
              : theme,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: metric(
                  '货款',
                  shipmentPositionMoney(
                    value,
                    value.formalReceivableOriginal ?? value.shipmentOriginal,
                  ),
                  '本批原币货款；待出库时是计划货款，尚未形成正式应收。',
                ),
              ),
              const SizedBox(width: UtenSpacing.s16),
              Expanded(
                child: metric(
                  '已收',
                  shipmentPaidLabel(value),
                  '本批已确认收款与实际定金抵款之和；尚未抵扣的定金和退减均不计入已收。',
                ),
              ),
              const SizedBox(width: UtenSpacing.s16),
              Expanded(
                child: metric(
                  '还欠',
                  shipmentDebtLabel(value),
                  readHint,
                  danger: value.hasDebt || value.needsReview,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: UtenSpacing.s16,
                runSpacing: UtenSpacing.s4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 240,
                    child: UtenSummaryField(
                      label: '到期',
                      inline: true,
                      value:
                          value.dueDate ??
                          (value.notPosted ? '待出库后核对' : '未约定/待核对付款时间'),
                      danger: value.isOverdue,
                    ),
                  ),
                  if (value.isSettled)
                    const SizedBox(
                      width: 120,
                      child: UtenSummaryField(
                        label: '状态',
                        value: '已结清',
                        inline: true,
                      ),
                    ),
                  if (value.isOverdue)
                    SizedBox(
                      width: 120,
                      child: UtenSummaryField(
                        label: '逾期',
                        value: '${value.overdueDays}天',
                        danger: true,
                        inline: true,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Tooltip(
              message: _expanded ? '收起本批金额明细' : '展开本批金额明细',
              child: TextButton.icon(
                key: const ValueKey('shipment-money-details-toggle'),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                ),
                label: Text(_expanded ? '收起明细' : '款项明细'),
              ),
            ),
          ],
        ),
        UtenCollapsibleContent(
          expanded: _expanded,
          maintainState: false,
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            child: UtenSummaryFacts(
              minFieldWidth: 150,
              maxColumns: 5,
              inline: false,
              children: [
                if (value.ready) ...[
                  detail(
                    '收款',
                    value.cashReceivedOriginal,
                    '已核准且有实际账户入账证明的本批结算原币金额；银行手续费与账户净到账分别核对。',
                  ),
                  detail(
                    '定金抵款',
                    value.prepaymentAppliedOriginal,
                    '预收已实际抵扣本批应收，不是再次到账；未抵扣的订单定金不计入本批已收。',
                  ),
                  detail('退减', value.reductionOriginal, '已正式办理的货款退减，不计入已收。'),
                  detail(
                    '退货抵款',
                    value.returnOffsetOriginal,
                    '已正式办理的退货抵销，不计入已收。',
                  ),
                  detail(
                    '其他抵款',
                    value.otherOffsetOriginal,
                    '已正式办理的其他应收抵销，不计入已收。',
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
