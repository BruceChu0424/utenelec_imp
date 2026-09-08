import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/widgets/sales_order_picker.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';

class CustomerPrepaymentReceiptFields extends ConsumerWidget {
  const CustomerPrepaymentReceiptFields({
    super.key,
    required this.salesOrderId,
    required this.salesOrderBillNo,
    required this.clientLabel,
    required this.currencyLabel,
    required this.exchangeRateController,
    required this.amountController,
    this.showSettlementFields = true,
    required this.enabled,
    required this.onOrderSelected,
  });

  final String? salesOrderId;
  final String? salesOrderBillNo;
  final String clientLabel;
  final String currencyLabel;
  final TextEditingController exchangeRateController;
  final TextEditingController amountController;
  final bool showSettlementFields;
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
        UtenFormGrid(
          children: [
            InputDecorator(
              decoration: UtenInputDecoration(
                const InputDecoration(labelText: '销售订单(必选)'),
                info: workflowFieldText(context).workflowPrepaymentOrderHint,
              ),
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
              child: Text(
                '客户：$clientLabel\n币种：$currencyLabel',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (showSettlementFields) ...[
              TextField(
                key: const ValueKey('customer-prepayment-receipt-rate'),
                controller: exchangeRateController,
                ignorePointers: false,
                enabled: enabled && salesOrderId != null,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: UtenInputDecoration(
                  InputDecoration(
                    label: fieldLabel(
                      '当前批次实际到账汇率(必填)',
                      Theme.of(context),
                      info: workflowFieldText(context).workflowExchangeRateHint,
                    ),
                  ),
                ),
              ),
              TextField(
                key: const ValueKey('customer-prepayment-receipt-amount'),
                controller: amountController,
                enabled: enabled && salesOrderId != null,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: UtenInputDecoration(
                  const InputDecoration(labelText: '本批预收原币金额(必填)'),
                  info: workflowFieldText(context).workflowPrepaymentAmountHint,
                ),
              ),
            ],
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
