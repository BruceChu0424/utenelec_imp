import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/buttons/uten_close_button.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/warehouse_sales_outbound.dart';
import '../repositories/warehouse_delivery_processing_repository.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';
import 'warehouse_sales_picking_fields.dart';

/// Physical warehouse handover is separate from workshop reporting. Requests
/// live in the existing picking draft so a recycled table row cannot lose them.
class WarehouseComponentProcessingActions extends ConsumerStatefulWidget {
  const WarehouseComponentProcessingActions({
    super.key,
    required this.detail,
    required this.component,
    required this.draft,
    required this.onFactsChanged,
    required this.onInputChanged,
    required this.checkpoint,
    this.enabled = true,
  });
  final WarehouseSalesOutboundDetail detail;
  final WarehouseDeliveryComponent component;
  final WarehouseSalesPickingDraft draft;
  final FutureOr<void> Function() onFactsChanged;
  final VoidCallback onInputChanged;
  final Future<void> Function() checkpoint;
  final bool enabled;
  @override
  ConsumerState<WarehouseComponentProcessingActions> createState() =>
      _WarehouseComponentProcessingActionsState();
}

class _WarehouseComponentProcessingActionsState
    extends ConsumerState<WarehouseComponentProcessingActions> {
  bool _busy = false;
  bool _confirming = false;
  Map<String, dynamic>? get _pending =>
      widget.draft.componentRequests[widget.component.id];
  static const _labels = {
    'ISSUE': '发至加工',
    'RECEIVE': '加工收回',
    'CANCEL_ISSUE': '取消发加工',
  };
  bool get _allowed =>
      widget.enabled &&
      widget.detail.header.allows(
        WarehouseSalesOutboundAction.confirmShipment,
      ) &&
      (ref.read(isSuperAdminProvider) ||
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.warehouseSalesOutboundExecute));
  bool get _canRead =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.warehouseSalesOutboundView) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.warehouseSalesOutboundExecute);
  bool _sameOwner(SensitiveReadBoundary boundary) =>
      mounted && ref.read(sensitiveReadBoundaryProvider) == boundary;

  void _pendingChanged(Map<String, dynamic>? value) {
    widget.draft.setComponentRequest(widget.component.id, value);
    widget.onInputChanged();
    if (mounted) setState(() {});
  }

  Future<void> _confirm(String action) async {
    if (!_allowed || _busy || _confirming || _pending != null) return;
    final component = widget.component;
    final warehouse =
        widget.draft.componentWarehouses[component.id] ?? component.warehouseId;
    if (warehouse == null) {
      context.appWarning('请先选择加工物料的实际仓库');
      return;
    }
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final original = <String, dynamic>{
      'expectedVersion': component.revision,
      'warehouseId': warehouse,
      'stockPlace':
          widget.draft.componentPlaces[component.id]?.text.trim() ??
          component.stockPlace ??
          '',
      'requestId': const Uuid().v4(),
    };
    final evidence = TextEditingController();
    setState(() => _confirming = true);
    try {
      final approved = await showUtenAdaptivePanel<bool>(
        context: context,
        widthFraction: UtenPanelWidth.form,
        builder: (dialogContext) => Scaffold(
          appBar: UtenAppBar(
            title: '确认${_labels[action]}',
            showPagePermissionAction: false,
            info: '仓库交接按本次物料和实际仓库记录。发至加工会冻结来源库存；车间报工及仓库收回完成后才能出库。仓库交接不代替车间报工。',
            actions: [
              UtenCloseButton(
                onPressed: () => Navigator.pop(dialogContext, false),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: TextField(
              controller: evidence,
              maxLength: 1000,
              decoration: const UtenInputDecoration(
                InputDecoration(labelText: '加工交接记录', hintText: '记录实际交接凭据'),
              ),
            ),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Wrap(
                spacing: UtenSpacing.s12,
                alignment: WrapAlignment.end,
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                  UtenButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: Text(_labels[action]!),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (approved != true || !_sameOwner(boundary) || !_allowed) return;
      final request = <String, dynamic>{
        'shipmentId': widget.detail.header.id,
        'componentId': component.id,
        'action': action,
        'status': 'UNKNOWN',
        'body': {...original, 'evidence': evidence.text.trim()},
      };
      _pendingChanged(request);
      await _submitOriginal(request);
    } finally {
      evidence.dispose();
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _wait(
    String title,
    Future<void> Function(SensitiveReadBoundary) action, {
    bool readOnly = false,
  }) async {
    if (_busy || (readOnly ? !_canRead : !_allowed)) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _busy = true;
    });
    try {
      await UtenBusyOverlay.run(
        context,
        title: title,
        action: () => action(boundary),
      );
    } catch (error) {
      if (mounted && _sameOwner(boundary)) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitOriginal(Map<String, dynamic> request) =>
      _wait('正在提交加工交接', (boundary) async {
        if (request['shipmentId'] != widget.detail.header.id ||
            request['componentId'] != widget.component.id) {
          throw const FormatException('原加工交接请求不属于当前散件，请保留记录核对');
        }
        final body = Map<String, dynamic>.from(request['body'] as Map);
        if (request['status'] == 'NOT_FOUND') {
          _pendingChanged({...request, 'status': 'UNKNOWN'});
        }
        try {
          await widget.checkpoint();
          if (!_sameOwner(boundary) || !_allowed) return;
          final repository = ref.read(
            warehouseDeliveryProcessingRepositoryProvider,
          );
          final scope = await repository.api.captureRequestScope(
            isCurrent: () => _sameOwner(boundary),
          );
          final updated = await scope.run(
            () => repository.submit(
              request['shipmentId'] as String,
              request['componentId'] as String,
              request['action'] as String,
              body,
            ),
          );
          await scope.verify();
          if (!_sameOwner(boundary)) return;
          if (updated.id != widget.component.id ||
              updated.revision <= (body['expectedVersion'] as num).toInt()) {
            throw const FormatException('加工交接回执未能确认，请核对原请求结果');
          }
          widget.draft.adoptComponentResult(updated);
          _pendingChanged(null);
          await widget.onFactsChanged();
          if (mounted && _sameOwner(boundary)) {
            context.appSuccess('${_labels[request['action']]}已确认');
          }
        } on ApiException catch (error) {
          if (!_sameOwner(boundary)) return;
          if (const {400, 403, 404, 409, 422}.contains(error.httpStatus)) {
            _pendingChanged(null);
            await widget.onFactsChanged();
          }
          rethrow;
        }
      });

  Future<void> _reconcile() => _wait('正在核对加工交接结果', (boundary) async {
    final pending = _pending;
    if (pending == null) return;
    if (pending['shipmentId'] != widget.detail.header.id ||
        pending['componentId'] != widget.component.id) {
      throw const FormatException('原加工交接请求不属于当前散件，请保留记录核对');
    }
    final body = pending['body'] as Map;
    final result = await ref
        .read(warehouseDeliveryProcessingRepositoryProvider)
        .result(pending['shipmentId'] as String, body['requestId'] as String);
    if (!_sameOwner(boundary)) return;
    if (result['found'] == true) {
      if (result['componentId']?.toString() != pending['componentId'] ||
          result['action'] != pending['action']) {
        throw const FormatException('原请求回执与当前加工动作不一致，请保留草稿核对');
      }
      final latest = await ref
          .read(warehouseSalesOutboundRepositoryProvider)
          .detail(widget.detail.header.id);
      if (!_sameOwner(boundary)) return;
      final updated = latest.deliveryComponents
          .where((component) => component.id == widget.component.id)
          .firstOrNull;
      if (updated == null) {
        throw const FormatException('原请求存在，但当前散件已变化，请保留记录核对');
      }
      widget.draft.adoptComponentResult(updated);
      _pendingChanged(null);
      await widget.onFactsChanged();
      if (mounted && _sameOwner(boundary)) context.appSuccess('已核对原加工交接结果');
    } else if (result['found'] == false) {
      _pendingChanged({...pending, 'status': 'NOT_FOUND'});
      if (mounted) context.appWarning('尚未查到原请求，可再次核对或使用原请求重试');
    } else {
      throw const FormatException('未收到明确的请求核对结果，当前记录已保留');
    }
  }, readOnly: true);

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final component = widget.component;
    final pending = _pending;
    if (!_canRead ||
        !component.hasProcessingLifecycle ||
        component.operations.isEmpty ||
        pending == null && !_allowed) {
      return const SizedBox.shrink();
    }
    final actions = pending != null
        ? <Widget>[
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy ? null : _reconcile,
              child: const Text('核对原交接结果'),
            ),
            if (pending['status'] == 'NOT_FOUND')
              UtenButton(
                onPressed: _busy || !_allowed
                    ? null
                    : () => _submitOriginal(pending),
                child: const Text('按原请求重试'),
              ),
          ]
        : <Widget>[
            if (component.processingIssuedAt == null &&
                component.processingWorkshopId != null)
              UtenButton(
                onPressed: _busy || _confirming
                    ? null
                    : () => _confirm('ISSUE'),
                child: const Text('发至加工'),
              ),
            if (component.processingIssuedAt != null &&
                component.processingReceivedAt == null &&
                component.processingComplete)
              UtenButton(
                onPressed: _busy || _confirming
                    ? null
                    : () => _confirm('RECEIVE'),
                child: const Text('加工收回'),
              ),
            if (component.processingIssuedAt != null &&
                component.processingReceivedAt == null &&
                financeAmountUnits(component.processedQty) == BigInt.zero)
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _busy || _confirming
                    ? null
                    : () => _confirm('CANCEL_ISSUE'),
                child: const Text('取消发加工'),
              ),
          ];
    return Wrap(spacing: 6, runSpacing: 4, children: actions);
  }
}
