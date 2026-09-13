import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/stock_doc_repository.dart';
import '../widgets/warehouse_stock_outbound_detail_table.dart';

class WarehouseStockBatchOutboundPage extends ConsumerStatefulWidget {
  const WarehouseStockBatchOutboundPage({
    super.key,
    required this.docType,
    required this.documentIds,
  });
  final StockDocType docType;
  final List<String> documentIds;

  @override
  ConsumerState<WarehouseStockBatchOutboundPage> createState() =>
      _WarehouseStockBatchOutboundPageState();
}

class _WarehouseStockBatchOutboundPageState
    extends ConsumerState<WarehouseStockBatchOutboundPage> {
  List<StockDocDetail> _documents = [];
  final Set<String> _selectedIds = {};
  final Set<String> _doneIds = {};
  final Map<String, String> _results = {};
  final Map<String, String> _reviewTokens = {};
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _stopped = false;
  String? _error;
  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canApprove =>
      ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove);
  bool _eligible(StockDocDetail d) =>
      _canApprove &&
      d.docType == widget.docType.code &&
      d.status == 0 &&
      !d.closed &&
      d.items.isNotEmpty &&
      !_doneIds.contains(d.id) &&
      (d.productionLinked ||
          documentOwnerCanWrite(
            ref.read(
              documentScopeCapabilityProvider(DocumentDataScope.stockDocument),
            ),
            d.makerId,
          ));

  Future<void> _load() async {
    if (_saving || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _selectedIds.clear();
    });
    try {
      if (widget.docType != StockDocType.otherOut &&
          widget.docType != StockDocType.finishedOut) {
        throw StateError('Unsupported outbound type');
      }
      final ids = widget.documentIds.toSet();
      if (ids.isEmpty || ids.length > 50) {
        throw StateError('Invalid batch size');
      }
      final names = ref.read(masterNameServiceProvider);
      await names.ensureLoaded();
      ref.invalidate(
        documentScopeCapabilityProvider(DocumentDataScope.stockDocument),
      );
      try {
        await ref.read(
          documentScopeCapabilityProvider(
            DocumentDataScope.stockDocument,
          ).future,
        );
      } catch (_) {
        // A failed capability lookup leaves the physical details read-only.
      }
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      // Bounded GET concurrency; never replay a write on reconnect.
      final documents = <StockDocDetail>[];
      final reviewTokens = <String, String>{};
      final targets = ids.toList();
      for (var offset = 0; offset < targets.length; offset += 5) {
        final reviews = await Future.wait(
          targets.skip(offset).take(5).map(repo.review),
        );
        for (final review in reviews) {
          documents.add(review.document);
          reviewTokens[review.document.id] = review.reviewToken;
        }
      }
      await names.loadGoodsDetails(
        documents
            .expand((d) => d.items)
            .map((i) => i.goodsId)
            .whereType<String>()
            .toSet(),
      );
      await names.loadEmployeeNames(documents.map((d) => d.workerId));
      if (!mounted) return;
      setState(() {
        _documents = documents;
        _reviewTokens
          ..clear()
          ..addAll(reviewTokens);
        _results.clear();
        _stopped = false;
        _selectedIds.addAll(documents.where(_eligible).map((d) => d.id));
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is ApiException
              ? e.message
              : _l10n.warehouseStockOutboundLoadFailed;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_saving ||
        _loading ||
        _stopped ||
        !_canApprove ||
        _selectedIds.isEmpty) {
      return;
    }
    final targets = _documents
        .where((d) => _selectedIds.contains(d.id) && _eligible(d))
        .toList();
    if (targets.isEmpty) return;
    // Lock selection and navigation before opening the second confirmation.
    setState(() {
      _saving = true;
      _confirming = true;
    });
    try {
      final confirmed = await UtenDialog.show(
        context,
        title: _l10n.warehouseStockOutboundConfirm,
        confirmLabel: _l10n.warehouseStockOutboundConfirm,
        danger: true,
        content: Text(
          _l10n.warehouseStockOutboundConfirmMessage(targets.length),
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _confirming = false);
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      for (final target in targets) {
        try {
          if (!_canApprove) throw StateError('Permission changed');
          final result = await repo.approveReviewed(
            target.id,
            expectedReviewToken: _reviewTokens[target.id]!,
          );
          if (result.status != 1 || result.id != target.id) {
            throw StateError('Unexpected result');
          }
          if (!mounted) return;
          setState(() {
            _doneIds.add(target.id);
            _selectedIds.remove(target.id);
          });
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _stopped = true;
            _results[target.id] =
                e is ApiException && e.httpStatus != null && e.httpStatus! < 500
                ? e.message
                : e is ApiException && e.code == 'CONFLICT'
                ? e.message
                : _l10n.warehouseOutboundBatchUnknown;
          });
          break;
        }
      }
      if (!mounted) return;
      bumpListRefresh(ref, widget.docType.refreshKey);
      invalidateWarehouseTaskCounts(ref);
      if (_stopped) {
        context.appWarning(_l10n.warehouseOutboundBatchStopped);
      } else {
        context.appSuccess(
          _l10n.warehouseStockOutboundCompleted(_doneIds.length),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _confirming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final names = ref.watch(masterNameServiceProvider);
    ref.watch(currentPermissionsProvider);
    ref.watch(documentScopeCapabilityProvider(DocumentDataScope.stockDocument));
    final effectiveSelection = _documents
        .where(_eligible)
        .map((d) => d.id)
        .toSet()
        .intersection(_selectedIds);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.warehouseStockOutboundTitle,
          leading: UtenBackButton(
            onPressed: _saving
                ? null
                : () => Navigator.of(context).pop(_doneIds.isNotEmpty),
          ),
          actions: [
            UtenAppBarActionButton(
              label: l10n.commonRefresh,
              icon: Icons.refresh_rounded,
              isLoading: _loading,
              onPressed: _saving || _loading ? null : _load,
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              AbsorbPointer(
                absorbing: _saving,
                child: UtenContentContainer.wide(
                  child: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                        ? UtenEmpty.error(
                            message: _error,
                            actionLabel: l10n.commonRetry,
                            onAction: _load,
                          )
                        : UtenCollapsingHeaderScrollView(
                            collapsingHeader: Column(
                              key: const Key(
                                'warehouse-stock-batch-outbound-header',
                              ),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                UtenCollapsibleSection(
                                  title: l10n.warehouseOutboundBatchDocuments,
                                  child: UtenFormGrid(
                                    children: [
                                      for (final document in _documents)
                                        _documentCard(document, names),
                                    ],
                                  ),
                                ),
                                if (_stopped)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: UtenSpacing.s8,
                                    ),
                                    child: Text(
                                      l10n.warehouseOutboundBatchStopped,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: UtenSpacing.s8),
                              ],
                            ),
                            body: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '${l10n.warehouseOutboundBatchLines} (${_documents.fold<int>(0, (count, d) => count + d.items.length)})',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: UtenSpacing.s8),
                                Expanded(
                                  child: WarehouseStockOutboundDetailTable(
                                    primary: true,
                                    documents: _documents,
                                    names: names,
                                    selectedIds: effectiveSelection,
                                    canSelect: (d) =>
                                        !_loading &&
                                        !_saving &&
                                        !_stopped &&
                                        _eligible(d),
                                    onSelectedIdsChanged: !_canApprove
                                        ? null
                                        : (next) => setState(() {
                                            _selectedIds
                                              ..clear()
                                              ..addAll(next);
                                          }),
                                    resultOf: (d) =>
                                        _doneIds.contains(d.id) || d.status == 1
                                        ? l10n.warehouseStockOutboundDone
                                        : _results[d.id] ??
                                              (_eligible(d)
                                                  ? l10n.warehouseOutboundBatchPending
                                                  : l10n.warehouseStockOutboundUnavailable),
                                    batchActionsBuilder: !_canApprove
                                        ? null
                                        : (_, ids) => [
                                            UtenButton(
                                              key: const Key(
                                                'warehouse-stock-batch-outbound-confirm',
                                              ),
                                              icon: Icons.outbound_outlined,
                                              isLoading:
                                                  _saving && !_confirming,
                                              type: UtenButtonType.danger,
                                              size: UtenButtonSize.large,
                                              onPressed:
                                                  _saving ||
                                                      _stopped ||
                                                      ids.isEmpty
                                                  ? null
                                                  : _submit,
                                              child: Text(
                                                l10n.warehouseStockOutboundConfirm,
                                              ),
                                            ),
                                          ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
              if (_saving && !_confirming)
                Positioned.fill(
                  child: UtenBusyOverlay(
                    title: l10n.warehouseStockOutboundProcessing,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _documentCard(StockDocDetail document, MasterNameService names) {
    final l10n = _l10n;
    final theme = Theme.of(context);
    final facts = <(String, String?)>[
      (l10n.warehouseOutboundBatchBillDate, document.billDate),
      if (document.workerId?.isNotEmpty == true)
        (l10n.warehouseOutboundBatchWorker, names.employee(document.workerId)),
      if (document.makerName?.trim().isNotEmpty == true)
        (l10n.warehouseOutboundBatchMaker, document.makerName),
      if (document.createdAt != null)
        (
          l10n.warehouseOutboundBatchCreatedAt,
          ChinaDateTime.formatIsoInstant(document.createdAt, fallback: '—'),
        ),
    ];
    return UtenCard(
      key: Key('warehouse-stock-outbound-document-${document.id}'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.warehouseStockOutboundBillNo,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            document.billNo ?? '—',
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
