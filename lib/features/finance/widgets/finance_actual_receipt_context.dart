import 'package:flutter/material.dart';

import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/models/customer_actual_receipt_context.dart';
import '../../../shared/paging/paged_read_intent.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

/// A separately opened customer reference. It never contributes to shipment debt.
class FinanceActualReceiptContext extends StatefulWidget {
  const FinanceActualReceiptContext({super.key, required this.onRead});
  final Future<CustomerActualReceiptContext?> Function() onRead;

  @override
  State<FinanceActualReceiptContext> createState() =>
      _FinanceActualReceiptContextState();
}

class _FinanceActualReceiptContextState
    extends State<FinanceActualReceiptContext> {
  CustomerActualReceiptContext? _value;
  String? _error;
  bool _expanded = false, _busy = false;
  int _generation = 0;

  Future<void> _changeExpanded(bool next) async {
    if (_busy) return;
    if (!next) {
      setState(() => _expanded = false);
      return;
    }
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await PagedReadIntent.scopedRead(
        () => mounted && generation == _generation,
        widget.onRead,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _value = result;
        _expanded = true;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = '客户到账参考读取未完成，可重试；资料变更时先刷新本页。原审核输入已保留。');
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _cancelRead() {
    ++_generation;
    setState(() {
      _busy = false;
      _expanded = false;
    });
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _value;
    return Stack(
      children: [
        UtenCollapsibleSection(
          key: const ValueKey('shipment-customer-receipt-reference'),
          title: '客户到账参考（辅助）',
          initiallyExpanded: false,
          expanded: _expanded,
          onExpandedChanged: _changeExpanded,
          titleTrailing: UtenFieldHintIcon(
            info: [
              '这是客户在本单币种下已核对到账的累计参考，可能涉及其他批次，不是本批已收或还欠。'
                  '展开时重新读取，仅完整账户入账证明计入累计；本批款项以上方货款、已收、还欠为准。',
              if (data == null) '尚未读取客户到账参考。',
              if (data?.basis.isNotEmpty == true) data!.basis,
              if (data != null && data.pendingCount > 0)
                '另有${data.pendingCount}笔已审收款缺少完整账户入账证明，未计入已核对金额。',
            ].join('\n'),
            errorMessage: _error,
          ),
          child: !_expanded
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: UtenSpacing.s16,
                        runSpacing: UtenSpacing.s8,
                        children: [
                          UtenSummaryField(
                            key: const ValueKey(
                              'shipment-actual-receipt-total',
                            ),
                            label: '客户累计到账（辅助）',
                            value: data?.available == true
                                ? financeLocalMoneyWithUnitSuffix(
                                    data?.verifiedCashLocal,
                                  )
                                : '待核对',
                            info: '严格按完整账户入账证明读取的客户累计实到本币金额，不用它抵扣或重算本批余额。',
                          ),
                          if (data?.available == true)
                            UtenSummaryField(
                              label: '已核对',
                              value: '${data!.verifiedCount}笔',
                            ),
                          if (data != null && data.pendingCount > 0)
                            UtenSummaryField(
                              label: '待核对',
                              value: '${data.pendingCount}笔',
                              info: '已审收款尚缺完整账户入账证明，未计入累计。',
                            ),
                        ],
                      ),
                      if (data != null && data.available) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        SizedBox(
                          height: 320,
                          child: MasterDataTableView<CustomerActualReceipt>(
                            emptyMessage: '暂无已核对的收款明细',
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
                                cellBuilder: (_, r) => Text(
                                  financeLocalMoneyWithUnitSuffix(r.cashLocal),
                                ),
                              ),
                            ],
                            items: data.receipts,
                            facets: const {},
                            nullCounts: const {},
                            filters: const {},
                            onFilterChanged: (_, _) {},
                            showPaginationControls: false,
                            showFullscreenToggle: false,
                            headerFilterScopeDescription:
                                '最近${data.receipts.length}/${data.verifiedCount}笔已核对来源；累计来自全部已核对收款，仅作客户辅助参考。',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        if (_busy)
          UtenBusyOverlay(
            title: '正在核对客户到账参考',
            showDoNotLeaveHint: false,
            onCancel: _cancelRead,
          ),
      ],
    );
  }
}
