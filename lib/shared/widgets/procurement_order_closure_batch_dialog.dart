import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/inputs/uten_input_decoration.dart';
import '../../components/inputs/uten_field_message.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/network/server_config.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../auth/permissions.dart';
import '../badges/badge_registry.dart';
import '../formatters/exact_decimal.dart';
import '../models/procurement_order_closure.dart';
import '../providers/authenticated_scope_provider.dart';
import 'procurement_order_closure_blocker_action.dart';

Future<bool?> showProcurementOrderClosureBatchDialog(
  BuildContext context, {
  required List<ProcurementOrderClosureTarget> orders,
  required bool Function() stillCurrent,
  int unsupportedRowCount = 0,
  List<String> unsupportedLabels = const [],
}) {
  final unique = uniqueProcurementClosureTargets(orders);
  if (unique.isEmpty || unique.length > 50) return Future.value(false);
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BatchDialog(
      orders: unique,
      stillCurrent: stillCurrent,
      unsupportedRowCount: unsupportedRowCount,
      unsupportedLabels: unsupportedLabels,
    ),
  );
}

class _BatchDialog extends ConsumerStatefulWidget {
  const _BatchDialog({
    required this.orders,
    required this.stillCurrent,
    required this.unsupportedRowCount,
    required this.unsupportedLabels,
  });
  final List<ProcurementOrderClosureTarget> orders;
  final bool Function() stillCurrent;
  final int unsupportedRowCount;
  final List<String> unsupportedLabels;
  @override
  ConsumerState<_BatchDialog> createState() => _BatchDialogState();
}

class _BatchDialogState extends ConsumerState<_BatchDialog> {
  static const _path = '/finance/procurement-approvals/order-closures';
  final _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  final Map<String, ProcurementOrderClosurePreview> _previews = {};
  AuthenticatedRequestScope? _scope;
  ModalRoute<dynamic>? _route;
  String _mode = 'CLOSE';
  String? _error;
  bool _loading = true,
      _busy = false,
      _invalidated = false,
      _confirmedEligibleOnly = false;
  List<ProcurementOrderClosureTarget> get _eligibleOrders => widget.orders
      .where((order) => _previews[order.identity]?.canSubmit == true)
      .toList(growable: false);
  int get _unavailableCount =>
      widget.orders.length -
      _eligibleOrders.length +
      widget.unsupportedRowCount;
  bool get _current => mounted && !_invalidated && widget.stillCurrent();
  bool get _ready =>
      _previews.length == widget.orders.length && _eligibleOrders.isNotEmpty;
  bool get _canReorder =>
      _previews.length == widget.orders.length &&
      _eligibleOrders.isNotEmpty &&
      _eligibleOrders.every(
        (order) => _previews[order.identity]?.canReorder == true,
      );

