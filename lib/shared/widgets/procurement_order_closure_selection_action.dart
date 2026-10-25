import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/ui/app_notification.dart';
import '../../core/network/api_client.dart';
import '../../core/network/server_config.dart';
import '../auth/permissions.dart';
import '../models/procurement_order_closure.dart';
import '../providers/authenticated_scope_provider.dart';

class ProcurementOrderClosureSelectionAction extends ConsumerStatefulWidget {
  const ProcurementOrderClosureSelectionAction({
    super.key,
    required this.selectedRowCount,
    required this.targets,
    required this.onSubmit,
    this.busy = false,
  });
  final int selectedRowCount;
  final List<ProcurementOrderClosureTarget?> targets;
  final Future<void> Function(
    List<ProcurementOrderClosureTarget> orders,
    int unsupportedRows,
  )
  onSubmit;
  final bool busy;

  @override
  ConsumerState<ProcurementOrderClosureSelectionAction> createState() =>
      _SelectionState();
}

class _SelectionState
    extends ConsumerState<ProcurementOrderClosureSelectionAction> {
  Timer? _debounce;
  int _generation = 0, _eligibleCount = 0;
  bool _checking = false, _failed = false;
  String _seen = '';
  String? _blockedReason;
  bool _valid(ProcurementOrderClosureTarget? target) =>
      target != null &&
      target.orderId.isNotEmpty &&
      const {'PURCHASE', 'SUBCONTRACT'}.contains(target.orderType);
  List<ProcurementOrderClosureTarget> get _orders =>
      uniqueProcurementClosureTargets(
        widget.targets
            .where((target) => _valid(target))
            .whereType<ProcurementOrderClosureTarget>(),
      );
  String get _signature =>
      '${widget.selectedRowCount}|${widget.busy}|${widget.targets.map((target) => target == null ? 'unsupported' : '${target.identity}:${target.localRevision}').join('|')}';
  bool _hasAction(ProcurementOrderClosureTarget order) =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(
            order.orderType == 'PURCHASE'
                ? Perm.purchaseOrderSubmitFinance
                : Perm.subcontractOrderSubmitFinance,
          );
  @override
  void initState() {
    super.initState();
    ref.listenManual(authenticatedScopeProvider, (_, _) => _queue());
    ref.listenManual(apiBaseUrlProvider, (_, _) => _queue());
    ref.listenManual(apiClientProvider, (_, _) => _queue());
    ref.listenManual(currentPermissionsProvider, (_, _) => _queue());
    ref.listenManual(isSuperAdminProvider, (_, _) => _queue());
    WidgetsBinding.instance.addPostFrameCallback((_) => _queue());
  }

  @override
  void didUpdateWidget(
    covariant ProcurementOrderClosureSelectionAction oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (_signature != _seen) _queue();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    ++_generation;
    super.dispose();
  }

  void _queue() {
    if (!mounted) return;
    final generation = ++_generation;
    _debounce?.cancel();
    _seen = _signature;
    final orders = _orders;
    final shouldCheck =
        !widget.busy &&
        widget.selectedRowCount > 0 &&
        widget.targets.length == widget.selectedRowCount &&
        orders.isNotEmpty &&
        orders.length <= 50 &&
        orders.any(_hasAction);
    setState(() {
      _eligibleCount = 0;
      _checking = shouldCheck;
      _failed = false;
      _blockedReason = null;
    });
    if (!shouldCheck) return;
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _check(orders, generation),
    );
  }

  Future<void> _check(
    List<ProcurementOrderClosureTarget> orders,
    int generation,
  ) async {
    bool current() => mounted && generation == _generation;
    try {
      final api = ref.read(apiClientProvider);
      final scope = await api.captureRequestScope(isCurrent: current);
      final json = await scope.run(
        () => api.post(
          '/finance/procurement-approvals/order-closures/batch-preview',
          body: {'orders': orders.map((order) => order.toJson()).toList()},
        ),
      );
      if (!current()) return;
      final requested = {for (final order in orders) order.identity: order};
      final eligible = <String>{};
      String? blockedReason;
      for (final item in json['items'] as List? ?? const []) {
        if (item is Map) {
          final identity = '${item['orderType']}:${item['orderId']}';
          final order = requested[identity];
          final preview = ProcurementOrderClosurePreview.fromJson(
            item.cast<String, dynamic>(),
          );
          if (order != null && _hasAction(order) && preview.canSubmit) {
            eligible.add(identity);
          } else {
            blockedReason ??= preview.blockReason;
          }
        }
      }
      setState(() {
        _eligibleCount = eligible.length;
        _checking = false;
        _blockedReason = blockedReason;
      });
    } catch (_) {
      if (current()) {
        setState(() {
          _eligibleCount = 0;
          _checking = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        lookupAppLocalizations(const Locale('zh'));
    final orders = _orders;
    final issue = widget.busy
        ? l10n.orderClosureBusy
        : widget.selectedRowCount == 0
        ? l10n.orderClosureSelectOrders
        : widget.targets.length != widget.selectedRowCount
        ? l10n.orderClosureSelectionChanged
        : orders.length > 50
        ? l10n.orderClosureBatchLimit
        : orders.isEmpty
        ? l10n.orderClosureOrdersOnly
        : !orders.any(_hasAction)
        ? l10n.orderClosureMissingPermission
        : _checking
        ? l10n.orderClosureEligibilityChecking
        : _failed
        ? l10n.orderClosureEligibilityFailed
        : _eligibleCount == 0
        ? (_blockedReason ?? l10n.orderClosureNoEligibleOrders)
        : null;
    return Tooltip(
      message: issue ?? l10n.orderClosureWholeOrderHint,
      child: UtenButton(
        key: const Key('procurement-order-closure-selection-action'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.stop_circle_outlined,
        isLoading: _checking,
        onPressed: issue == null
            ? () => widget.onSubmit(
                orders,
                widget.targets.where((target) => !_valid(target)).length,
              )
            : null,
        onDisabledTap: () =>
            context.appInfo(issue ?? l10n.orderClosureSelectOrders),
        child: Text(
          '${_eligibleCount > 1 ? l10n.orderClosureBatchAction : l10n.orderClosureAction} ($_eligibleCount)',
        ),
      ),
    );
  }
}
