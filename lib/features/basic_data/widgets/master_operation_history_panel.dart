import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_close_button.dart';
import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../models/goods_operation_history.dart';
import '../repositories/master_operation_history_repository.dart';
import 'master_inline_edit.dart';
import 'basic_data_l10n.dart';
import 'master_record_history_panel.dart';

/// Entry visibility is only a convenience. The server authorizes each change.
bool canOpenMasterOperationHistory(String entityType, Set<String> permissions) {
  if (entityType == 'clients' &&
      permissions.contains(Perm.clientView) &&
      (permissions.contains(Perm.clientAddressCreate) ||
          permissions.contains(Perm.clientAddressDelete))) {
    return true;
  }
  final prefix = const {
    'clients': 'client',
    'suppliers': 'supplier',
    'moulds': 'mould',
    'colors': 'color',
    'units': 'unit',
    'currencies': 'currency',
    'warehouses': 'warehouse',
    'accounts': 'account',
    'reference-methods': 'settlement_method',
    'payment-styles': 'payment_style',
  }[entityType];
  return prefix != null &&
      permissions.any(
        (permission) =>
            permission.startsWith('$prefix:') &&
            !permission.endsWith(':view') &&
            !permission.endsWith(':export'),
      );
}

Future<void> showMasterOperationHistory(
  BuildContext context, {
  required String entityType,
  bool preferRedo = false,
  required VoidCallback onChanged,
}) => showUtenAdaptivePanel<void>(
  context: context,
  drawerWidth: 640,
  enableDrag: false,
  builder: (_) => MasterOperationHistoryPanel(
    entityType: entityType,
    preferRedo: preferRedo,
    onChanged: onChanged,
  ),
);

String goodsOperationLabel(AppLocalizations l10n, GoodsOperationEntry entry) =>
    entry.label.isNotEmpty ? entry.label : l10n.goodsHistoryOther;

String _operationTypeLabel(
  AppLocalizations l10n,
  String type,
  String fallback,
) => switch (type) {
  'GOODS_CREATE' => l10n.goodsHistoryGoodsCreate,
  'GOODS_EDIT' => l10n.goodsHistoryGoodsEdit,
  'GOODS_NAME_EN' => l10n.goodsHistoryGoodsNameEn,
  'GOODS_STATUS' => l10n.goodsHistoryGoodsStatus,
  'GOODS_DELETE' => l10n.goodsHistoryGoodsDelete,
  'GOODS_IMPORT' => l10n.goodsHistoryGoodsImport,
  'GOODS_PURCHASE_POLICY' => l10n.goodsHistoryGoodsPurchasePolicy,
  'GOODS_SUBCONTRACT_POLICY' => l10n.goodsHistoryGoodsSubcontractPolicy,
  'BOM_CREATE' => l10n.goodsHistoryBomCreate,
  'BOM_EDIT' => l10n.goodsHistoryBomEdit,
  'BOM_DELETE' => l10n.goodsHistoryBomDelete,
  'BOM_PASTE' => l10n.goodsHistoryBomPaste,
  'BOM_AUDIT' => l10n.goodsHistoryBomAudit,
  'CATEGORY_CREATE' => l10n.goodsHistoryCategoryCreate,
  'CATEGORY_EDIT' => l10n.goodsHistoryCategoryEdit,
  'CATEGORY_DELETE' => l10n.goodsHistoryCategoryDelete,
  _ => fallback.isNotEmpty ? fallback : l10n.goodsHistoryOther,
};

class MasterOperationHistoryPanel extends ConsumerStatefulWidget {
  const MasterOperationHistoryPanel({
    super.key,
    required this.entityType,
    this.preferRedo = false,
    required this.onChanged,
  });

  final String entityType;
  final bool preferRedo;
  final VoidCallback onChanged;

  @override
  ConsumerState<MasterOperationHistoryPanel> createState() =>
      _MasterOperationHistoryPanelState();
}

