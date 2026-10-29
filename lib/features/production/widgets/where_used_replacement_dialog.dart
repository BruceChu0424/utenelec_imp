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
import '../../basic_data/models/goods_node.dart';
import 'where_used_material_picker.dart';

Future<bool?> showWhereUsedReplacementDialog({
  required BuildContext context,
  required GoodsListItem material,
  required Set<String> productIds,
}) => showDialog<bool>(
  context: context,
  builder: (_) => _ReplacementDialog(
    material: material,
    productIds: Set.unmodifiable(productIds),
  ),
);

class _ReplacementDialog extends ConsumerStatefulWidget {
  const _ReplacementDialog({required this.material, required this.productIds});
  final GoodsListItem material;
  final Set<String> productIds;
  @override
  ConsumerState<_ReplacementDialog> createState() => _ReplacementDialogState();
}

class _ReplacementDialogState extends ConsumerState<_ReplacementDialog> {
  late final SensitiveReadBoundary _boundary;
  late final Future<AuthenticatedRequestScope> _requestScope;
  GoodsListItem? _replacement;
  Map<String, dynamic>? _preview;
  bool _busy = false;
  bool _recoveringCommit = false;
  String? _error;
  final Map<String, String> _confirmations = {};
  final Set<String> _confirmed = {};
  bool get _current =>
      mounted &&
      _boundary.identity?.readOnly != true &&
      _boundary == ref.read(sensitiveReadBoundaryProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.goodsBomEdit) &&
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionWhereUsedView);

  @override
  void initState() {
    super.initState();
    _boundary = ref.read(sensitiveReadBoundaryProvider);
    _requestScope = _boundary.api.captureRequestScope(
      isCurrent: () => _current,
    );
    // Keep the captured identity even if secure storage fails before the first click.
    unawaited(
      _requestScope.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
      if (next == _boundary || !mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      if (route.isCurrent) {
        Navigator.of(context).pop(false);
      } else {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  String _label(GoodsListItem item) =>
      '${item.name ?? '—'}${(item.code ?? '').isEmpty ? '' : ' / ${item.code}'}'
      '${(item.colorName ?? '').isEmpty ? '' : ' / ${item.colorName}'}';

  Future<void> _pick() async {
    if (!_current || _busy || _recoveringCommit) return;
    final item = await showWhereUsedReplacementPicker(
      context,
      ref,
      readBoundary: _boundary,
    );
    if (!_current || item == null) return;
    setState(() {
      _replacement = item;
      _preview = null;
      _error = null;
      _confirmations.clear();
      _confirmed.clear();
    });
  }

  Future<void> _submit() async {
    final replacement = _replacement;
    if (!_current || _busy || replacement == null) return;
    if (replacement.id == widget.material.id) {
      setState(
        () => _error = AppLocalizations.of(
          context,
        ).whereUsedReplacementSameComponent,
      );
      return;
    }
    final preview = _preview;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await _requestScope;
      final result = await scope.run(
        () => _boundary.api.post(
          '/production/reports/where-used/replacement/${preview == null ? 'preview' : 'commit'}',
          body: preview == null
              ? {
                  'materialGoodsId': widget.material.id,
                  'replacementGoodsId': replacement.id,
                  'productIds': widget.productIds.toList(),
                  for (final field in _confirmed) field: true,
                }
              : {'previewToken': preview['previewToken']},
        ),
      );
      if (!mounted || !_current) return;
      if (preview == null) {
        setState(() => _preview = result);
      } else {
        Navigator.of(context).pop(true);
      }
    } on ApiException catch (error) {
      if (!_current) return;
      setState(() {
        _recoveringCommit = preview != null && _uncertain(error);
        _error = _recoveringCommit
            ? AppLocalizations.of(context).whereUsedReplacementCommitUncertain
            : error.message;
        if (!_recoveringCommit) _preview = null;
        for (final field in error.fieldErrors ?? const <ApiFieldError>[]) {
          if (const {
            'confirmUnusualWeight',
            'confirmSecondPeriodicMaterial',
          }.contains(field.field)) {
            _confirmations[field.field] = field.message;
          }
        }
      });
    } catch (_) {
      if (_current) {
        setState(() {
          _recoveringCommit = preview != null;
          _error = _recoveringCommit
              ? AppLocalizations.of(context).whereUsedReplacementCommitUncertain
              : AppLocalizations.of(context).whereUsedReplacementFailed;
          if (!_recoveringCommit) _preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static bool _uncertain(ApiException error) {
    if (const {
      'SESSION_CHANGED',
      'SESSION_STATE_UNAVAILABLE',
      'UNAUTHORIZED',
      'FORBIDDEN',
      'NOT_FOUND',
    }.contains(error.code)) {
      return false;
    }
    return (error.httpStatus ?? 0) >= 500 ||
        error.httpStatus == null && !error.hasResponseCode ||
        const {'NETWORK', 'NETWORK_TIMEOUT', 'TIMEOUT'}.contains(error.code);
  }

  Widget _field(String label, Widget value) {
    final title = Text(label, style: Theme.of(context).textTheme.labelLarge);
    if (MediaQuery.sizeOf(context).width < 600) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          const SizedBox(height: UtenSpacing.s4),
          value,
        ],
      );
    }
    return Row(
      children: [
        SizedBox(
          width: MediaQuery.textScalerOf(context).scale(76),
          child: title,
        ),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(child: value),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final products = (preview?['affectedProducts'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final edgeCount = (preview?['edges'] as List?)?.length ?? 0;
    final additional = products
        .where((product) => product['selected'] != true)
        .length;
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_busy,
      child: UtenAlertDialog(
        showCloseButton: _recoveringCommit,
        closeEnabled: !_busy,
        closeTooltip: l10n.whereUsedCloseAndVerify,
        onClose: () => Navigator.of(context).pop(),
        key: const Key('where-used-replacement-dialog'),
        title: Text(
          preview == null
              ? l10n.whereUsedReplacementTitle
              : l10n.whereUsedReplacementConfirmTitle,
        ),
        maxWidth: 680,
        content: SizedBox(
          width: 620,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(
                l10n.whereUsedCurrentComponent,
                SelectableText(_label(widget.material)),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _field(
                l10n.whereUsedReplaceWith,
                UtenButton(
                  key: const Key('where-used-replacement-picker'),
                  type: UtenButtonType.tonal,
                  onPressed: _busy || _recoveringCommit ? null : _pick,
                  child: Text(
                    _replacement == null
                        ? l10n.whereUsedChooseComponent
                        : _label(_replacement!),
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              Text(l10n.whereUsedReplacementRules(widget.productIds.length)),
              const SizedBox(height: UtenSpacing.s8),
              Text(l10n.whereUsedReplacementHistory),
              if (preview != null) ...[
                const SizedBox(height: UtenSpacing.s16),
                Text(
                  l10n.whereUsedReplacementImpact(edgeCount, products.length) +
                      (additional > 0
                          ? l10n.whereUsedReplacementSharedImpact(additional)
                          : ''),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: additional > 0 ? theme.colorScheme.error : null,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final product in products)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: UtenSpacing.s4,
                            ),
                            child: Text(
                              '${product['name'] ?? '—'} / ${product['code'] ?? '—'}'
                              '${product['selected'] == true ? l10n.whereUsedReplacementSelectedSuffix : l10n.whereUsedReplacementSharedSuffix}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              for (final confirmation in _confirmations.entries)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _confirmed.contains(confirmation.key),
                  title: Text(confirmation.value),
                  onChanged: _busy || _recoveringCommit
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _confirmed.add(confirmation.key);
                          } else {
                            _confirmed.remove(confirmation.key);
                          }
                        }),
                ),
            ],
          ),
        ),
        actions: [
          if (!_recoveringCommit)
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
          UtenButton(
            key: const Key('where-used-replacement-confirm'),
            isLoading: _busy,
            onPressed: _replacement == null || !_current ? null : _submit,
            child: Text(
              _recoveringCommit
                  ? l10n.whereUsedRetryReplacementCommit
                  : preview == null
                  ? l10n.whereUsedPreviewImpact
                  : l10n.whereUsedConfirmReplaceSync,
            ),
          ),
        ],
      ),
    );
  }
}
