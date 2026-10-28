import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/native_facet_options.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:async';
import '../../../shared/auth/native_read_view_scope_mixin.dart'
    show nativeReadAccessDenied;
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/paging/paged_query_identity.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/models/party_open_balance.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/master_server_column_filters.dart';
import '../models/sales_order_finance_confirmation.dart';
import '../providers/finance_name_provider.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';
import '../../../shared/drafts/review_task_draft.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../core/router/page_resume_provider.dart';

/// 销售订货单财务确认工作台（V294 闸门，V300 驳回，批量确认）。
///
/// 大小屏同一张表（窄屏横向滚动）：单击选择、双击进入审核详情、复选多选和
/// 批量确认；右键/长按行菜单保留显式「查看详情」入口，不把双击作为唯一入口。
///
/// [embedded]：嵌入「业务审核中心」分段时为 true——去掉本页 AppBar 与内容
/// 容器（外层提供标题/刷新/容器），保留右下角批量确认 FAB；[refreshTick] 由
/// 外层刷新按钮/返回本页时递增，变化即重拉当前页。
class FinanceSalesOrderConfirmationPage extends ConsumerStatefulWidget {
  const FinanceSalesOrderConfirmationPage({
    super.key,
    this.changesOnly = false,
    this.initialState,
    this.embedded = false,
    this.externalHeader,
    this.refreshTick = 0,
    this.refreshCompletion,
  });

  final bool changesOnly;
  final String? initialState;
  final bool embedded;

  /// 宿主（业务审核中心）的大类行：挂进本页折叠头，随页一起滚走
  /// （2026-09-24 用户口径「表格滑到顶」，置顶后只剩表格自身工具条）。
  final Widget? externalHeader;

  /// 外层（业务审核中心）触发的刷新信号；数值变化时重拉当前视图。
  final int refreshTick;
  final Completer<void>? refreshCompletion;

  @override
  ConsumerState<FinanceSalesOrderConfirmationPage> createState() =>
      _FinanceSalesOrderConfirmationPageState();
}