  @override
  void initState() {
    super.initState();
    ref.listenManual(authenticatedScopeProvider, (previous, next) {
      if (previous != next) _retire();
    });
    ref.listenManual(apiBaseUrlProvider, (previous, next) {
      if (previous != next) _retire();
    });
    ref.listenManual(apiClientProvider, (previous, next) {
      if (!identical(previous, next)) _retire();
    });
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) _retire();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
  }

  void _retire() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _previews.clear();
    _reason.clear();
    if (_route?.isActive == true) _route!.navigator?.removeRoute(_route!);
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current) return;
    setState(() {
      _loading = true;
      _error = null;
      _confirmedEligibleOnly = false;
    });
    try {
      final api = ref.read(apiClientProvider);
      final scope = _scope ??= await api.captureRequestScope(
        isCurrent: () => _current,
      );
      final json = await scope.run(
        () => api.post(
          '$_path/batch-preview',
          body: {
            'orders': widget.orders.map((order) => order.toJson()).toList(),
          },
        ),
      );
      if (!mounted || !_current) return;
      setState(() {
        _previews.clear();
        for (final item in json['items'] as List? ?? const []) {
          if (item is Map) {
            _previews['${item['orderType']}:${item['orderId']}'] =
                ProcurementOrderClosurePreview.fromJson(
                  item.cast<String, dynamic>(),
                );
          }
        }
        if (!_canReorder) _mode = 'CLOSE';
      });
    } catch (error) {
      if (mounted && _current) {
        setState(
          () => _error = AppLocalizations.of(context).orderClosureLoadFailed,
        );
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openBlocker(String route) async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      await _scope?.verify();
      if (!mounted || !_current) return;
      await context.push<void>(route);
      if (mounted && _current) await _load();
    } catch (error) {
      if (mounted && _current) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_current ||
        _busy ||
        !_ready ||
        (_unavailableCount > 0 && !_confirmedEligibleOnly) ||
        (_mode == 'CLOSE_AND_REORDER' && !_canReorder) ||
        _form.currentState?.validate() != true) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _scope!.run(
        () => ref
            .read(apiClientProvider)
            .post(
              '$_path/batch-requests',
              body: {
                'mode': _mode,
                'reason': _reason.text.trim(),
                'items': [
                  for (final order in _eligibleOrders)
                    {
                      ...order.toJson(),
                      'expectedFingerprint':
                          _previews[order.identity]!.fingerprint,
                    },
                ],
              },
            ),
      );
      if (!mounted || !_current) return;
      refreshBadges(ref);
      context.appSuccess(AppLocalizations.of(context).orderClosureSubmitted);
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted && _current) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_busy,
      child: UtenAlertDialog(
        key: const Key('procurement-order-closure-batch-dialog'),
        maxWidth: 800,
        title: Text(
          '${widget.orders.length == 1 ? l10n.orderClosureAction : l10n.orderClosureBatchAction} (${widget.orders.length})',
        ),
        content: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  UtenButton(onPressed: _load, child: Text(l10n.commonRetry)),
                ],
              )
            : Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.orderClosureWholeOrderHint),
                    Text(
                      '${l10n.orderClosureEligibleOrders}: ${_eligibleOrders.length} · ${l10n.orderClosureUnavailableOrders}: $_unavailableCount',
                    ),
                    if (widget.unsupportedRowCount > 0)
                      Text(
                        '${l10n.orderClosureOrdersOnly} (${widget.unsupportedRowCount})',
                      ),
                    for (final label in widget.unsupportedLabels)
                      Text('$label: ${l10n.orderClosureUnsupportedRowReason}'),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(l10n.orderClosureReceiptFinalityHint),
                    RadioGroup<String>(
                      groupValue: _mode,
                      onChanged: (mode) {
                        if (!_busy &&
                            mode != null &&
                            (mode != 'CLOSE_AND_REORDER' || _canReorder)) {
                          setState(() => _mode = mode);
                        }
                      },
                      child: Column(
                        children: [
                          RadioListTile<String>(
                            value: 'CLOSE',
                            title: Text(l10n.orderClosureAction),
                            subtitle: Text(l10n.orderClosureCloseHint),
                            enabled: !_busy,
                          ),
                          RadioListTile<String>(
                            value: 'CLOSE_AND_REORDER',
                            title: Text(l10n.orderClosureReorder),
                            subtitle: Text(l10n.orderClosureReorderHint),
                            enabled: !_busy && _canReorder,
                          ),
                        ],
                      ),
                    ),
                    for (var index = 0; index < widget.orders.length; index++)
                      _orderPreview(widget.orders[index], index),
                    if (_unavailableCount > 0 && _eligibleOrders.isNotEmpty)
                      CheckboxListTile(
                        key: const Key(
                          'procurement-order-closure-confirm-eligible',
                        ),
                        value: _confirmedEligibleOnly,
                        onChanged: _busy
                            ? null
                            : (value) => setState(
                                () => _confirmedEligibleOnly = value == true,
                              ),
                        title: Text(
                          '${l10n.orderClosureEligibleOnlyConfirm} (${_eligibleOrders.length})',
                        ),
                      ),
                    TextFormField(
                      key: const Key('procurement-order-closure-batch-reason'),
                      errorBuilder: utenTextFieldErrorBuilder,
                      controller: _reason,
                      enabled: !_busy,
                      maxLength: 500,
                      minLines: 2,
                      maxLines: 4,
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          labelText: l10n.orderClosureReason,
                          hintText: l10n.orderClosureReasonHint,
                        ),
                      ),
                      validator: (value) => value?.trim().isNotEmpty == true
                          ? null
                          : l10n.orderClosureReasonRequired,
                    ),
                  ],
                ),
              ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          UtenButton(
            key: const Key('procurement-order-closure-batch-submit'),
            type: UtenButtonType.danger,
            isLoading: _busy,
            onPressed:
                !_loading &&
                    _error == null &&
                    _ready &&
                    (_unavailableCount == 0 || _confirmedEligibleOnly) &&
                    _current &&
                    !_busy
                ? _submit
                : null,
            child: Text(
              '${l10n.orderClosureSubmit} (${_eligibleOrders.length})',
            ),
          ),
        ],
      ),
    );
  }

  Widget _orderPreview(ProcurementOrderClosureTarget order, int index) {
    final l10n = AppLocalizations.of(context);
    final preview = _previews[order.identity];
    return ExpansionTile(
      key: ValueKey('closure-preview-${order.identity}'),
      initiallyExpanded:
          widget.orders.length == 1 || preview?.canSubmit != true,
      title: Text(
        preview?.billNo.isNotEmpty == true
            ? preview!.billNo
            : '${l10n.orderClosureAction} ${index + 1}',
      ),
      childrenPadding: const EdgeInsets.all(UtenSpacing.s8),
      children: [
        if (preview?.canSubmit != true)
          Text(
            preview?.blockReason ?? l10n.orderClosureUnavailable,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (preview?.blocker case final blocker?)
          ProcurementOrderClosureBlockerAction(
            blocker: blocker,
            busy: _busy,
            onOpen: _openBlocker,
          ),
        if (preview?.unverifiedQuantity == true)
          Text(l10n.orderClosureUnverifiedQuantity),
        if (preview?.canReorder == false && preview?.blockReorderReason != null)
          Text(preview!.blockReorderReason!),
        for (final line
            in preview?.items ?? const <ProcurementOrderClosureLine>[])
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Text(
              '${line.goodsCode} ${line.goodsName}\n${l10n.orderClosureRemaining}: ${financeExactTrimmed(line.remainingQty) ?? '—'} ${line.unitName} · ${l10n.orderClosureRemainingGift}: ${financeExactTrimmed(line.remainingGiftQty) ?? '—'} ${line.unitName}',
            ),
          ),
      ],
    );
  }
}
