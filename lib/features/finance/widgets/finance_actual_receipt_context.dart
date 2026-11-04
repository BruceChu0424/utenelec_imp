import 'package:flutter/material.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/models/customer_actual_receipt_context.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

/// Gives shipment reviewers actual bank context without treating accumulated receipts as free credit.
class FinanceActualReceiptContext extends StatelessWidget {
  const FinanceActualReceiptContext({super.key, required this.value});
  final CustomerActualReceiptContext? value;
  @override
  Widget build(BuildContext context) {
    final data = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Text(
          data?.available == true
              ? '已核对到账累计：${financeLocalMoneyWithUnitSuffix(data?.verifiedCashLocal)}（${data?.verifiedCount}笔，本单币种）'
              : '实际到账来源尚未读取',
          key: const Key('shipment-actual-receipt-total'),
        ),
        if (data != null && data.pendingCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: UtenInlineNotice(
              message:
                  '另有${data.pendingCount}笔已审收款尚缺完整账户入账证明，未计入已核对金额。请核对后人工决定放行。',
            ),
          ),
        if (data?.available == true) ...[
          const SizedBox(height: 6),
          Text(data!.basis, style: Theme.of(context).textTheme.bodySmall),
          if (data.receipts.isNotEmpty)
            UtenCollapsibleSection(
              title: '已核对到账明细（显示${data.receipts.length}/${data.verifiedCount}）',
              initiallyExpanded: false,
              child: SizedBox(
                height: 320,
                child: MasterDataTableView<CustomerActualReceipt>(
                  tableKey: 'finance.shipment.actual-receipts',
                  columns: [
                    MasterColumnDef(
                      key: 'billNo',
                      label: '收款单号',
                      width: 180,
                      value: (r) => r.billNo,
                      columnSearchEnabled: false,
                    ),
                    MasterColumnDef(
                      key: 'bankBookedAt',
                      label: '实际到账时间',
                      width: 210,
                      value: (r) => r.bankBookedAt,
                      columnSearchEnabled: false,
                    ),
                    MasterColumnDef(
                      key: 'accountCurrency',
                      label: '账户币种',
                      width: 100,
                      value: (r) => r.accountCurrency,
                      columnSearchEnabled: false,
                    ),
                    MasterColumnDef(
                      key: 'accountAmount',
                      label: '实收账户原币',
                      width: 160,
                      value: (r) => r.accountAmount,
                      columnSearchEnabled: false,
                      cellBuilder: (_, r) =>
                          Text(financeMoneyText(r.accountAmount)),
                    ),
                    MasterColumnDef(
                      key: 'cashLocal',
                      label: '实收本币',
                      width: 160,
                      value: (r) => r.cashLocal,
                      columnSearchEnabled: false,
                      cellBuilder: (_, r) =>
                          Text(financeLocalMoneyWithUnitSuffix(r.cashLocal)),
                    ),
                  ],
                  items: data.receipts,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  showPaginationControls: false,
                  showFullscreenToggle: false,
                  headerFilterScopeDescription: '本次列出的最近已核对来源；累计金额来自全部已核对收款',
                ),
              ),
            ),
        ],
      ],
    );
  }
}