class _FinanceSalesOrderConfirmationPageState
    extends ConsumerState<FinanceSalesOrderConfirmationPage>
    with ScopedPagedReadViewMixin<FinanceSalesOrderConfirmationPage> {
  /// 宿主页路径(创建时捕获), 精准刷新信号只在它就在栈顶时立即重拉。
  String? _hostLocation;

  static const int _maxBatchSize = 100;

  SalesOrderFinancePendingPage? _result;
  bool _loading = false;
  bool _batchBusy = false;
  String? _error;
  String _keyword = '';
  int _requestVersion = 0;
  int _countVersion = 0;
  int? _readerEpoch;
  Map<String, dynamic>? _acceptedQuery;
  final _tableRows =
      MasterDataTableRowsController<SalesOrderFinancePendingItem>();
  final Set<String> _selectedIds = <String>{};
  final Map<String, SalesOrderFinancePendingItem> _selectedItems =
      <String, SalesOrderFinancePendingItem>{};
  SalesOrderFinancePendingItem? _activeItem;
  TaskClaimSession? _batchClaim;

  @override
  void dispose() {
    ++_requestVersion;
    final completion = widget.refreshCompletion;
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
    _batchClaim?.releaseAll().ignore();
    super.dispose();
  }

  String _state = 'pending';
  String? _confirmationKind;
  bool get _showRejected => _state == 'rejected';
  bool get _showConfirmed => _state == 'confirmed';
  bool get _canBatchDecide => !_showRejected && !_showConfirmed;
  bool? get _changesFilter => !_canBatchDecide
      ? null
      : switch (_confirmationKind) {
          'initial' => false,
          'changes' => true,
          _ => null,
        };

  /// 「已驳回」段的全量张数(中性括号, 下一步在销售手上; 2026-09-21 父有红徽章子也要有数)。
  /// null = 尚未取到, 不渲染数字。
  int? _rejectedCount;

  /// 表头排序 + 销售单号列值筛选 + facets 桶 + 防串台代数
  /// （2026-09-25 单号列统一，共享状态见 MasterServerColumnFilters）；
  /// 排序列 key 见 [_kSortFields]，null = 服务端默认序。
  final _columnFilters = MasterServerColumnFilters();

  bool get _canView {
    return ref.read(isSuperAdminProvider) ||
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.salesOrderFinanceView);
  }

  bool get _canConfirm {
    return ref.read(isSuperAdminProvider) ||
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.salesOrderFinanceConfirm);
  }

  @override
  void initState() {
    super.initState();
    _readerEpoch = ref.read(exportContextEpochProvider);
    _state = _initialSelection.state;
    _confirmationKind = _initialSelection.kind;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 客户应收列前缀要显示本位币名(币种字典 baseCurrency 标记)。
      ref.read(financeNameServiceProvider).ensureLoaded();
      final completion = widget.refreshCompletion;
      _load(1).whenComplete(() {
        if (completion != null && !completion.isCompleted) {
          completion.complete();
        }
      });
    });
  }

  @override
  void didUpdateWidget(FinanceSalesOrderConfirmationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialState != widget.initialState ||
        oldWidget.changesOnly != widget.changesOnly) {
      _switchTab(
        _initialSelection.state,
        confirmationKind: _initialSelection.kind,
      );
    }
    if (widget.refreshTick != oldWidget.refreshTick) {
      final completion = widget.refreshCompletion;
      _refreshCurrent().whenComplete(() {
        if (completion != null && !completion.isCompleted) {
          completion.complete();
        }
      });
    }
  }

  @override
  void scopedPagedReadOwnerChanged() {
    final epoch = ref.read(exportContextEpochProvider);
    final changedOwner = _readerEpoch != epoch;
    _readerEpoch = epoch;
    ++_requestVersion;
    ++_countVersion;
    if (!mounted) return;
    setState(() {
      _result = null;
      _acceptedQuery = null;
      _rejectedCount = null;
      _columnFilters.reset();
      _clearSelectionState();
      _loading = false;
      _error =
          scopedPagedReadRejection?.message ??
          (changedOwner ? null : '读取权限已变化，请重新加载');
    });
    if (changedOwner) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _canView &&
            epoch == ref.read(exportContextEpochProvider)) {
          _load(1);
        }
      });
    }
  }

  Map<String, dynamic> get _cacheQuery => {
    'owner': ref.read(exportContextEpochProvider),
    'repository': ref.read(salesOrderFinanceConfirmationRepositoryProvider),
    'keyword': _keyword,
    'state': _state,
    'confirmationKind': _confirmationKind,
    'columns': Map.of(_columnFilters.values),
    'sort': _columnFilters.sortColumn,
    'ascending': _columnFilters.sortAscending,
  };

  Future<void> _navigatePage(int page) => _load(page, useCache: true);

  Future<void> _load(int page, {bool useCache = false}) async {
    final cacheQuery = _cacheQuery;
    final repo = ref.read(salesOrderFinanceConfirmationRepositoryProvider);
    final rejected = _showRejected;
    final confirmed = _showConfirmed;
    final changesOnly = _changesFilter;
    final keyword = _keyword.isEmpty ? null : _keyword;
    final sort = _kSortFields[_columnFilters.sortColumn];
    final order = _columnFilters.sortColumn == null
        ? null
        : (_columnFilters.sortAscending ? 'asc' : 'desc');
    final billNo = _columnFilters['billNo'];

    if (!_canView) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      if (!samePagedReadQuery(_acceptedQuery, cacheQuery)) {
        _result = null;
        _columnFilters.generation++;
        _columnFilters.buckets = const {};
        _clearSelectionState();
      }
      _loading = true;
      _error = null;
    });
    // 「已驳回」段全量数(不带关键字)先于列表请求发出, 列表请求始终是本轮最后一个请求;
    // 已驳回段下且未搜索时本页 total 就是全量驳回数, 不另发。
    unawaited(_loadHistoryCounts(requestVersion));
    try {
      final cachedPage = await readScopedPage<SalesOrderFinancePendingItem>(
        page,
        query: cacheQuery,
        currentQuery: () => _cacheQuery,
        useCache: useCache,
        fetchPage: (target) async {
          final response = await repo.pending(
            page: target,
            rejected: rejected,
            keyword: keyword,
            changesOnly: changesOnly,
            confirmed: confirmed,
            sort: sort,
            order: order,
            billNo: billNo,
          );
          return PagedReadSnapshot<
            SalesOrderFinancePendingItem,
            SalesOrderFinancePendingPage
          >(
            page: PagedResult(
              items: response.items,
              page: response.page,
              size: response.size,
              total: response.total,
              totalPages: response.totalPages,
            ),
            snapshot: response,
          );
        },
      );
      final result =
          (cachedPage
                  as PagedReadSnapshot<
                    SalesOrderFinancePendingItem,
                    SalesOrderFinancePendingPage
                  >)
              .snapshot;
      if (!mounted || requestVersion != _requestVersion) return;
      // 单号 facets 与列表同口径（2026-09-25 单号列统一）；失败静默（下拉降级为空）。

      setState(() {
        _result = result;
        _acceptedQuery = cacheQuery;
        _loading = false;
        for (final item in result.items) {
          if (_selectedIds.contains(item.orderId)) {
            _selectedItems[item.orderId] = item;
          }
        }
        if (_activeItem != null &&
            !result.items.any((item) => item.orderId == _activeItem!.orderId)) {
          _activeItem = null;
        }
        // 已驳回段下且未搜索: 本页 total 就是全量驳回数, 不另发请求。
        if (_showRejected &&
            _keyword.isEmpty &&
            _columnFilters['billNo'] == null) {
          _rejectedCount = result.total;
        }
      });
      // 分段计数与列表同源, 随列表加载一并失效(页内专用, 不连带整份徽章汇总)。
      ref.invalidate(salesOrderFinanceQueueCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) {
        return;
      }
      if (nativeReadAccessDenied(error)) {
        _retireDeniedRead(error);
        return;
      }
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '待确认任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 财务退回仍是未完成的修订工作；仅取其全量计数，不给已完成历史挂计数。
  Future<void> _loadHistoryCounts(int requestVersion) async {
    final epoch = ref.read(exportContextEpochProvider);
    final generation = ++_countVersion;
    final repo = ref.read(salesOrderFinanceConfirmationRepositoryProvider);
    bool current() =>
        mounted &&
        requestVersion == _requestVersion &&
        generation == _countVersion &&
        epoch == ref.read(exportContextEpochProvider);
    try {
      final rejected = await repo.pending(size: 1, rejected: true);
      if (!current()) return;
      setState(() {
        _rejectedCount = rejected.total;
      });
    } catch (error) {
      if (current() && error is ApiException && nativeReadAccessDenied(error)) {
        _retireDeniedRead(error);
      }
      // 计数失败静默: 分段不显示数字, 不影响列表。
    }
  }

  void _retireDeniedRead(ApiException error) {
    invalidateScopedPageReads();
    ++_requestVersion;
    ++_countVersion;
    setState(() {
      _result = null;
      _acceptedQuery = null;
      _rejectedCount = null;
      _columnFilters.reset();
      _clearSelectionState();
      _loading = false;
      _error = error.message;
    });
  }

  /// 表头排序键 → 服务端 sort 参数（2026-09-25 单号列统一；未列出的列不可排序）。
  static const _kSortFields = <String, String>{'billNo': 'billNo'};

  /// 表头排序变化：服务端重排整个结果集，回第 1 页（勾选清空防指向已变化任务）。
  void _onSortChange(String? column, bool ascending) {
    final next = column != null && _kSortFields.containsKey(column)
        ? column
        : null;
    if (next == _columnFilters.sortColumn &&
        (next == null || ascending == _columnFilters.sortAscending)) {
      return;
    }
    _columnFilters.handleSortChanged(
      next,
      ascending,
      onChanged: () {
        if (mounted) setState(() {});
        _load(1);
      },
    );
  }

  /// 销售单号 facets（2026-09-25 单号列统一）：与列表同过滤口径
  /// （不含单号列自身值筛选）。

  ({String state, String? kind}) get _initialSelection {
    final requested =
        const {
          'pending',
          'initial',
          'changes',
          'confirmed',
          'rejected',
        }.contains(widget.initialState)
        ? widget.initialState!
        : widget.changesOnly
        ? 'changes'
        : 'pending';
    return switch (requested) {
      'initial' || 'changes' => (state: 'pending', kind: requested),
      _ => (state: requested, kind: null),
    };
  }

  void _switchTab(String state, {String? confirmationKind}) {
    if (state == _state && confirmationKind == _confirmationKind) return;
    ++_requestVersion;
    setState(() {
      _state = state;
      _confirmationKind = confirmationKind;
      _result = null;
      _error = null;
      ++_columnFilters.generation;
      _columnFilters.reset();
      _clearSelectionState();
    });
    _load(1);
  }

  void _filterConfirmationKind(String? value) {
    if (_state != 'pending' || _batchBusy || _batchClaim != null) return;
    if (value != null && value != 'initial' && value != 'changes') return;
    _switchTab('pending', confirmationKind: value);
  }

  void _clearSelectionState() {
    _selectedIds.clear();
    _selectedItems.clear();
    _activeItem = null;
  }

  Future<void> _refreshCurrent() async {
    setState(_clearSelectionState);
    await _load(_tableRows.visiblePage ?? _result?.page ?? 1);
  }

  void _invalidateSearchRequest(String _) {
    ++_requestVersion;
  }

  void _applyKeyword(String value) {
    final next = value.trim();
    if (next == _keyword) return;
    setState(() {
      _keyword = next;
      _result = null;
      _error = null;
      _clearSelectionState();
    });
    _load(1);
  }

  void _setSelectedIds(Set<String> next) {
    if (_batchClaim != null) return;
    if (next.length > _maxBatchSize) {
      context.appWarning('单次最多选择 $_maxBatchSize 笔订单');
      return;
    }
    final pageItems = {for (final item in _tableRows.items) item.orderId: item};
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
      _selectedItems.removeWhere((id, _) => !next.contains(id));
      for (final id in next) {
        final item = pageItems[id];
        if (item != null) _selectedItems[id] = item;
      }
    });
  }

  /// 打开财务审核详情页；确认/驳回后返回 true → 刷新当前视图。
  Future<void> _open(SalesOrderFinancePendingItem item) async {
    final drafts = _taskDrafts(item);
    if (drafts.isNotEmpty) {
      await resumeTaskFormDraft(context, ref, drafts);
      if (mounted) await _refreshCurrent();
      return;
    }
    final route = Uri.parse(
      item.detailRoute,
    ).replace(queryParameters: {'returnTo': _returnPath});
    final changed = await context.push<bool>(route.toString());
    if (changed == true && mounted) {
      setState(() {
        _selectedIds.remove(item.orderId);
        _selectedItems.remove(item.orderId);
      });
      _load(_tableRows.visiblePage ?? _result?.page ?? 1);
    }
  }

  List<SalesOrderFinancePendingItem> get _selectedTasks {
    final tasks = _selectedItems.values
        .where((item) => _taskDrafts(item).isEmpty)
        .toList(growable: false);
    tasks.sort((a, b) => a.billNo.compareTo(b.billNo));
    return tasks;
  }

  Future<void> _confirmSelected() async {
    if (_batchBusy || _batchClaim != null) return;
    if (!_canBatchDecide) {
      context.appWarning('只有待确认或订单修改待确认的订单可以批量确认');
      return;
    }
    if (!_canConfirm) {
      context.appWarning('您没有销售订单财务确认权限');
      return;
    }
    final tasks = _selectedTasks;
    if (tasks.isEmpty) {
      context.appWarning('请先选择需要确认的订单');
      return;
    }

    final claim = financeReviewClaim(
      ProviderScope.containerOf(context, listen: false),
      localizations: AppLocalizations.of(context),
    );
    _batchClaim = claim;
    var decisionAttempted = false;
    var decisionConfirmed = false;
    setState(() => _batchBusy = true);
    try {
      await claim.claimAll(
        'SALES_ORDER_FINANCE_CONFIRM',
        tasks.map((task) => task.orderId),
      );
      if (!mounted || !claim.isReady) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '整批还没有认领成功，请重试');
        }
        return;
      }
      for (final task in tasks) {
        final snapshot = await ref
            .read(salesOrderFinanceConfirmationRepositoryProvider)
            .review(task.orderId);
        if (!mounted || !claim.isReady) return;
        if (snapshot.financeReviewRevision != task.financeReviewRevision ||
            snapshot.financeConfirmed ||
            snapshot.financeRejected) {
          context.appWarning('订单内容或状态已变化，请刷新并重新核对后再批量审核');
          return;
        }
      }

      setState(() => _batchBusy = false);
      final controller = TextEditingController();
      var remark = '';
      late final bool? approved;
      try {
        approved = await UtenDialog.showAndWaitForExit<bool>(
          context,
          onPopped: (_) {
            remark = controller.text;
          },

          builder: (dialogContext) => UtenAlertDialog(
            scrollable: false,
            title: Text('批量确认 ${tasks.length} 笔销售订单'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const UtenReviewerResponsibilityNotice(
                      actionLabel: '销售订单批量财务确认',
                      description: '本次确认要么全部生效、要么全部不生效；有一笔订单有问题，整批都不会通过。',
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    const Text(
                      '确认只放行计划部可见与排产，不代表已收款，也不会在此建立正式应收。'
                      '请确认下列订单已逐笔核对金额、客户应收和发运策略：',
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.outlineVariant,
                          ),
                          borderRadius: UtenRadius.mdAll,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: tasks.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.outlineVariant,
                          ),
                          itemBuilder: (context, index) {
                            final item = tasks[index];
                            return ListTile(
                              dense: true,
                              title: Text(
                                item.billNo,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(item.clientName ?? '未标注客户'),
                              trailing: Text(
                                _orderAmount(item),
                                textAlign: TextAlign.end,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      key: const Key('sales-order-finance-batch-remark'),
                      controller: controller,
                      maxLength: 500,
                      maxLines: 2,
                      decoration: UtenInputDecoration(
                        const InputDecoration(
                          labelText: '统一确认备注(选填)',
                          border: OutlineInputBorder(),
                        ),
                        info:
                            '${workflowFieldText(context).workflowFinanceReviewHint} 该备注写入本次选中的每笔订单。',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FinanceReviewClaimButton(
                key: const Key('sales-order-finance-batch-submit'),
                claim: claim,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text('确认通过 ${tasks.length} 笔'),
              ),
            ],
          ),
        );
      } finally {
        controller.dispose();
      }

      if (approved != true || !mounted) return;

      setState(() => _batchBusy = true);
      if (!await claim.validateForDecision() || !mounted) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '认领已失效，请重新认领后核对');
        }
        return;
      }
      decisionAttempted = true;
      await ref
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .confirmBatch(
            tasks.map((item) => item.orderId),
            remark: remark,
            expectedRevisions: {
              for (final task in tasks)
                task.orderId: task.financeReviewRevision,
            },
            expectedClaimIds: {
              for (final task in tasks)
                task.orderId: claim.claimIdFor(
                  'SALES_ORDER_FINANCE_CONFIRM',
                  task.orderId,
                )!,
            },
          );
      decisionConfirmed = true;
      if (!mounted) return;
      context.appSuccess('已批量确认 ${tasks.length} 笔，计划部可接手排产');
      final page = _result?.page ?? 1;
      setState(_clearSelectionState);
      refreshBadges(ref);
      await _load(page);
    } on Object catch (error) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      if (decisionConfirmed) {
        context.appWarning(l10n.financeBatchReviewRefreshFailed);
      } else if (decisionAttempted &&
          (error is! ApiException ||
              error.code == 'NETWORK' ||
              error.code == 'NETWORK_TIMEOUT' ||
              error.code == 'UNKNOWN' ||
              (error.httpStatus ?? 0) >= 500)) {
        context.appWarning(l10n.financeBatchReviewResultUnknown);
      } else {
        context.appApiError(
          error,
          fallback: l10n.financeBatchReviewCheckFailed,
        );
      }
    } finally {
      await claim.releaseAll();
      if (identical(_batchClaim, claim)) _batchClaim = null;
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  /// 审核详情的返回落点：嵌入审核中心时回审核中心；独立页时回对应队列
  /// （详情页办结后 bumpListRefresh 也用同一 key，见 finance_sales_order_review_page）。
  String get _returnPath => Uri(
    path: widget.embedded
        ? RouteName.financeAudits
        : '/finance/sales-order-confirmations',
    queryParameters: {
      if (widget.embedded) 'segment': 'salesConfirm',
      // Legacy state=changes remains a stable return/deep-link encoding.
      'state': _confirmationKind ?? _state,
    },
  ).toString();

  @override
  Widget build(BuildContext context) {
    ref.watch(formDraftsProvider);
    final returnPath = _returnPath;
    // 审核页确认/驳回成功 bump 的信号: 本队列就在栈顶时立即重拉, 被审核页盖着时
    // 留给返回时的刷新(ADR-108)。
    _hostLocation ??= currentLocationOr(context, returnPath);
    ref.onListRefresh(_hostLocation!, 'finance:sales-order:$returnPath', () {
      if (mounted) _refreshCurrent();
    });
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.salesOrderFinanceView);
    final canConfirm =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.salesOrderFinanceConfirm);
    final Widget main;
    if (!allowed) {
      main = _pinHostHeader(
        UtenEmpty.error(
          message: '无权查看销售订单财务确认任务',
          description: AppLocalizations.of(
            context,
          ).financeSalesReviewAccessHint,
        ),
      );
    } else {
      main = _buildBody(context, canConfirm: canConfirm);
    }
    final body = SafeArea(
      child: Stack(
        children: [
          main,
          // 批量确认提交期间的全屏居中遮罩（2026-09-25 统一口径：点按钮跑
          // 网络一律 UtenBusyOverlay，弃折叠头里的加载条）。
          if (_batchBusy)
            const Positioned.fill(
              child: UtenBusyOverlay(title: '正在确认所选订单，请稍候'),
            ),
        ],
      ),
    );
    if (widget.embedded) {
      // 嵌入形态：无 AppBar（标题/刷新由业务审核中心提供），保留批量确认 FAB。
      return Scaffold(
        body: body,
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: allowed && canConfirm && _canBatchDecide
            ? _floatingSelectionActions()
            : null,
      );
    }
    return Scaffold(
      appBar: UtenAppBar(
        title: '销售订单财务确认',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: '/finance'),
        ),
        actions: allowed
            ? [
                UtenAppBarActionButton(
                  key: const Key('sales-order-finance-confirm-refresh'),
                  label: '刷新',
                  icon: Icons.refresh_rounded,
                  isLoading: _loading,
                  onPressed: _loading || _batchBusy ? null : _refreshCurrent,
                ),
              ]
            : null,
      ),
      body: body,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: allowed && canConfirm && _canBatchDecide
          ? _floatingSelectionActions()
          : null,
    );
  }

  Widget _floatingSelectionActions() {
    final selectedCount = _selectedIds.length;
    final selectedItem = selectedCount == 1
        ? _selectedItems[_selectedIds.single]
        : null;
    final canConfirmNow = selectedCount > 0 && !_loading && !_batchBusy;
    const disabledReason = '请先选择至少一笔待确认订单';
    return UtenFloatingActionGroup(
      children: [
        // 已选胶囊随悬浮组首位（2026-10-04 全站口径：已选恒右下悬浮）。
        UtenSelectionSummaryPill(
          count: selectedCount,
          onClear: selectedCount == 0 || _loading || _batchBusy
              ? null
              : () => _setSelectedIds(<String>{}),
        ),
        UtenButton(
          key: const Key('sales-order-finance-open-selected'),
          size: UtenButtonSize.large,
          type: UtenButtonType.secondary,
          icon: Icons.open_in_new_rounded,
          onPressed: selectedItem == null || _batchBusy
              ? null
              : () => _open(selectedItem),
          onDisabledTap: selectedCount > 1
              ? () => context.appWarning('查看详情时只能选择一笔订单')
              : null,
          child: const Text('查看详情'),
        ),
        Tooltip(
          message: canConfirmNow ? '批量确认所选订单' : disabledReason,
          child: UtenButton(
            key: const Key('sales-order-finance-batch-confirm'),
            size: UtenButtonSize.large,
            type: UtenButtonType.danger,
            icon: Icons.fact_check_outlined,
            onPressed: canConfirmNow ? _confirmSelected : null,
            onDisabledTap: canConfirmNow
                ? null
                : () => context.appWarning(disabledReason),
            child: Text(selectedCount == 0 ? '批量确认' : '批量确认($selectedCount)'),
          ),
        ),
      ],
    );
  }

  /// 骨架/错误/无权态钉住宿主分类栏：分类栏在、内容区给 [child]（数据到位后由
  /// [_buildBody] 接管，分类栏随页滚走）。2026-10-01 用户口径：点击子分类的
  /// 瞬间整条分类栏不得消失。
  Widget _pinHostHeader(Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.externalHeader != null) ...[
        widget.externalHeader!,
        const SizedBox(height: UtenSpacing.s8),
      ],
      Expanded(child: child),
    ],
  );

  Widget _buildBody(BuildContext context, {required bool canConfirm}) {
    final result =
        _result ??
        const SalesOrderFinancePendingPage(
          items: <SalesOrderFinancePendingItem>[],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 大小屏共用一张表：窄屏同样横向滚动（2026-10-09 卡片形态退役）。
        final workbench = _desktopWorkbench(
          context,
          result,
          canConfirm: canConfirm,
        );
        // 嵌入形态不复套容器与内边距（业务审核中心已提供），避免双重 gutter。
        if (widget.embedded) return workbench;
        return UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: workbench,
          ),
        );
      },
    );
  }

  Widget _desktopWorkbench(
    BuildContext context,
    SalesOrderFinancePendingPage result, {
    required bool canConfirm,
  }) {
    final theme = Theme.of(context);
    // 2026-09-24 对齐物料分析页口径：筛选/错误行进折叠头（上滑先收走，
    // 表头顶到头再表内滚）；独立页与业务审核中心嵌入态同款。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 宿主大类行随页滚走（2026-09-24「表格滑到顶」）。
          if (widget.externalHeader != null) ...[
            widget.externalHeader!,
            const SizedBox(height: UtenFilterRow.rowGap),
          ],
          _filters(theme),
          if (!widget.embedded)
            const TaskDraftRecoveryNotice(
              scope: FormDraftCategoryScope(
                module: BadgeModule.finance,
                routePrefix: '/finance/sales-order-confirmations/',
              ),
            ),
          if (_error != null && result.items.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            _InlineError(
              message: _error!,
              onRetry: () => _load(_tableRows.visiblePage ?? result.page),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
        ],
      ),
      body: MasterDataTableView<SalesOrderFinancePendingItem>(
        expensiveRowMounts: false,
        rowsController: _tableRows,
        paginationRevision: _result,
        paginationScope: (_keyword, _state, _confirmationKind),
        tableKey: 'sales.order.items',
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        key: const Key('sales-order-finance-desktop-table'),
        bottomContentPadding: _canBatchDecide && canConfirm
            ? UtenFloatingActionGroup.scrollClearance
            : widget.embedded
            ? UtenSpacing.s24
            : math.max(
                UtenSpacing.s24,
                UtenCapsuleNavScope.occlusionOf(context),
              ),
        selectable: _canBatchDecide && canConfirm,
        idOf: (item) => _taskDrafts(item).isEmpty ? item.orderId : null,
        selectedIds: _selectedIds,
        onSelectedIdsChanged: _setSelectedIds,
        // 已选胶囊由页面右下 FAB 自摆（_floatingSelectionActions 首位）；
        // 空 builder 旧写法退役（组件层动作空列表时仍渲染胶囊组，会双胶囊）。
        showSelectionSummary: false,
        columns: _columns(),
        items: result.items,
        // 销售单号表头值筛选（2026-09-25 单号列统一）：服务端分组计数桶。
        facets: <String, List<MasterFacetBucket>>{
          if (_canBatchDecide)
            'status': const [
              MasterFacetBucket(value: 'initial', count: 0, label: '首次待确认'),
              MasterFacetBucket(value: 'changes', count: 0, label: '订单修改待确认'),
            ],
          'billNo': _columnFilters.bucketOf('billNo'),
        },
        nullCounts: const <String, int>{},
        facetPageLoaders: nativeFacetLoaders(
          ref,
          path: '/sales/orders/finance-confirmation/pending/facets',
          fields: const ['billNo'],
          filters: {
            'rejected': _showRejected,
            'keyword': _keyword,
            'changesOnly': _changesFilter,
            'confirmed': _showConfirmed,
          },
        ),
        facetSearchScope: nativeFacetSearchScope(
          ref,
          '/sales/orders/finance-confirmation/pending/facets',
          {
            'rejected': _showRejected,
            'keyword': _keyword,
            'changesOnly': _changesFilter,
            'confirmed': _showConfirmed,
          },
        ),

        filters: <String, String?>{
          'status': _confirmationKind,
          'billNo': _columnFilters['billNo'],
        },
        // 表头排序走服务端（2026-09-25 单号列统一）。
        sortColumn: _columnFilters.sortColumn,
        sortAscending: _columnFilters.sortAscending,
        onSortChange: _onSortChange,
        onFilterChanged: (key, value) {
          if (key == 'status') {
            _filterConfirmationKind(value);
            return;
          }
          if (key == 'billNo') {
            _columnFilters.handleFilterChanged(
              key,
              value,
              onChanged: () {
                if (mounted) setState(() {});
                _load(1);
              },
            );
          }
        },
        onRowTap: _open,
        onSelectionChanged: canConfirm && _canBatchDecide
            ? null
            : (item) => setState(() => _activeItem = item),
        onSelectionCleared: canConfirm && _canBatchDecide
            ? null
            : () => setState(() => _activeItem = null),
        rowMenuBuilder: (item) => [
          UtenMenuItem(
            label: _taskDrafts(item).isEmpty ? '查看审核详情' : '继续填写审核',
            icon: Icons.open_in_new_rounded,
            onTap: () => _open(item),
          ),
        ],
        rowColor: (item) => _rowColor(theme, item),
        isLoading: _loading,
        error: result.items.isEmpty ? _error : null,
        onRetry: () => _load(_tableRows.visiblePage ?? result.page),
        emptyMessage: _emptyMessage,
        currentPage: result.page,
        totalPages: result.totalPages,
        onPageChange: _navigatePage,
        toolbarActions: canConfirm && _canBatchDecide
            ? null
            : [
                UtenButton(
                  key: const Key('sales-order-finance-open-selected'),
                  size: UtenButtonSize.large,
                  type: UtenButtonType.secondary,
                  icon: Icons.open_in_new_rounded,
                  onPressed: _activeItem == null || _batchBusy
                      ? null
                      : () => _open(_activeItem!),
                  child: const Text('查看选中详情'),
                ),
              ],
      ),
    );
  }

  List<MasterColumnDef<SalesOrderFinancePendingItem>> _columns() => [
    MasterColumnDef(
      key: 'status',
      label: '审核状态 / 原因',
      width: 188,
      value: (item) => _taskDrafts(item).isNotEmpty
          ? taskDraftStatus(_taskDrafts(item))
          : item.financeConfirmed
          ? '已批准'
          : item.financeRejected
          ? '已驳回：${item.financeRejectedReason ?? '未注明原因'}'
          : item.changeCount > 0
          ? '订单修改待确认 · ${item.changeCount} 次变更'
          // 报价转入且各行单价/折扣与财务核定的报价一致(ADR-134)：本次只核信用与条款。
          : item.sourceQuote != null && item.matchesQuote == true
          ? '待财务确认 · ${AppLocalizations.of(context).quoteFinanceOrderAllMatch}'
          : '待财务确认',
      // 状态列档位（ADR-169）：本页是财务的确认队列——待财务确认=绿
      // （「就绪可动手」，轮到我审=绿灯，与报价一致只是文案差异）；
      // 修改后待确认=橙（改过 N 次需注意前后对比）；已驳回=红（驳回需销售修订）。
      cellColor: (context, item) => utenStatusBadgeCellColor(
        item.financeConfirmed
            ? UtenStatusBadgeType.success
            : item.financeRejected
            ? UtenStatusBadgeType.danger
            : item.changeCount > 0
            ? UtenStatusBadgeType.orange
            : UtenStatusBadgeType.success,
      ),
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '销售单号',
      info: '单击选择 · 双击查看详情',
      width: 172,
      sortable: true, // 2026-09-25 单号列统一：表头排序 + 值筛选。
      value: (item) => item.billNo,
    ),
    MasterColumnDef(
      key: 'clientName',
      label: '客户',
      width: 180,
      value: (item) => item.clientName ?? '—',
    ),
    MasterColumnDef(
      key: 'sellerName',
      label: '业务员',
      width: 112,
      value: (item) => item.sellerName ?? '—',
    ),
    const MasterColumnDef(
      key: 'totalOriginal',
      label: '订单金额',
      width: 150,
      type: 'money',
      value: _orderAmount,
    ),
    // 2026-09-27 用户口径(ADR-128)：客户应收与订单同一币种，才看得出还差多少。
    MasterColumnDef(
      key: 'clientBalance',
      label: '客户应收',
      width: 170,
      type: 'money',
      info:
          '按本单币种算：客户在这个币种下还欠多少(已扣可用预收)，'
          '预收多于应收时显示「预收有余」。客户其它币种的余额和原币未核实的历史应收'
          '不换算、不相加，悬停金额可查看；红字表示全部币种应收(折本币)已超信用额度。',
      value: _clientBalanceText,
      cellBuilder: (_, item) => _ClientBalanceCell(item: item),
    ),
    MasterColumnDef(
      key: 'deliverDate',
      label: '交货日期',
      width: 120,
      type: 'date',
      value: (item) => item.deliverDate ?? '未定',
    ),
    MasterColumnDef(
      key: 'shipmentPolicy',
      label: '发运策略',
      width: 148,
      value: (item) => _shipmentPolicyLabel(item.shipmentPolicy),
    ),
    MasterColumnDef(
      key: 'urgency',
      label: '紧迫度',
      width: 104,
      value: (item) => _urgencyLabel(_urgencyFor(item)),
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '明细行',
      width: 84,
      type: 'number',
      value: (item) => '${item.itemCount}',
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '开单日期',
      width: 120,
      type: 'date',
      value: (item) => item.billDate ?? '—',
    ),
  ];

  Widget _filters(ThemeData theme) {
    final count = ref.watch(salesOrderFinanceQueueCountProvider(false));
    final changedCount = ref.watch(salesOrderFinanceQueueCountProvider(true));
    // false/true are complementary slices of the same pending predicate.
    // Sum once for the main queue; these page counts never enter global totals.
    final pendingCount =
        count.isLoading ||
            count.hasError ||
            changedCount.isLoading ||
            changedCount.hasError
        ? null
        : count.value == null || changedCount.value == null
        ? null
        : count.value! + changedCount.value!;
    // 全平台统一筛选工具条：分段 + 胶囊搜索框（窄屏自动换行）。
    // 整批提交期间不响应分段切换（原 onSelectionChanged 置空的语义收进回调守卫）。
    return UtenFilterToolbar<String>(
      segmentsKey: const Key('sales-order-finance-tabs'),
      searchKey: const Key('sales-order-finance-search'),
      compactBreakpoint: UtenBreakpoints.mediumStart,
      segments: [
        // 「待确认」= 等我放行的队列 → 红徽章。
        // 「已驳回」= 我退回去了、销售还没改回来: 既不是终态(单子还会再回到本页),
        // 也不用财务现在动手 -> 黄色进行中徽章(ADR-100 判定顺序第二问)。
        // 注意与销售自己的出货/订货列表页相反: 在那边这批单是「本人要改单重报」的活,
        // 必须红; 同一批单在两条链上各答各的问题, 不是双计。
        UtenFilterSegment(
          value: 'pending',
          label: '待确认',
          count: pendingCount,
          countForm: UtenSegmentCountForm.actionable,
        ),
        UtenFilterSegment(
          value: 'rejected',
          label: '已驳回',
          count: _rejectedCount,
          countForm: UtenSegmentCountForm.inProgress,
        ),
        const UtenFilterSegment(value: 'confirmed', label: '历史单据'),
      ],
      selected: {_state},
      onSelectionChanged: (value) {
        if (_batchBusy || _batchClaim != null) return;
        _switchTab(value);
      },
      searchHint: '搜索单号 / 客户 / 业务员',
      initialSearchValue: _keyword,
      onSearchInputChanged: _invalidateSearchRequest,
      onSearchChanged: _applyKeyword,
    );
  }

  List<FormDraft> _taskDrafts(SalesOrderFinancePendingItem item) =>
      reviewTaskDraftsFor(
        ref.read(formDraftsProvider),
        FormDraftCatalog.financeSalesOrderReview,
        item.orderId,
      );

  Color? _rowColor(ThemeData theme, SalesOrderFinancePendingItem item) {
    if (item.financeRejected) {
      return theme.colorScheme.errorContainer.withValues(alpha: 0.30);
    }
    return switch (_urgencyFor(item)) {
      _DeliverUrgency.overdue => theme.colorScheme.errorContainer.withValues(
        alpha: 0.24,
      ),
      _DeliverUrgency.soon => theme.colorScheme.tertiaryContainer.withValues(
        alpha: 0.24,
      ),
      _ => null,
    };
  }

  String get _emptyMessage {
    if (_keyword.isNotEmpty) return '没有匹配“$_keyword”的订单';
    return switch (_state) {
      'confirmed' => '没有已获财务批准的销售订单',
      'rejected' => '没有被财务驳回的销售订单',
      'pending' when _confirmationKind == 'changes' => '目前没有订单修改待确认的销售订单',
      'pending' when _confirmationKind == 'initial' => '目前没有首次待财务确认的销售订单',
      _ => '目前没有待财务确认的销售订单',
    };
  }
}

