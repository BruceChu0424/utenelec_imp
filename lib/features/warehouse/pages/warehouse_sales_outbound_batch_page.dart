import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_sales_outbound.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';
import '../widgets/warehouse_sales_outbound_table_columns.dart';
import '../widgets/warehouse_sales_picking_fields.dart';

/// Review multiple documents, then explicitly perform one warehouse stage.
/// Each command retains its own existing server transaction and result.
class WarehouseSalesOutboundBatchPage extends ConsumerStatefulWidget {
  const WarehouseSalesOutboundBatchPage({
    super.key,
    required this.targets,
    required this.action,
  });

  final List<WarehouseSalesOutboundSummary> targets;
  final WarehouseSalesOutboundAction action;

  @override
  ConsumerState<WarehouseSalesOutboundBatchPage> createState() =>
      _WarehouseSalesOutboundBatchPageState();
}

class _WarehouseSalesOutboundBatchPageState
    extends ConsumerState<WarehouseSalesOutboundBatchPage> {
  /// 选填统一出库备注，随每张单的出库事件留证。
  final _reason = TextEditingController();
  List<WarehouseSalesOutboundDetail>? _details;
  final Set<String> _completed = {};
  String? _failedId;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _attempted = false;
  int _loadVersion = 0;
  final Map<String, WarehouseSalesPickingDraft> _picking = {};

  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final draft in _picking.values) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted || _saving || _attempted) return;
    final version = ++_loadVersion;
    final l10n = _l10n;
    setState(() {
      _loading = true;
      _error = null;
      _details = null;
    });
    try {
      final targets = {for (final item in widget.targets) item.id: item};
      if (targets.isEmpty) {
        throw FormatException(l10n.warehouseOutboundBatchEmpty);
      }
      final repository = ref.read(warehouseSalesOutboundRepositoryProvider);
      final details = await Future.wait(targets.keys.map(repository.detail));
      if (!mounted || version != _loadVersion) return;
      if (details.any(
        (detail) =>
            detail.lines.isEmpty ||
            detail.header.warehouseWorkStatus !=
                targets[detail.header.id]?.warehouseWorkStatus ||
            warehouseSalesOutboundPrimaryAction(detail.header) != widget.action,
      )) {
        throw FormatException(l10n.warehouseOutboundBatchStale);
      }
      setState(() {
        for (final draft in _picking.values) {
          draft.dispose();
        }
        _picking.clear();
        for (final detail in details) {
          _picking[detail.header.id] = WarehouseSalesPickingDraft(detail);
        }
        _details = details;
      });
    } on ApiException catch (error) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = error.message);
      }
    } on FormatException catch (error) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = l10n.commonError);
      }
    } finally {
      if (mounted && version == _loadVersion) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final details = _details;
    if (_saving ||
        _confirming ||
        _loading ||
        _attempted ||
        details == null ||
        details.isEmpty) {
      return;
    }
    final l10n = _l10n;
    final valid = _picking.values
        .map((draft) => draft.validate())
        .toList()
        .every((value) => value);
    if (!valid) {
      setState(() {});
      final firstError = _picking.values
          .map((draft) => draft.error)
          .firstWhere((message) => message != null, orElse: () => null);
      context.appWarning(firstError ?? '请逐行核对实际发出仓');
      return;
    }
    // Busy before the dialog also prevents two confirmations from rapid taps.
    setState(() => _confirming = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          l10n.warehouseOutboundBatchAction(
            warehouseSalesOutboundActionLabel(l10n, widget.action),
          ),
        ),
        content: Text(
          l10n.warehouseOutboundBatchConfirm(
            warehouseSalesOutboundActionLabel(l10n, widget.action),
            details.length,
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          UtenButton(
            key: const Key('warehouse-sales-outbound-batch-confirm'),
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      setState(() => _confirming = false);
      return;
    }

    setState(() {
      _confirming = false;
      _saving = true;
      _attempted = true;
    });
    final repository = ref.read(warehouseSalesOutboundRepositoryProvider);
    try {
      for (var i = 0; i < details.length; i++) {
        final reviewed = details[i];
        try {
          final latest = await repository.detail(reviewed.header.id);
          if (warehouseSalesOutboundReviewSnapshot(latest) !=
                  warehouseSalesOutboundReviewSnapshot(reviewed) ||
              warehouseSalesOutboundPrimaryAction(latest.header) !=
                  widget.action) {
            throw FormatException(l10n.warehouseOutboundBatchStale);
          }
          final updated = await repository.transition(
            reviewed.header.id,
            targetStatus: widget.action.targetStatus,
            reason: _reason.text.trim(),
            stockPlaces: _picking[reviewed.header.id]?.stockPlaces,
            lineWarehouses: _picking[reviewed.header.id]?.lineWarehouses,
          );
          if (updated.header.id != reviewed.header.id ||
              updated.header.warehouseWorkStatus !=
                  widget.action.targetStatus) {
            throw FormatException(l10n.warehouseOutboundBatchUnknown);
          }
          _completed.add(reviewed.header.id);
          details[i] = updated;
          if (mounted) setState(() {});
        } catch (error) {
          _failedId = reviewed.header.id;
          _error = switch (error) {
            ApiException() => error.message,
            FormatException() => error.message,
            _ => l10n.warehouseOutboundBatchUnknown,
          };
          break;
        }
      }
    } finally {
      if (mounted) {
        invalidateWarehouseTaskCounts(ref);
        setState(() => _saving = false);
      }
    }
    if (!mounted) return;
    if (_failedId == null) {
      context.appSuccess(l10n.commonSuccess);
      Navigator.of(context).pop(true);
    } else {
      context.appError(_error!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final rows = [
      for (final detail in _details ?? const <WarehouseSalesOutboundDetail>[])
        for (final line in detail.lines)
          WarehouseSalesOutboundTableRow(detail, line),
    ];
    final actionLabel = warehouseSalesOutboundActionLabel(l10n, widget.action);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.warehouseOutboundBatchReview,
          leading: UtenBackButton(
            onPressed: _saving
                ? null
                : () => Navigator.of(context).pop(_attempted),
          ),
          actions: [
            if (!_attempted)
              UtenAppBarActionButton(
                label: l10n.commonRefresh,
                icon: Icons.refresh_rounded,
                isLoading: _loading,
                onPressed: _loading || _saving ? null : _load,
              ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: UtenFloatingActionGroup(
          children: [
            if (_failedId != null)
              UtenButton(
                type: UtenButtonType.secondary,
                size: UtenButtonSize.large,
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.commonBack),
              )
            else if (_details != null)
              UtenButton(
                key: const Key('warehouse-sales-outbound-batch-submit'),
                type: UtenButtonType.danger,
                size: UtenButtonSize.large,
                icon: Icons.fact_check_outlined,
                isLoading: _saving,
                onPressed: _loading || _saving || _confirming || _attempted
                    ? null
                    : _submit,
                child: Text(l10n.warehouseOutboundBatchAction(actionLabel)),
              ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              AbsorbPointer(
                absorbing: _saving,
                child: _loading
                    ? const UtenSkeletonList()
                    : _details == null
                    ? UtenEmpty.error(
                        message: _error ?? l10n.warehouseOutboundBatchEmpty,
                        actionLabel: l10n.commonRetry,
                        onAction: _load,
                      )
                    : UtenContentContainer.wide(
                        child: Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s12),
                          child: UtenCollapsingHeaderScrollView(
                            collapsingHeader: Column(
                              key: const Key(
                                'warehouse-sales-outbound-batch-header',
                              ),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  l10n.warehouseOutboundBatchSelection(
                                    _details!.length,
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s8),
                                UtenCollapsibleSection(
                                  title: l10n.warehouseOutboundBatchDocuments,
                                  // 列数既按容器宽度算，也不超过单据张数：只有一张单
                                  // 据时卡片横铺满屏，不再固定占三分之一屏。
                                  child: UtenFormGrid(
                                    maxColumns: _details!.isEmpty
                                        ? 1
                                        : _details!.length,
                                    children: [
                                      for (final detail in _details!)
                                        _documentCard(detail),
                                    ],
                                  ),
                                ),
                                if (_failedId != null) ...[
                                  const SizedBox(height: UtenSpacing.s8),
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      '${l10n.warehouseOutboundBatchStopped}\n$_error',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: UtenSpacing.s12),
                              ],
                            ),
                            // 明细区直接从处理说明开始：不再写「出库明细」标题，
                            // 页面标题与表头已说明这里是什么。
                            body: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  controller: _reason,
                                  readOnly: _attempted,
                                  maxLength: 500,
                                  decoration: UtenInputDecoration(
                                    InputDecoration(
                                      labelText:
                                          l10n.warehouseOutboundBatchReason,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                Expanded(
                                  child: MasterDataTableView<WarehouseSalesOutboundTableRow>(
                                    key: const Key(
                                      'warehouse-sales-outbound-batch-table',
                                    ),
                                    primary: true,
                                    columns: warehouseSalesOutboundTableColumns(
                                      l10n: l10n,
                                      rows: rows,
                                      // V631：发出仓按行在表格里选，批量核对不再逐单选仓。
                                      draftOf: (row) =>
                                          _picking[row.detail.header.id],
                                      onDraftChanged: () => setState(() {}),
                                      stockPlaceControllerOf: (row) =>
                                          _picking[row.detail.header.id]
                                              ?.places[row.line.id],
                                      editingEnabled:
                                          !_attempted &&
                                          !_saving &&
                                          !_confirming,
                                      includeShipment: true,
                                      resultOf: _attempted
                                          ? (row) =>
                                                _completed.contains(
                                                  row.detail.header.id,
                                                )
                                                ? l10n.warehouseOutboundBatchDone
                                                : _failedId ==
                                                      row.detail.header.id
                                                ? l10n.warehouseOutboundBatchFailed
                                                : l10n.warehouseOutboundBatchPending
                                          : null,
                                    ),
                                    items: rows,
                                    bottomContentPadding:
                                        UtenFloatingActionGroup.scrollClearance,
                                    rowKeyOf: (row) => row.key,
                                    facets: const {},
                                    nullCounts: const {},
                                    filters: const {},
                                    onFilterChanged: (_, _) {},
                                    emptyMessage: l10n.commonNoData,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
              if (_saving)
                Positioned.fill(
                  child: UtenBusyOverlay(
                    title: l10n.warehouseOutboundBatchAction(actionLabel),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _documentCard(WarehouseSalesOutboundDetail detail) {
    final l10n = _l10n;
    final theme = Theme.of(context);
    final facts = <(String, String?)>[
      (l10n.warehouseOutboundBatchBillDate, detail.header.billDate),
      (l10n.warehouseOutboundClient, detail.header.clientName),
      (l10n.warehouseOutboundStatus, detail.header.statusLabel),
      if (detail.warehouseWorkUpdatedAt != null)
        (
          l10n.warehouseOutboundBatchUpdatedAt,
          ChinaDateTime.formatIsoInstant(
            detail.warehouseWorkUpdatedAt,
            fallback: '—',
          ),
        ),
    ];
    return UtenCard(
      key: Key('warehouse-sales-outbound-document-${detail.header.id}'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.warehouseOutboundBillNo,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            detail.header.billNo ?? '—',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          for (final fact in facts)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${fact.$1}: ',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    TextSpan(text: fact.$2 ?? '—'),
                  ],
                ),
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }
}
