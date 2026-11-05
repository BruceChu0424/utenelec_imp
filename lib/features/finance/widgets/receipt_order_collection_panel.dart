import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart' show CancelToken;

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog_chrome.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/widgets/sales_order_picker.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';
import 'ar_ap_picker_dialog.dart';

class ReceiptOrderCollection {
  const ReceiptOrderCollection({
    required this.order,
    required this.amount,
    required this.prepayment,
    required this.items,
  });
  final SalesDocListItem order;
  final String amount;
  final bool prepayment;
  final List<AppliedArAp> items;
}

Future<ReceiptOrderCollection?> showReceiptOrderCollectionPanel(
  BuildContext context, {
  SalesDocListItem? initialOrder,
  String? initialAmount,
  String? appliedLedgerId,
}) => showUtenAdaptivePanel<ReceiptOrderCollection>(
  context: context,
  drawerWidth: 760,
  compactHeightFactor: .9,
  builder: (_) => _ReceiptOrderCollectionPanel(
    initialOrder: initialOrder,
    initialAmount: initialAmount,
    appliedLedgerId: appliedLedgerId,
  ),
);

class _ReceiptOrderCollectionPanel extends ConsumerStatefulWidget {
  const _ReceiptOrderCollectionPanel({
    this.initialOrder,
    this.initialAmount,
    this.appliedLedgerId,
  });
  final SalesDocListItem? initialOrder;
  final String? initialAmount;
  final String? appliedLedgerId;
  @override
  ConsumerState<_ReceiptOrderCollectionPanel> createState() =>
      _ReceiptOrderCollectionPanelState();
}

