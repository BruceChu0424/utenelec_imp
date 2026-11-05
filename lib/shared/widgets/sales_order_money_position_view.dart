import 'package:flutter/material.dart';
import '../../components/data_display/uten_detail_summary_card.dart';
import '../../components/inputs/uten_field_hint_icon.dart';
import '../../core/theme/uten_tokens.dart';
import '../models/sales_order_money_position.dart';
import '../formatters/money_display.dart';

/// The same order-scoped finance projection is shown at order and shipment decisions.
class SalesOrderMoneyPositionView extends StatelessWidget {
  const SalesOrderMoneyPositionView({
    super.key,
    required this.value,
    this.frozen = false,
  });
  final SalesOrderMoneyPosition value;
  final bool frozen;
  @override
  Widget build(BuildContext context) {
    Widget metric(String label, String? amount, String info) =>
        UtenSummaryField(
          label: label,
          info: info,
          value: financeMoneyWithUnitSuffix(
            amount,
            currencyName: value.currencyName,
          ),
          emphasis: true,
        );
    final pending = value.hasUnallocated || !value.positionComplete;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  '${frozen ? '审核时订单资金' : '订单资金'} · ${value.orderBillNo ?? '待刷新'}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              UtenFieldHintIcon(
                info: [
                  if (frozen) '这是本次财务放行时的冻结依据，后续收款或退货不会改写本次审核历史。',
                  '仅为本订单的资金，不把客户其他订单款当成本单收款。已收为客户结算原币金额，'
                      '例如结算1000、手续费10、银行净到账990，已收1000与账户实到990分别保留。'
                      '待确认草稿不抵扣；预收转销不重复算到账；退货余额不表示已退款。'
                      '未收计划含未发货部分，不是本批还欠，不能当作催收依据或代替发货审核及授信规则。',
                  ...value.warnings,
                ].join('\n'),
              ),
            ],
          ),
          if (pending)
            UtenSummaryField(
              label: '资金核对',
              value: '待财务核对',
              info: value.warnings.join('\n'),
            ),
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s8,
            children: [
              metric(
                '本单已确认收款',
                value.cashReceivedOriginal,
                '已审核并准确归属本订单的客户结算款，不含待确认草稿或其他订单款。',
              ),
              metric(
                '待确认收款',
                value.pendingReceiptOriginal,
                '尚未审核的本单收款草稿，未计入已收及抵扣。',
              ),
              metric(
                '未收计划（辅助）',
                pending ? null : value.plannedRemainingOriginal,
                '此计划包含未发货部分，并非已经发生的本批欠款；实际催收请看出货单本批还欠。',
              ),
              metric(
                '本单可用预收',
                value.prepaymentAvailableOriginal,
                '绑定本单且尚未核销的预收余额。',
              ),
              metric(
                '预收已抵',
                value.prepaymentAppliedOriginal,
                '预收已转销正式应收；这不是第二次收款。',
              ),
              metric(
                '退货金额',
                value.returnCreditOriginal,
                '按本订单来源核对的退货金额，不等于已执行退款。',
              ),
              metric(
                '客户待处理余额',
                value.customerPendingBalanceOriginal,
                '退货等形成的待处理客户余额；仅凭此余额不能宣称已经退款。',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
