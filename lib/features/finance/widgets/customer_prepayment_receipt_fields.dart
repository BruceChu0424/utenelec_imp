import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/widgets/sales_order_picker.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';

class CustomerPrepaymentReceiptFields extends ConsumerWidget {
  const CustomerPrepaymentReceiptFields({
    super.key,
    required this.salesOrderId,
    required this.salesOrderBillNo,
    required this.clientLabel,
    required this.currencyLabel,
    required this.exchangeRateController,
    required this.amountController,
    required this.enabled,
    required this.onOrderSelected,
  });

  final String? salesOrderId;
  final String? salesOrderBillNo;
  final String clientLabel;
  final String currencyLabel;
  final TextEditingController exchangeRateController;
  final TextEditingController amountController;
  final bool enabled;
  final ValueChanged<SalesDocListItem> onOrderSelected;

  Future<void> _pickOrder(BuildContext context, WidgetRef ref) async {
    final selected = await showSalesOrderPicker(context, ref);
    if (selected != null) onOrderSelected(selected);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(UtenSpacing.s8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(UtenRadius.md),
          ),
          child: Text(
            '客户预收由财务登记实际到账。必须绑定已审核销售订单；客户和币种随订单锁定，'
            '不生成普通应收核销明细。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenFormGrid(
          children: [
            InputDecorator(
              decoration: const InputDecoration(labelText: '销售订单（必选）'),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      salesOrderBillNo ?? salesOrderId ?? '尚未选择',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.small,
                    icon: Icons.search_rounded,
                    onPressed: enabled ? () => _pickOrder(context, ref) : null,
                    child: Text(salesOrderId == null ? '选择' : '更换'),
                  ),
                ],
              ),
            ),
            InputDecorator(
              decoration: const InputDecoration(labelText: '客户（订单锁定）'),
              child: Text(clientLabel),
            ),
            InputDecorator(
              decoration: const InputDecoration(labelText: '币种（订单锁定）'),
              child: Text(currencyLabel),
            ),
            TextField(
              key: const ValueKey('customer-prepayment-receipt-rate'),
              controller: exchangeRateController,
              enabled: enabled && salesOrderId != null,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '到账汇率（必填）',
                helperText: '按本次实际到账汇率填写；服务端以六位精度校验',
              ),
            ),
            TextField(
              key: const ValueKey('customer-prepayment-receipt-amount'),
              controller: amountController,
              enabled: enabled && salesOrderId != null,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '本次预收原币金额（必填）'),
            ),
          ],
        ),
        if (salesOrderId case final orderId?) ...[
          const SizedBox(height: UtenSpacing.s8),
          SalesOrderMoneySummaryCard(salesOrderId: orderId),
        ],
      ],
    );
  }
}