enum _DeliverUrgency { none, normal, soon, overdue }

_DeliverUrgency _urgencyFor(SalesOrderFinancePendingItem item) {
  final raw = item.deliverDate;
  if (raw == null || raw.isEmpty) return _DeliverUrgency.none;
  final date = DateTime.tryParse(raw);
  if (date == null) return _DeliverUrgency.none;
  final today = DateTime.now();
  final diff = DateTime(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime(today.year, today.month, today.day)).inDays;
  if (diff < 0) return _DeliverUrgency.overdue;
  if (diff <= 3) return _DeliverUrgency.soon;
  return _DeliverUrgency.normal;
}

String _urgencyLabel(_DeliverUrgency urgency) => switch (urgency) {
  _DeliverUrgency.overdue => '已逾期',
  _DeliverUrgency.soon => '临近交货',
  _DeliverUrgency.normal => '正常',
  _DeliverUrgency.none => '未定',
};

String _orderAmount(SalesOrderFinancePendingItem item) =>
    financeMoneyWithUnitSuffix(
      item.totalOriginal,
      currencyName: item.currencyName,
      currencyCode: item.currencyCode,
    );

/// 客户应收(ADR-128)：本单币种下还差多少，如「12000.00 美金」「预收有余 200.00 美金」。
String _clientBalanceText(SalesOrderFinancePendingItem item) =>
    item.clientBalance?.headline(PartyBalanceSide.customer) ?? '—';

