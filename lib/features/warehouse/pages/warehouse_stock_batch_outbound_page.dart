import 'dart:convert';

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
import '../models/warehouse_task_item_selection.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/stock_doc_repository.dart';
import '../widgets/warehouse_stock_outbound_detail_table.dart';
import '../widgets/warehouse_task_session_guard.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

class WarehouseStockBatchOutboundPage extends ConsumerStatefulWidget {
  const WarehouseStockBatchOutboundPage({
    super.key,
    required this.docType,
    required this.documentIds,
    this.selectedItemIds,
  });
  final StockDocType docType;
  final List<String> documentIds;
  final List<String>? selectedItemIds;

  @override
  ConsumerState<WarehouseStockBatchOutboundPage> createState() =>
      _WarehouseStockBatchOutboundPageState();
}

class _WarehouseStockBatchOutboundPageState
    extends ConsumerState<WarehouseStockBatchOutboundPage>
    with WarehouseTaskSessionGuard<WarehouseStockBatchOutboundPage> {
  List<StockDocDetail> _documents = [];
  final Set<String> _selectedIds = {};
  final Set<String> _doneIds = {};
  final Map<String, String> _results = {};
  final Map<String, String> _reviewTokens = {};
  final Set<String> _pendingVerification = {};
  final Set<String> _blockedSources = {};
  final Map<String, Set<String>> _originalItemIds = {};
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _stopped = false;
  int _loadEpoch = 0;
  String? _error;
  bool get _inbound => widget.docType == StockDocType.otherIn;
  String get _confirmLabel =>
      _inbound ? '确认批量入库' : _l10n.warehouseStockOutboundConfirm;
  final Set<String> _incompleteDocuments = {};
  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();

  @override
  void initState() {
    super.initState();
    startWarehouseTaskGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant WarehouseStockBatchOutboundPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    String source(WarehouseStockBatchOutboundPage page) => jsonEncode([
      page.docType.code,
      page.documentIds.toList()..sort(),
      page.selectedItemIds == null
          ? null
          : (page.selectedItemIds!.toList()..sort()),
    ]);
    if (source(oldWidget) != source(widget)) invalidateWarehouseTask();
  }

  bool get _canApprove =>
      warehouseTaskCanWrite &&
      (ref.read(isSuperAdminProvider) ||
          ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove));

  @override
  void onWarehouseTaskInvalidated() {
    ++_loadEpoch;
    if (!mounted) return;
    setState(() {
      _documents = [];
      _selectedIds.clear();
      _doneIds.clear();
      _results.clear();
      _reviewTokens.clear();
      _pendingVerification.clear();
      _blockedSources.clear();
      _originalItemIds.clear();
      _incompleteDocuments.clear();
      _loading = false;
      _saving = false;
      _confirming = false;
      _stopped = true;
      _error = '账号、服务器或权限已变化，请重新进入核对';
    });
  }

  bool _eligible(StockDocDetail d) =>
      _canApprove &&
      d.docType == widget.docType.code &&
      d.status == 0 &&
      !d.closed &&
      d.items.isNotEmpty &&
      (!_inbound || !d.productionLinked) &&
      !_doneIds.contains(d.id) &&
      !_pendingVerification.contains(d.id) &&
      !_blockedSources.contains(d.id) &&
      (d.productionLinked ||
          documentOwnerCanWrite(
            ref.read(
              documentScopeCapabilityProvider(DocumentDataScope.stockDocument),
            ),
            d.makerId,
          ));

  Future<void> _load() async {
    if (_saving) return;
    if (!warehouseTaskIsCurrent) {
      if (mounted) onWarehouseTaskInvalidated();
      return;
    }
    final epoch = ++_loadEpoch;
    final recovering = _stopped || _pendingVerification.isNotEmpty;
    final previousSelection = Set<String>.of(_selectedIds);
    setState(() {
      _loading = true;
      _error = null;
      _selectedIds.clear();
    });
    try {
      final scope = await captureWarehouseTaskScope();
      await scope.run(() async {
        if (widget.docType != StockDocType.otherOut &&
            widget.docType != StockDocType.finishedOut &&
            !_inbound) {
          throw StateError('Unsupported outbound type');
        }
        final ids = widget.documentIds.toSet();
        if (ids.isEmpty || ids.length > 50) {
          throw StateError('Invalid batch size');
        }
        final names = ref.read(masterNameServiceProvider);
        await names.ensureLoaded();
        scope.checkCurrent();
        try {
          await ref.read(
            documentScopeCapabilityProvider(
              DocumentDataScope.stockDocument,
            ).future,
          );
        } catch (_) {
          // A failed capability lookup leaves the physical details read-only.
        }
        scope.checkCurrent();
        final repo = ref.read(stockDocRepositoryProvider(widget.docType));
        // Bounded GET concurrency; never replay a write on reconnect.
        final documents = <StockDocDetail>[];
        final reviewTokens = <String, String>{};
        final blocked = <String>{};
        final recoveryResults = <String, String>{};
        final targets = ids.toList();
        for (var offset = 0; offset < targets.length; offset += 5) {
          final reviews = await Future.wait(
            targets.skip(offset).take(5).map((id) async {
              try {
                final review = await (_inbound
                    ? repo.reviewNative(id)
                    : repo.review(id));
                if (review.document.id != id) {
                  throw StateError('Unexpected review source');
                }
                return (id: id, review: review);
              } catch (_) {
                if (!recovering) rethrow;
                return (id: id, review: null);
              }
            }),
          );
          scope.checkCurrent();
          for (final review in reviews) {
            if (review.review == null) {
              blocked.add(review.id);
              documents.add(
                StockDocDetail(id: review.id, docType: widget.docType.code),
              );
              recoveryResults[review.id] =
                  _pendingVerification.contains(review.id)
                  ? '原单当前不可读取，原结果继续待核对，不能再次办理'
                  : '来源当前不可办理，本次未派发，原范围继续保留';
              continue;
            }
            final value = review.review!;
            final itemIds = value.document.items
                .map((item) => item.id)
                .whereType<String>()
                .toSet();
            final original = _originalItemIds[review.id];
            if (recovering &&
                original != null &&
                (original.length != itemIds.length ||
                    !itemIds.containsAll(original))) {
              blocked.add(review.id);
              documents.add(
                StockDocDetail(id: review.id, docType: widget.docType.code),
              );
              recoveryResults[review.id] =
                  _pendingVerification.contains(review.id)
                  ? '原明细范围已变化，原结果继续待核对，不能再次办理'
                  : '来源明细范围已变化，本次未派发，原范围继续保留';
              continue;
            }
            if (_pendingVerification.contains(review.id)) {
              if (original == null ||
                  original.length != itemIds.length ||
                  !itemIds.containsAll(original)) {
                blocked.add(review.id);
                documents.add(
                  StockDocDetail(id: review.id, docType: widget.docType.code),
                );
                recoveryResults[review.id] = '原明细范围已变化，原结果继续待核对，不能再次办理';
                continue;
              }
              if (value.document.status == 1) {
                _pendingVerification.remove(review.id);
                _doneIds.add(review.id);
                recoveryResults[review.id] = _inbound ? '已核对原入库结果' : '已核对原出库结果';
              } else {
                recoveryResults[review.id] = '尚未查到原办理结果，请继续只读核对，不能重新派发';
              }
            } else {
              _originalItemIds[review.id] = itemIds;
            }
            documents.add(value.document);
            reviewTokens[review.id] = value.reviewToken;
          }
        }
        final selection = WarehouseTaskItemSelection(widget.selectedItemIds);
        selection.validate([
          ...documents
              .expand((document) => document.items)
              .map((item) => item.id),
          if (recovering)
            for (final id in blocked) ...?_originalItemIds[id],
        ]);
        final incompleteDocuments = <String>{};
        for (var index = 0; index < documents.length; index++) {
          final document = documents[index];
          if (blocked.contains(document.id)) continue;
          final items = document.items
              .where((item) => selection.contains(item.id))
              .toList();
          if (items.length != document.items.length) {
            incompleteDocuments.add(document.id);
          }
          documents[index] = document.withItems(items);
        }
        await names.loadGoodsDetails(
          documents
              .expand((d) => d.items)
              .map((i) => i.goodsId)
              .whereType<String>()
              .toSet(),
        );
        // 经办人姓名由详情接口随单返回(workerName), 不再逐张查员工档案
        // (该接口要求 employee:view 且每次调用落人事查看审计)。
        scope.checkCurrent();
        if (epoch != _loadEpoch) return;
        setState(() {
          _documents = documents;
          _reviewTokens
            ..clear()
            ..addAll(reviewTokens);
          _results
            ..clear()
            ..addAll(recoveryResults);
          _blockedSources
            ..clear()
            ..addAll(blocked);
          _incompleteDocuments
            ..clear()
            ..addAll(incompleteDocuments);
          _stopped = _pendingVerification.isNotEmpty;
          _selectedIds.addAll(
            documents
                .where(_eligible)
                .where(
                  (document) =>
                      !recovering || previousSelection.contains(document.id),
                )
                .map((d) => d.id),
          );
          _loading = false;
        });
      });
    } catch (e) {
      if (warehouseTaskIsCurrent && epoch == _loadEpoch) {
        setState(() {
          _loading = false;
          _error = e is ApiException
              ? e.message
              : _inbound
              ? '入库明细加载失败，请刷新后核对'
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
    if (targets.any((target) => _incompleteDocuments.contains(target.id))) {
      context.appWarning('该单据需整单确认，请返回任务中心选齐同单明细；本次未办理');
      return;
    }
    // Lock selection and navigation before opening the second confirmation.
    setState(() {
      _saving = true;
      _confirming = true;
    });
    try {
      final scope = await captureWarehouseTaskScope();
      if (!mounted) return;
      final confirmed = await UtenDialog.show(
        context,
        title: _confirmLabel,
        confirmLabel: _confirmLabel,
        danger: true,
        content: Text(
          _inbound
              ? '确认将所选 ${targets.length} 张原入库单完整审核入库？未选单据继续保留草稿。'
              : _l10n.warehouseStockOutboundConfirmMessage(targets.length),
        ),
      );
      if (confirmed != true || !warehouseTaskIsCurrent) return;
      scope.checkCurrent();
      setState(() => _confirming = false);
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      for (final target in targets) {
        var dispatched = false;
        try {
          if (!_canApprove) throw StateError('Permission changed');
          scope.checkCurrent();
          final result = await scope.run(() {
            dispatched = true;
            return repo.approveReviewed(
              target.id,
              expectedReviewToken: _reviewTokens[target.id]!,
              itemIds: widget.selectedItemIds == null
                  ? null
                  : target.items
                        .map((item) => item.id)
                        .whereType<String>()
                        .toList(),
            );
          });
          scope.checkCurrent();
          if (result.status != 1 || result.id != target.id) {
            throw StateError('Unexpected result');
          }
          if (!warehouseTaskIsCurrent) return;
          setState(() {
            _doneIds.add(target.id);
            _selectedIds.remove(target.id);
          });
        } catch (e) {
          if (!warehouseTaskIsCurrent) return;
          setState(() {
            final definite =
                e is ApiException &&
                ((e.httpStatus != null &&
                        const [
                          400,
                          403,
                          404,
                          409,
                          422,
                        ].contains(e.httpStatus) &&
                        e.hasResponseCode) ||
                    e.code == 'CONFLICT');
            if (dispatched && !definite) _pendingVerification.add(target.id);
            _stopped = true;
            _results[target.id] =
                e is ApiException && e.httpStatus != null && e.httpStatus! < 500
                ? e.message
                : e is ApiException && e.code == 'CONFLICT'
                ? e.message
                : _inbound
                ? '入库结果尚未确认，请刷新原单核对'
                : _l10n.warehouseOutboundBatchUnknown;
          });
          break;
        }
      }
      if (!mounted || !warehouseTaskIsCurrent) return;
      bumpListRefresh(ref, widget.docType.refreshKey);
      invalidateWarehouseTaskCounts(ref);
      if (_stopped) {
        context.appWarning(
          _inbound ? '本批入库已暂停，请核对未完成单据' : _l10n.warehouseOutboundBatchStopped,
        );
      } else {
        context.appSuccess(
          _inbound
              ? '已完成 ${_doneIds.length} 张入库单'
              : _l10n.warehouseStockOutboundCompleted(_doneIds.length),
        );
      }
    } on ApiException catch (error) {
      if (warehouseTaskIsCurrent) {
        setState(() {
          _stopped = true;
          _error = error.message;
        });
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
          title: _inbound ? '批量入库核对' : l10n.warehouseStockOutboundTitle,
          leading: UtenBackButton(
            enabled: !_saving,
            onPressed: () => Navigator.of(context).pop(_doneIds.isNotEmpty),
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
                  child: UtenPageEdgePadding(
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
                                if (_incompleteDocuments.isNotEmpty)
                                  Text(
                                    '该单据需整单确认，请返回任务中心选齐同单明细',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                UtenCollapsibleSection(
                                  title: l10n.warehouseOutboundBatchDocuments,
                                  // 列数既按容器宽度算，也不超过单据张数：只有一张单
                                  // 据时卡片横铺满屏，不再固定占三分之一屏。
                                  child: UtenFormGrid(
                                    maxColumns: _documents.isEmpty
                                        ? 1
                                        : _documents.length,
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
                                      _inbound
                                          ? '本批入库已暂停，请核对未完成单据'
                                          : l10n.warehouseOutboundBatchStopped,
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
                            // 明细表直接占满 body：不再写「出库明细」标题，
                            // 页面本身就叫批量出库详情，表头已说明每列是什么。
                            body: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: WarehouseStockOutboundDetailTable(
                                    primary: true,
                                    documents: _documents,
                                    inbound: _inbound,
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
                                        ? (_inbound
                                              ? '已入库'
                                              : l10n.warehouseStockOutboundDone)
                                        : _results[d.id] ??
                                              (_eligible(d)
                                                  ? l10n.warehouseOutboundBatchPending
                                                  : (_inbound
                                                        ? '当前不可入库'
                                                        : l10n.warehouseStockOutboundUnavailable)),
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
                                              child: Text(_confirmLabel),
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
                    title: _inbound
                        ? '正在确认入库'
                        : l10n.warehouseStockOutboundProcessing,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _documentCard(StockDocDetail document, MasterNameService names) {
    if (_blockedSources.contains(document.id)) {
      return UtenCard(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Text(
          '来源 ${document.id}\n${_results[document.id] ?? '当前不可办理，原范围保留'}',
        ),
      );
    }
    final l10n = _l10n;
    final theme = Theme.of(context);
    final facts = <(String, String?)>[
      (l10n.warehouseOutboundBatchBillDate, document.billDate),
      if (document.workerId?.isNotEmpty == true)
        (
          l10n.warehouseOutboundBatchWorker,
          names.employeeOr(document.workerName, document.workerId),
        ),
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
            _inbound ? '入库单号' : l10n.warehouseStockOutboundBillNo,
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
