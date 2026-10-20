import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/goods_bom_item.dart';
import '../models/goods_node.dart';
import '../providers/goods_clipboard.dart';
import '../repositories/goods_bom_batch_repository.dart';
import 'bom_component_picker.dart';
import 'bom_component_quantity_field.dart';
import 'periodic_bom_confirmation.dart';

Future<BomBatchResult?> showGoodsBomBatchMaintenanceDialog({
  required BuildContext context,
  required BomBatchAction action,
  required Iterable<String> targetGoodsIds,
  List<GoodsBomItem> initialComponents = const [],
}) {
  final boundary = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(sensitiveReadBoundaryProvider);
  final targets = List<String>.unmodifiable(targetGoodsIds);
  final components = List<GoodsBomItem>.unmodifiable(initialComponents);
  return showDialog<BomBatchResult>(
    context: context,
    builder: (_) => _BatchMaintenanceDialog(
      action: action,
      targetGoodsIds: targets,
      initialComponents: components,
      expectedBoundary: boundary,
    ),
  );
}

class _BatchMaintenanceDialog extends ConsumerStatefulWidget {
  const _BatchMaintenanceDialog({
    required this.action,
    required this.targetGoodsIds,
    required this.initialComponents,
    required this.expectedBoundary,
  });
  final BomBatchAction action;
  final List<String> targetGoodsIds;
  final List<GoodsBomItem> initialComponents;
  final SensitiveReadBoundary expectedBoundary;
  @override
  ConsumerState<_BatchMaintenanceDialog> createState() =>
      _BatchMaintenanceDialogState();
}

class _ComponentInput {
  _ComponentInput(this.goods, {this.copied})
    : quantity = TextEditingController(
        text: copied == null
            ? (goods.isPeriodicIssue ? '' : '1')
            : formatBomQty(
                copied.isPeriodicEdge
                    ? copied.periodicUnitWeightGrams ?? copied.qty ?? 0
                    : copied.qty ?? 0,
              ),
      );
  final GoodsListItem goods;
  final GoodsBomItem? copied;
  final TextEditingController quantity;
}