/// 客户应收的补充说明：其它币种、原币未核实的历史应收、超信用；都没有时为 null。
String? _clientBalanceNote(SalesOrderFinancePendingItem item) {
  final balance = item.clientBalance;
  if (balance == null) return null;
  final parts = [
    balance.footnote(PartyBalanceSide.customer),
    if (balance.overCredit)
      '全部币种应收(折本币) ${balance.baseMoneyText(balance.openBookLocal)}'
          ' 已超信用额度 ${balance.baseMoneyText(balance.creditLimitLocal)}',
  ].whereType<String>();
  return parts.isEmpty ? null : parts.join('；');
}

/// 「客户应收」格：单行显示本单币种的数，补充说明放进提示(全站表格单行口径)。
class _ClientBalanceCell extends StatelessWidget {
  const _ClientBalanceCell({required this.item});

  final SalesOrderFinancePendingItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = _clientBalanceNote(item);
    final text = Text(
      _clientBalanceText(item),
      // 单行 + 省略号（2026-10-06 全站表格行高统一口径：读表格内内容不超过
      // 单行文本高度）；补充说明随金额悬停显示（无说明不挂提示，见表测试）。
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: item.clientBalance?.overCredit == true
          ? TextStyle(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w700,
            )
          : null,
    );
    if (note == null) return text;
    return Tooltip(message: note, child: text);
  }
}

String _shipmentPolicyLabel(String? policy) => switch (policy) {
  'ALLOW_PARTIAL' => '允许分批发货',
  'REQUIRE_COMPLETE' => '整单齐套后发货',
  'CUSTOMER_CONFIRM' => '客户确认后分批',
  'LEGACY' || null || '' => '历史未指定',
  _ => '未知策略（$policy）',
};

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.lgAll,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}