class _ReceiptOrderCollectionPanelState
    extends ConsumerState<_ReceiptOrderCollectionPanel> {
  final _amount = TextEditingController();
  SalesDocListItem? _order;
  bool _busy = false;
  bool _retired = false;
  int _requestRevision = 0;
  CancelToken? _readCancellation;
  late final bool Function() _ownerCurrent;
  String? _error;

  @override
  void initState() {
    super.initState();
    _order = widget.initialOrder;
    _amount.text = widget.initialAmount ?? '';
    _ownerCurrent = captureReadOwner(ref);
    listenReadOwner(ref, () {
      _readCancellation?.cancel('read owner retired');
      setState(() {
        _retired = true;
        _busy = false;
        ++_requestRevision;
        _error = '登录身份、权限或连接已变化，原输入已保留；请关闭后重新打开';
      });
    });
  }

  bool get _current => mounted && !_retired && _ownerCurrent();

  @override
  void dispose() {
    _readCancellation?.cancel('panel closed');
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_busy || !_current) return;
    final order = await showSalesOrderPicker(
      context,
      ref,
      receiptSources: true,
    );
    if (!_current || order == null) return;
    setState(() {
      _order = order;
      _error = null;
    });
  }

  Future<void> _confirm() async {
    if (_busy || !_current) return;
    final order = _order;
    final amount = financeExactDecimal(_amount.text.trim());
    if (order == null ||
        amount == null ||
        (financeAmountUnits(amount) ?? BigInt.zero) <= BigInt.zero) {
      setState(() => _error = order == null ? '请选择销售订货单' : '请填写大于0的本次收款金额');
      return;
    }
    final revision = ++_requestRevision;
    final cancellation = CancelToken();
    _readCancellation = cancellation;
    bool current() => _current && revision == _requestRevision;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final json = await ref
          .read(apiClientProvider)
          .postCancellable(
            '/finance/receipts/order-collection-preview',
            body: {
              'salesOrderId': order.id,
              'amountOriginal': amount,
              if (widget.appliedLedgerId != null)
                'appliedLedgerId': widget.appliedLedgerId,
            },
            cancelToken: cancellation,
          );
      if (!mounted || !current()) return;
      if (json['salesOrderId'] != order.id ||
          json['clientId'] != order.clientId ||
          json['currencyId'] != order.currencyId) {
        throw StateError('订单资料已变化，请重新选择订单');
      }
      final kind = json['receiptKind'];
      if (kind != 'AR_SETTLEMENT' && kind != 'CUSTOMER_PREPAYMENT') {
        throw StateError('订单收款来源未能确认');
      }
      if (financeAmountUnits(
            financeExactDecimal(json['amountOriginal']) ?? '',
          ) !=
          financeAmountUnits(amount)) {
        throw StateError('本次收款金额核对不一致，请重新核对');
      }
      final items = [
        for (final raw in json['items'] as List? ?? const [])
          if (raw is Map)
            AppliedArAp(
              ledgerId: raw['ledgerId'].toString(),
              appliedBillNo: raw['billNo']?.toString(),
              sourceDocNo: raw['sourceDocNo']?.toString(),
              sourceDocType: 'SALES_SHIPMENT',
              receiptAmountText:
                  financeExactDecimal(raw['amountOriginal']) ?? '',
              balanceOriginalText: financeExactDecimal(raw['balanceOriginal']),
              currencyId: order.currencyId,
              salesOrderIds: [order.id],
              authoritativeSalesOrderId: order.id,
              requestedSalesOrderId: order.id,
              salesOrderNos: [order.billNo ?? order.id],
            ),
      ];
      final amounts = items
          .map((item) => financeAmountUnits(item.receiptAmountText))
          .toList();
      if (kind == 'AR_SETTLEMENT' &&
              (items.isEmpty ||
                  items.any(
                    (item) => item.ledgerId == 'null' || item.ledgerId.isEmpty,
                  ) ||
                  amounts.any(
                    (value) => value == null || value <= BigInt.zero,
                  ) ||
                  amounts.fold<BigInt>(
                        BigInt.zero,
                        (sum, value) => sum + (value ?? BigInt.zero),
                      ) !=
                      financeAmountUnits(amount)) ||
          kind == 'CUSTOMER_PREPAYMENT' && items.isNotEmpty) {
        throw StateError('订单收款分配未完整对应本次金额，请重新核对');
      }
      Navigator.of(context).pop(
        ReceiptOrderCollection(
          order: order,
          amount: amount,
          prepayment: kind == 'CUSTOMER_PREPAYMENT',
          items: items,
        ),
      );
    } catch (error) {
      if (mounted && current()) {
        setState(() => _error = humanErrorMessage(error) ?? error.toString());
      }
    } finally {
      if (identical(_readCancellation, cancellation)) _readCancellation = null;
      if (mounted && revision == _requestRevision) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Column(
        children: [
          UtenPanelHeader(
            title: '按订货单收款',
            onClose: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    icon: Icons.search_rounded,
                    onPressed: _busy || _retired ? null : _pick,
                    child: Text(_order?.billNo ?? '选择销售订货单'),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  TextField(
                    key: const ValueKey('order-collection-amount'),
                    controller: _amount,
                    enabled: !_busy && !_retired,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        labelText: '本次收款原币金额',
                        error: utenFieldError(_error),
                      ),
                      info:
                          '先引用订货单再填本次金额。已立账应收按本订单来源分配，尚无正式应收时登记本订单预收。'
                          '此处为客户结算原币金额，银行净到账和手续费在收款单中分别填写。',
                    ),
                  ),
                  if (!_retired)
                    if (_order case final order?) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      SalesOrderMoneySummaryCard(salesOrderId: order.id),
                    ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: UtenDialogActions(
              children: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                UtenButton(
                  key: const ValueKey('order-collection-confirm'),
                  onPressed: _busy || _retired ? null : _confirm,
                  child: const Text('引用本次收款'),
                ),
              ],
            ),
          ),
        ],
      ),
      if (_busy && !_retired)
        UtenBusyOverlay(
          title: '核对订单收款来源',
          cancelLabel: '取消核对',
          showDoNotLeaveHint: false,
          onCancel: () => setState(() {
            _readCancellation?.cancel('preview cancelled');
            ++_requestRevision;
            _busy = false;
            _error = '已取消核对，原输入已保留';
          }),
        ),
    ],
  );
}