class _MasterOperationHistoryPanelState
    extends ConsumerState<MasterOperationHistoryPanel>
    with NativeReadViewScopeMixin<MasterOperationHistoryPanel> {
  GoodsOperationHistory? _history;
  String? _selectedId;
  String? _error;
  String? _message;
  bool _loading = false;
  bool _confirming = false;
  bool _mutating = false;
  bool _needsRefresh = false;
  bool _capabilityReloadScheduled = false;
  int _requestEpoch = 0;

  bool get _busy => _confirming || _mutating;
  bool get _canOpen => canOpenMasterOperationHistory(
    widget.entityType,
    ref.read(currentPermissionsProvider),
  );

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) _capabilitiesChanged();
    });
    ref.listenManual(isSuperAdminProvider, (previous, next) {
      if (previous != next) _capabilitiesChanged();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void nativeReadOwnerChanged() => _clear();
  @override
  void nativeReadPermissionChanged() => _clear();
  @override
  Future<void> nativeReadReload() => _load();

  /// A remaining write permission does not authorize an already rendered
  /// operation. Fence its DTO, confirmation and pending response immediately,
  /// then ask the server for the current per-operation capabilities again.
  void _capabilitiesChanged() {
    invalidateNativeReadAccess();
    _clear();
    if (_capabilityReloadScheduled) return;
    _capabilityReloadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _capabilityReloadScheduled = false;
      if (mounted && _canOpen) _load();
    });
  }

  void _clear() {
    _requestEpoch++;
    if (!mounted) return;
    setState(() {
      _history = null;
      _selectedId = null;
      _error = null;
      _message = null;
      _loading = false;
      _confirming = false;
      _mutating = false;
      _needsRefresh = false;
    });
  }

  String? _initialSelection(GoodsOperationHistory result) {
    final preferred = result.entries.where(
      (entry) => widget.preferRedo ? entry.canRedo : entry.canUndo,
    );
    return preferred.firstOrNull?.id ??
        (widget.preferRedo ? null : result.entries.firstOrNull?.id);
  }

  Future<void> _load() async {
    if (!mounted || !_canOpen || _busy) return;
    final acceptsRead = captureNativeRead(
      'master-history-${widget.entityType}',
      () => 'master-history-${widget.entityType}',
    );
    if (!acceptsRead()) return;
    final request = ++_requestEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(masterOperationHistoryRepositoryProvider(widget.entityType))
          .list();
      if (!acceptsRead() || request != _requestEpoch || !_canOpen) return;
      acceptNativeRead();
      setState(() {
        _history = result;
        if (!result.entries.any((entry) => entry.id == _selectedId)) {
          _selectedId = _initialSelection(result);
        }
        _loading = false;
        _needsRefresh = false;
      });
    } catch (error) {
      if (!acceptsRead() || request != _requestEpoch || !_canOpen) return;
      setState(() {
        _loading = false;
        _error = error is ApiException
            ? error.message
            : basicDataL10n(context).goodsHistoryLoadFailed;
      });
    }
  }

  Future<void> _apply(GoodsOperationEntry entry) async {
    if (_busy ||
        _loading ||
        _needsRefresh ||
        !nativeReadCanWrite ||
        !_canOpen) {
      return;
    }
    final redo = entry.isUndone;
    if (redo ? !entry.canRedo : !entry.canUndo) return;
    final owns = captureNativeOwnership();
    final l10n = basicDataL10n(context);
    final label = goodsOperationLabel(l10n, entry);
    var decisionMade = false;
    void decide(BuildContext dialogContext, bool confirmed) {
      // The dialog is still painted during its closing animation. A second
      // click must not pop the operation panel beneath it or confirm twice.
      if (decisionMade) return;
      decisionMade = true;
      Navigator.pop(
        dialogContext,
        confirmed && owns() && nativeReadCanWrite && _canOpen,
      );
    }

    setState(() => _confirming = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => trackNativeReadDialog(
        dialogContext,
        UtenAlertDialog(
          title: Text(redo ? l10n.goodsHistoryRedo : l10n.goodsHistoryUndo),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.summary.isNotEmpty) ...[
                Text(entry.summary),
                const SizedBox(height: UtenSpacing.s8),
              ],
              Text(ChinaDateTime.formatIsoInstant(entry.createdAt)),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                redo
                    ? l10n.goodsHistoryRedoConfirm(label, entry.affectedCount)
                    : l10n.goodsHistoryUndoConfirm(label, entry.affectedCount),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => decide(dialogContext, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => decide(dialogContext, true),
              child: Text(redo ? l10n.goodsHistoryRedo : l10n.goodsHistoryUndo),
            ),
          ],
        ),
      ),
    );
    if (!owns()) return;
    setState(() => _confirming = false);
    if (confirmed != true || !nativeReadCanWrite || !_canOpen) return;
    ++_requestEpoch;
    setState(() {
      _mutating = true;
      _error = null;
      _message = null;
    });
    try {
      final repository = ref.read(
        masterOperationHistoryRepositoryProvider(widget.entityType),
      );
      final result = redo
          ? await repository.redo(entry.id, expectedVersion: entry.version)
          : await repository.undo(entry.id, expectedVersion: entry.version);
      if (!owns() || !_canOpen) return;
      setState(() {
        _history = result;
        _mutating = false;
        _selectedId = result.entries.any((item) => item.id == entry.id)
            ? entry.id
            : _initialSelection(result);
        _message = redo ? l10n.goodsHistoryRedoDone : l10n.goodsHistoryUndoDone;
      });
      widget.onChanged();
    } catch (error) {
      if (!owns() || !_canOpen) return;
      setState(() {
        _mutating = false;
        _needsRefresh = true;
        _error = [
          error is ApiException ? error.message : l10n.goodsHistoryActionFailed,
          l10n.goodsHistoryRefreshBeforeRetry,
        ].join('\n');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = basicDataL10n(context);
    final canOpen = canOpenMasterOperationHistory(
      widget.entityType,
      ref.watch(currentPermissionsProvider),
    );
    final entries = _history?.entries ?? const <GoodsOperationEntry>[];
    final selected = entries
        .where((entry) => entry.id == _selectedId)
        .firstOrNull;
    final enabled =
        selected != null &&
        (selected.isUndone ? selected.canRedo : selected.canUndo) &&
        nativeReadCanWrite &&
        !_busy &&
        !_loading &&
        !_needsRefresh;

    return PopScope(
      canPop: !_mutating,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        masterEditText(
                          context,
                          '操作记录与撤回',
                          'Operation history',
                          '작업 기록',
                        ),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    UtenFieldHintIcon(info: l10n.goodsHistoryHint, dense: true),
                    UtenCloseButton(
                      tooltip: l10n.goodsHistoryClose,
                      onPressed: _busy ? null : () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s8,
                  children: [
                    TextButton(
                      key: const ValueKey('master-history-refresh'),
                      onPressed: _busy || _loading || !canOpen ? null : _load,
                      child: Text(l10n.commonRefresh),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_loading || _mutating) const LinearProgressIndicator(),
          Expanded(
            child: !canOpen
                ? Center(
                    child: Text(
                      masterEditText(
                        context,
                        '当前没有可查看的操作权限。',
                        'You do not have access to this operation history.',
                        '이 작업 기록을 볼 권한이 없습니다.',
                      ),
                    ),
                  )
                : _history == null &&
                      !nativeReadAccessConfirmed &&
                      !_loading &&
                      _error == null
                ? nativeReadAccessNotice()
                : ListView(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    children: [
                      if (_error != null) ...[
                        UtenInlineNotice(
                          level: UtenInlineNoticeLevel.error,
                          message: _error,
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      if (_message != null) ...[
                        UtenInlineNotice(message: _message),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      if (entries.isEmpty && !_loading && _error == null)
                        Text(l10n.goodsHistoryEmpty),
                      for (final entry in entries)
                        _entry(context, entry, selected?.id == entry.id),
                      if (_history?.events.isNotEmpty == true) ...[
                        const SizedBox(height: UtenSpacing.s24),
                        Text(
                          l10n.goodsHistoryEvents,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                        for (final event in _history!.events)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: UtenSpacing.s8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.goodsHistoryEvent(
                                    event.action == 'REDO'
                                        ? l10n.goodsHistoryRedo
                                        : l10n.goodsHistoryUndo,
                                    _eventLabel(l10n, event, entries),
                                  ),
                                ),
                                if (event.summary.isNotEmpty)
                                  Text(event.summary),
                                Text(
                                  ChinaDateTime.formatIsoInstant(
                                    event.createdAt,
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenButton(
                  key: const ValueKey('master-history-apply'),
                  isExpanded: true,
                  isLoading: _mutating,
                  onPressed: enabled ? () => _apply(selected) : null,
                  child: Text(
                    selected?.isUndone == true ||
                            (selected == null && widget.preferRedo)
                        ? l10n.goodsHistoryRedo
                        : l10n.goodsHistoryUndoSelected,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _entry(
    BuildContext context,
    GoodsOperationEntry entry,
    bool selected,
  ) {
    final l10n = basicDataL10n(context);
    final colors = Theme.of(context).colorScheme;
    final label = goodsOperationLabel(l10n, entry);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? colors.secondaryContainer : colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: UtenRadius.controlAll,
            side: BorderSide(
              color: selected ? colors.primary : colors.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('master-history-entry-${entry.id}'),
            onTap: _busy || _loading
                ? null
                : () => setState(() => _selectedId = entry.id),
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleMedium),
                  if (entry.summary.isNotEmpty) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(entry.summary),
                  ],
                  const SizedBox(height: UtenSpacing.s4),
                  Wrap(
                    spacing: UtenSpacing.s12,
                    runSpacing: UtenSpacing.s4,
                    children: [
                      Text(l10n.goodsHistoryAffected(entry.affectedCount)),
                      Text(
                        entry.isUndone
                            ? l10n.goodsHistoryUndone
                            : l10n.goodsHistoryApplied,
                      ),
                      if (selected) Text(l10n.goodsHistorySelected),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    ChinaDateTime.formatIsoInstant(entry.createdAt),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (selected && !entry.canUndo && !entry.canRedo) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      entry.blockedReason?.isNotEmpty == true
                          ? entry.blockedReason!
                          : l10n.goodsHistoryBlocked,
                      style: TextStyle(color: colors.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _eventLabel(
    AppLocalizations l10n,
    GoodsOperationEvent event,
    List<GoodsOperationEntry> entries,
  ) {
    final entry = entries
        .where((entry) => entry.id == event.operationId)
        .firstOrNull;
    return entry == null
        ? _operationTypeLabel(l10n, event.operationType, event.label)
        : goodsOperationLabel(l10n, entry);
  }
}

class MasterOperationHistoryActions extends ConsumerWidget {
  const MasterOperationHistoryActions({
    super.key,
    required this.entityType,
    required this.onChanged,
    this.enabled = true,
    this.recordId,
    this.categoryId,
  });
  final String entityType;
  final VoidCallback onChanged;
  final bool enabled;
  final String? recordId;
  final String? categoryId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = basicDataL10n(context);
    final canUndo = canOpenMasterOperationHistory(
      entityType,
      ref.watch(currentPermissionsProvider),
    );
    Future<void> open(bool redo) async {
      if (!await confirmMasterInlineLeave(context) || !context.mounted) return;
      await showMasterOperationHistory(
        context,
        entityType: entityType,
        preferRedo: redo,
        onChanged: onChanged,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: UtenSpacing.s4,
      children: [
        MasterRecordHistoryAction(
          entityType: entityType,
          recordId: recordId,
          categoryId: categoryId,
          onChanged: onChanged,
          enabled: enabled,
        ),
        if (canUndo)
          UtenAppBarActionButton(
            label: l10n.goodsHistoryUndo,
            onPressed: enabled ? () => open(false) : null,
          ),
        if (canUndo)
          UtenAppBarActionButton(
            label: l10n.goodsHistoryRedo,
            onPressed: enabled ? () => open(true) : null,
          ),
      ],
    );
  }
}