class _BatchMaintenanceDialogState
    extends ConsumerState<_BatchMaintenanceDialog> {
  late final SensitiveReadBoundary _boundary;
  late final GoodsBomBatchRepository _repository;
  late final Future<AuthenticatedRequestScope> _requestScope;
  late final NavigatorState _navigator;
  final List<_ComponentInput> _components = [];
  BomBatchPreview? _preview;
  bool _busy = false;
  bool _recoveringCommit = false;
  bool _expanded = false;
  String? _error;
  List<ApiFieldError> _problems = const [];
  ModalRoute<dynamic>? _confirmationRoute;
  ModalRoute<dynamic>? _ownRoute;
  bool _invalidated = false;
  AppLocalizations get _l10n => AppLocalizations.of(context);
  bool get _remove => widget.action == BomBatchAction.remove;
  bool get _overwrite => widget.action == BomBatchAction.overwrite;
  bool get _current {
    if (!mounted ||
        _invalidated ||
        _boundary.identity?.readOnly == true ||
        _boundary != ref.read(sensitiveReadBoundaryProvider) ||
        !identical(_repository, ref.read(goodsBomBatchRepositoryProvider))) {
      return false;
    }
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.goodsBomEdit) &&
        (_remove
            ? permissions.contains(Perm.goodsBomDelete)
            : permissions.contains(Perm.goodsBomCreate)) &&
        (!_overwrite || permissions.contains(Perm.goodsBomDelete));
  }

  @override
  void initState() {
    super.initState();
    _boundary = widget.expectedBoundary;
    _navigator = Navigator.of(context);
    _repository = ref.read(goodsBomBatchRepositoryProvider);
    if (_boundary != ref.read(sensitiveReadBoundaryProvider)) {
      _invalidated = true;
      _closeRoutes();
    }
    _requestScope = _boundary.api.captureRequestScope(
      isCurrent: () => _current,
    );
    unawaited(
      _requestScope.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    _addCopies(widget.initialComponents);
    ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
      if (next == _boundary || !mounted) return;
      _invalidated = true;
      _closeRoutes();
    });
  }

  void _closeRoutes() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_navigator.mounted) return;
      // A child confirmation may only have built after the boundary listener ran.
      for (final route in [_confirmationRoute, _ownRoute]) {
        if (route != null && route.isActive) _navigator.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    for (final component in _components) {
      component.quantity.dispose();
    }
    super.dispose();
  }

  void _invalidate() {
    _preview = null;
    _error = null;
    _problems = const [];
  }

  void _addCopies(List<GoodsBomItem> items) {
    for (final item in items) {
      if (_components.any(
        (component) => component.goods.id == item.componentGoodsId,
      )) {
        continue;
      }
      _components.add(
        _ComponentInput(
          GoodsListItem(
            id: item.componentGoodsId,
            code: item.componentCode,
            name: item.componentName,
            colorName: item.componentColorName,
            unitName: item.componentUnitName,
            issueMethod: item.componentIssueMethod ?? GoodsIssueMethod.order,
            price: item.price,
          ),
          copied: item,
        ),
      );
    }
  }

  Future<void> _pick() async {
    if (!_current || _busy || _recoveringCommit || _overwrite) return;
    final picked = await ref.read(
      _remove ? bomComponentRemovalPickerProvider : bomComponentPickerProvider,
    )(context, ref);
    if (!_current || _busy || _recoveringCommit || picked.isEmpty) return;
    setState(() {
      for (final goods in picked) {
        if (_components.every((component) => component.goods.id != goods.id)) {
          _components.add(_ComponentInput(goods));
        }
      }
      _invalidate();
    });
  }

  List<Map<String, dynamic>> _bodies() {
    return [for (final component in _components) _body(component)];
  }

  Map<String, dynamic> _body(_ComponentInput component) {
    final goods = component.goods;
    final entered = double.tryParse(component.quantity.text.trim());
    if (entered == null || !entered.isFinite || entered <= 0) {
      throw ApiException(
        'VALIDATION_FAILED',
        _l10n.goodsBomBatchInvalidQuantity(
          goods.name ?? goods.code ?? '—',
          goods.isPeriodicIssue
              ? bomPeriodicQuantityLabel(context, goods.unitName)
              : _l10n.bomDesignQty,
        ),
      );
    }
    if (goods.isPeriodicIssue &&
        goods.periodicCostBasis != null &&
        goods.periodicCostBasis != GoodsPeriodicCostBasis.own) {
      throw ApiException(
        'VALIDATION_FAILED',
        _l10n.goodsBomBatchSharedPeriodicNotAllowed(
          goods.name ?? goods.code ?? '—',
        ),
      );
    }
    final copied = component.copied;
    final body = copied == null
        ? <String, dynamic>{'price': goods.price}
        : bomComponentCopyBody(copied);
    if (goods.isPeriodicIssue) {
      body.addAll(periodicBomQuantityBody(goods.id, entered, goods.unitName));
    } else {
      body.addAll({'componentGoodsId': goods.id, 'qty': entered});
    }
    if (copied != null && body['qty'] != copied.qty) body.remove('total');
    return body;
  }

  Future<void> _submit() async {
    if (!_current || _busy) return;
    if (_components.isEmpty) {
      setState(() => _error = _l10n.goodsBomBatchSelectFirst);
      return;
    }
    final limit = _remove ? 500 : 200;
    if (_components.length > limit) {
      setState(() => _error = _l10n.goodsBomBatchComponentLimit(limit));
      return;
    }
    final reviewed = _preview;
    setState(() {
      _busy = true;
      _error = null;
      _problems = const [];
    });
    try {
      final scope = await _requestScope;
      if (reviewed != null) {
        final result = await scope.run(
          () => _repository.commit(
            reviewed.previewToken,
            confirmSharedChanges: true,
          ),
        );
        if (!mounted || !_current) return;
        Navigator.of(context).pop(result);
        return;
      }
      final bodies = _remove ? <Map<String, dynamic>>[] : _bodies();
      while (_current) {
        try {
          final preview = await scope.run(
            () => _repository.preview(
              action: widget.action,
              targetGoodsIds: widget.targetGoodsIds,
              items: bodies,
              componentGoodsIds: _remove
                  ? [for (final component in _components) component.goods.id]
                  : const [],
            ),
          );
          if (!_current) return;
          setState(() {
            _preview = preview;
            _recoveringCommit = false;
          });
          break;
        } on ApiException catch (error) {
          final confirmations = periodicConfirmationsOf(error);
          if (confirmations == null || !mounted || !_current) rethrow;
          setState(() => _busy = false);
          final confirmed = await askPeriodicConfirmations(
            context,
            confirmations,
            onRouteOpened: (route) {
              _confirmationRoute = route;
              if (route != null && !_current) _closeRoutes();
            },
            isCurrent: () => _current,
          );
          _confirmationRoute = null;
          if (!_current || confirmed == null) return;
          applyPeriodicConfirmations(bodies, confirmed);
          setState(() => _busy = true);
        }
      }
    } catch (error) {
      if (!_current) return;
      setState(() {
        _recoveringCommit =
            reviewed != null && isBomBatchCommitUncertain(error);
        if (!_recoveringCommit) _preview = null;
        _error = _recoveringCommit
            ? _l10n.goodsBomBatchCommitUncertain
            : error is ApiException
            ? error.message
            : _l10n.goodsBomBatchFailed;
        _problems = error is ApiException && !_recoveringCommit
            ? error.fieldErrors ?? const []
            : const [];
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _title => _overwrite
      ? _l10n.goodsBomBatchOverwriteTitle
      : _remove
      ? _l10n.goodsBomBatchRemoveTitle
      : _l10n.goodsBomBatchAddTitle;

  String _summary(BomBatchResult result) => _l10n.goodsBomBatchSummary(
    result.changedTargetCount,
    result.added,
    result.updated,
    result.removed,
    result.skipped,
  );

  @override
  Widget build(BuildContext context) {
    _ownRoute ??= ModalRoute.of(context);
    ref.watch(sensitiveReadBoundaryProvider);
    if (!_current) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final preview = _preview;
    final enabled = !_busy && !_recoveringCommit;
    final copied =
        ref.watch(goodsClipboardProvider).bomItems ?? const <GoodsBomItem>[];
    return PopScope(
      canPop: !_busy,
      child: UtenAlertDialog(
        key: const Key('goods-bom-batch-dialog'),
        maxWidth: 760,
        title: Text(_title),
        content: SizedBox(
          width: 700,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_l10n.goodsBomBatchTargets(widget.targetGoodsIds.length)),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                _overwrite
                    ? _l10n.goodsBomBatchOverwriteDescription
                    : _remove
                    ? _l10n.goodsBomBatchRemoveDescription
                    : _l10n.goodsBomBatchAddDescription,
              ),
              const SizedBox(height: UtenSpacing.s12),
              if (!_overwrite)
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    UtenButton(
                      key: const Key('goods-bom-batch-pick'),
                      onPressed: enabled ? _pick : null,
                      child: Text(_l10n.goodsBomBatchChooseComponents),
                    ),
                    if (copied.isNotEmpty)
                      UtenButton(
                        key: const Key('goods-bom-batch-use-copied'),
                        type: UtenButtonType.tonal,
                        onPressed: enabled
                            ? () => setState(() {
                                _addCopies(copied);
                                _invalidate();
                              })
                            : null,
                        child: Text(_l10n.goodsBomBatchUseCopied),
                      ),
                  ],
                ),
              const SizedBox(height: UtenSpacing.s12),
              if (_components.isEmpty)
                Text(_l10n.goodsBomBatchSelectFirst)
              else ...[
                for (final component
                    in (_expanded || _components.length <= 4
                        ? _components
                        : _components.take(1)))
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s4,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                                  component.goods.code,
                                  component.goods.name,
                                  component.goods.colorName,
                                ]
                                .whereType<String>()
                                .where((value) => value.isNotEmpty)
                                .join(' / '),
                          ),
                        ),
                        if (!_remove) ...[
                          const SizedBox(width: UtenSpacing.s8),
                          SizedBox(
                            width: 128,
                            child: BomComponentQuantityField(
                              goods: component.goods,
                              controller: component.quantity,
                              enabled: enabled,
                              fieldKey: ValueKey(
                                'goods-bom-batch-qty-${component.goods.id}',
                              ),
                              onChanged: (_) => setState(_invalidate),
                            ),
                          ),
                        ],
                        IconButton(
                          key: ValueKey(
                            'goods-bom-batch-remove-${component.goods.id}',
                          ),
                          tooltip: _l10n.goodsBomBatchUnselectComponent,
                          onPressed: enabled && !_overwrite
                              ? () => setState(() {
                                  _components.remove(component);
                                  component.quantity.dispose();
                                  _invalidate();
                                })
                              : null,
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                      ],
                    ),
                  ),
                if (_components.length > 4)
                  TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(
                      _expanded
                          ? _l10n.goodsBomBatchCollapseComponents
                          : _l10n.goodsBomBatchExpandComponents(
                              _components.length,
                            ),
                    ),
                  ),
              ],
              if (preview != null) ...[
                const Divider(height: UtenSpacing.s24),
                Text(_summary(preview), style: theme.textTheme.titleSmall),
                const SizedBox(height: UtenSpacing.s8),
                _readList([
                  for (final target in preview.targets)
                    '${target.goodsName ?? '—'} / ${target.goodsCode ?? '—'}: '
                        '${_l10n.goodsBomBatchTargetCounts(target.added, target.updated, target.removed, target.skipped)}',
                ]),
                if (preview.otherUsageCount > 0) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  Text(
                    _l10n.goodsBomBatchSharedImpact(preview.otherUsageCount),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  _readList([
                    for (final product in preview.affectedProducts.where(
                      (product) => !product.selected,
                    ))
                      '${product.goodsName ?? '—'} / ${product.goodsCode ?? '—'}',
                  ]),
                ],
                if (preview.hiddenUsageCount > 0)
                  Text(
                    _l10n.goodsBomBatchHiddenImpact(preview.hiddenUsageCount),
                  ),
                if (preview.warnings.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  for (final warning in preview.warnings)
                    Text(
                      warning,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
                const SizedBox(height: UtenSpacing.s8),
                Text(_l10n.goodsBomBatchConfirmImpact),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  _error!,
                  key: const Key('goods-bom-batch-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                for (final problem in _problems.take(10))
                  Text(
                    problem.field.isEmpty
                        ? problem.message
                        : '${problem.field}: ${problem.message}',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (_problems.length > 10)
                  Text(_l10n.goodsBomBatchMoreProblems(_problems.length - 10)),
              ],
            ],
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(
              _recoveringCommit
                  ? _l10n.goodsBomBatchCloseVerify
                  : _l10n.commonCancel,
            ),
          ),
          UtenButton(
            key: const Key('goods-bom-batch-submit'),
            type: _remove || _overwrite
                ? UtenButtonType.danger
                : UtenButtonType.primary,
            isLoading: _busy,
            onPressed: _components.isEmpty ? null : _submit,
            child: Text(
              _recoveringCommit
                  ? _l10n.goodsBomBatchRetryCommit
                  : preview == null
                  ? _l10n.goodsBomBatchPreview
                  : _l10n.goodsBomBatchConfirmCommit,
            ),
          ),
        ],
      ),
    );
  }

  Widget _readList(List<String> lines) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 180),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
              child: Text(line),
            ),
        ],
      ),
    ),
  );
}
