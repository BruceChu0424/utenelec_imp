import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:async';
import '../../../shared/auth/native_read_view_scope_mixin.dart'
    show nativeReadAccessDenied;
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/paging/paged_query_identity.dart';

import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/master_server_column_filters.dart';
import '../finance_workflow_routes.dart';
import '../models/finance_procurement_workflow.dart';
import '../repositories/finance_procurement_workflow_repository.dart';
import '../../../shared/drafts/review_task_draft.dart';
import '../../../shared/badges/badge_registry.dart';

/// 订货审批任务中心（采购/委外订货的财务审核队列）。
///
/// [embedded]：嵌入「业务审核中心」分段时为 true——去掉本页 AppBar 与内容
/// 容器（外层提供标题/刷新/容器）；[refreshTick] 由外层刷新信号递增触发重拉。
class FinanceProcurementApprovalTasksPage extends ConsumerStatefulWidget {
  const FinanceProcurementApprovalTasksPage({
    super.key,
    this.embedded = false,
    this.externalHeader,
    this.refreshTick = 0,
    this.refreshCompletion,
    this.initialStatus,
  });

  final bool embedded;

  /// 宿主（业务审核中心）的大类行：挂进本页折叠头，随页一起滚走
  /// （2026-09-24 用户口径「表格滑到顶」，置顶后只剩表格自身工具条）。
  final Widget? externalHeader;

  /// 外层（业务审核中心）触发的刷新信号；数值变化时重拉当前页。
  final int refreshTick;
  final Completer<void>? refreshCompletion;
  final String? initialStatus;

  @override
  ConsumerState<FinanceProcurementApprovalTasksPage> createState() =>
      _FinanceProcurementApprovalTasksPageState();
}

class _FinanceProcurementApprovalTasksPageState
    extends ConsumerState<FinanceProcurementApprovalTasksPage>
    with ScopedPagedReadViewMixin<FinanceProcurementApprovalTasksPage> {
  static const int _maxBatchSize = 100;

  FinanceProcurementApprovalPage? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  int _ownerGeneration = 0;
  int? _readerEpoch;
  Map<String, dynamic>? _acceptedQuery;

  /// 类型筛选由状态表头承接；null = 同时展示采购和委外。
  FinanceProcurementOrderType? _orderType;

  String _keyword = '';
  String _status = 'PENDING';

  /// 表头排序 + 订货单号列值筛选 + facets 桶 + 防串台代数
  /// （2026-09-25 单号列统一，共享状态见 MasterServerColumnFilters）；
  /// 排序列 key 见 [_kSortFields]，null = 服务端默认序。
  final _columnFilters = MasterServerColumnFilters();
  final _tableRows =
      MasterDataTableRowsController<FinanceProcurementApprovalTask>();
  Set<String> _selectedIds = <String>{};
  final Map<String, FinanceProcurementApprovalTask> _selectedTasksById = {};
  bool _busyDecision = false;
  TaskClaimSession? _batchClaim;

  @override
  void dispose() {
    final completion = widget.refreshCompletion;
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
    _batchClaim?.releaseAll().ignore();
    super.dispose();
  }

  Future<TaskClaimSession?> _claimSelection(
    List<FinanceProcurementDecisionItem> commands,
    String action,
  ) async {
    final claim = financeReviewClaim(
      ProviderScope.containerOf(context, listen: false),
      localizations: AppLocalizations.of(context),
    );
    _batchClaim = claim;
    setState(() => _busyDecision = true);
    try {
      await claim.claimAll(
        'PROCUREMENT_FINANCE_APPROVE',
        commands.map((command) => command.caseId),
      );
      if (!mounted || !claim.isReady) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '整批还没有认领成功，请重试');
        }
        await _releaseBatchClaim(claim);
        return null;
      }
      for (final command in commands) {
        final review = await ref
            .read(financeProcurementWorkflowRepositoryProvider)
            .review(command.caseId);
        if (!mounted ||
            !claim.isReady ||
            review.version != command.expectedVersion ||
            !review.isPending ||
            review.isClosureRequest ||
            review.isOrderClosed ||
            !review.allowedActions.contains(action)) {
          if (mounted) context.appWarning('部分订货内容、资格或认领已变化，请刷新后重新核对');
          await _releaseBatchClaim(claim);
          return null;
        }
      }
      if (mounted) setState(() => _busyDecision = false);
      return claim;
    } on Object catch (error) {
      if (mounted) {
        context.appApiError(
          error,
          fallback: AppLocalizations.of(context).financeBatchReviewCheckFailed,
        );
      }
      await _releaseBatchClaim(claim);
      return null;
    }
  }

  Future<void> _releaseBatchClaim(TaskClaimSession claim) async {
    await claim.releaseAll();
    if (identical(_batchClaim, claim)) _batchClaim = null;
    if (mounted) setState(() => _busyDecision = false);
  }

  bool get _allowed {
    return ref.read(isSuperAdminProvider) ||
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.financeOrderApprovalView);
  }

  @override
  void initState() {
    super.initState();
    _readerEpoch = ref.read(exportContextEpochProvider);
    _status =
        const {
          'PENDING',
          'CLOSURE_PENDING',
          'APPROVED',
          'REJECTED',
          'ALL',
        }.contains(widget.initialStatus)
        ? widget.initialStatus!
        : 'PENDING';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final completion = widget.refreshCompletion;
      _load(1).whenComplete(() {
        if (completion != null && !completion.isCompleted) {
          completion.complete();
        }
      });
    });
  }

  @override
  void didUpdateWidget(FinanceProcurementApprovalTasksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStatus != oldWidget.initialStatus) {
      _selectStatus(
        const {
              'PENDING',
              'CLOSURE_PENDING',
              'APPROVED',
              'REJECTED',
              'ALL',
            }.contains(widget.initialStatus)
            ? widget.initialStatus!
            : 'PENDING',
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

  void _selectType(FinanceProcurementOrderType? type) {
    if (_busyDecision || _orderType == type) return;
    setState(() {
      _orderType = type;
      _result = null;
      ++_columnFilters.generation;
      _clearSelectionState();
    });
    _load(1);
  }

  void _selectStatus(String status) {
    if (_busyDecision || _status == status) return;
    ++_requestVersion;
    setState(() {
      _status = status;
      _result = null;
      ++_columnFilters.generation;
      _columnFilters.reset();
      _clearSelectionState();
    });
    _load(1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (_keyword == normalized) return;
    setState(() {
      _keyword = normalized;
      _clearSelectionState();
    });
    _load(1);
  }

  void _clearSelectionState() {
    _selectedIds = <String>{};
    _selectedTasksById.clear();
  }

  Future<void> _refreshCurrent() async {
    setState(_clearSelectionState);
    await _load(_tableRows.visiblePage ?? _result?.page ?? 1);
  }

  @override
  void scopedPagedReadOwnerChanged() {
    final epoch = ref.read(exportContextEpochProvider);
    final changedOwner = _readerEpoch != epoch;
    _readerEpoch = epoch;
    ++_ownerGeneration;
    ++_requestVersion;
    if (!mounted) return;
    setState(() {
      _result = null;
      _acceptedQuery = null;
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
            _allowed &&
            epoch == ref.read(exportContextEpochProvider)) {
          _load(1);
        }
      });
    }
  }

  Map<String, dynamic> get _cacheQuery => {
    'owner': ref.read(exportContextEpochProvider),
    'repository': ref.read(financeProcurementWorkflowRepositoryProvider),
    'keyword': _keyword,
    'orderType': _orderType,
    'status': _status,
    'columns': Map.of(_columnFilters.values),
    'sort': _columnFilters.sortColumn,
    'ascending': _columnFilters.sortAscending,
  };

  Future<void> _navigatePage(int page) => _load(page, useCache: true);

  Future<void> _load(int page, {bool useCache = false}) async {
    final cacheQuery = _cacheQuery;
    final repo = ref.read(financeProcurementWorkflowRepositoryProvider);
    final orderType = _orderType;
    final status = _status;
    final keyword = _keyword.isEmpty ? null : _keyword;
    final sort = _kSortFields[_columnFilters.sortColumn];
    final order = _columnFilters.sortColumn == null
        ? null
        : (_columnFilters.sortAscending ? 'asc' : 'desc');
    final billNo = _columnFilters['billNo'];

    if (!_allowed) return;
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
    try {
      final cachedPage = await readScopedPage<FinanceProcurementApprovalTask>(
        page,
        query: cacheQuery,
        currentQuery: () => _cacheQuery,
        useCache: useCache,
        fetchPage: (target) async {
          final response = await repo.approvalTasks(
            page: target,
            orderType: orderType,
            keyword: keyword,
            sort: sort,
            order: order,
            billNo: billNo,
            status: status,
          );
          return PagedReadSnapshot<
            FinanceProcurementApprovalTask,
            FinanceProcurementApprovalPage
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
                    FinanceProcurementApprovalTask,
                    FinanceProcurementApprovalPage
                  >)
              .snapshot;
      if (!mounted || requestVersion != _requestVersion) return;
      // 单号 facets 与列表同口径（2026-09-25 单号列统一）；失败静默（下拉降级为空）。
      unawaited(_loadBillNoFacets());
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _acceptedQuery = cacheQuery;
        _loading = false;
        for (final task in result.items) {
          if (_selectedIds.contains(task.caseId)) {
            _selectedTasksById[task.caseId] = task;
          }
        }
      });
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) {
        return;
      }
      if (nativeReadAccessDenied(error)) invalidateScopedPageReads();
      setState(() {
        if (nativeReadAccessDenied(error)) {
          _result = null;
          _acceptedQuery = null;
          _columnFilters.reset();
          _clearSelectionState();
        }
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '待审任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 表头排序键 → 服务端 sort 参数（2026-09-25 单号列统一；未列出的列不可排序）。
  static const _kSortFields = <String, String>{'billNo': 'billNo'};

  /// 表头排序变化：服务端重排整个结果集，回第 1 页（勾选清空防指向已变化任务）。
  void _onSortChange(String? column, bool ascending) {
    if (_busyDecision) return;
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
        if (mounted) setState(_clearSelectionState);
        _load(1);
      },
    );
  }

  /// 订货单号 facets（2026-09-25 单号列统一）：与列表同过滤口径
  /// （不含单号列自身值筛选）。
  Future<void> _loadBillNoFacets() => _columnFilters.loadFacets(
    () async => {
      'billNo': await ref
          .read(financeProcurementWorkflowRepositoryProvider)
          .approvalBillNoFacets(
            orderType: _orderType,
            keyword: _keyword.isEmpty ? null : _keyword,
            status: _status,
          ),
    },
    onLoaded: () {
      if (mounted) setState(() {});
    },
  );

  Future<void> _open(FinanceProcurementApprovalTask task) async {
    final owner = _ownerGeneration;
    final drafts = _taskDrafts(task);
    if (drafts.isNotEmpty) {
      await resumeTaskFormDraft(context, ref, drafts);
      if (mounted && owner == _ownerGeneration) await _refreshCurrent();
      return;
    }
    // 双击/行菜单主入口 → 财务专用审核详情页（底部通过/驳回，不退回本列表即可决策）；
    // 与采购/委外业务订货详情页彻底分离（ADR-027 §五 2026-09-03 增补）。
    if (task.caseId.isEmpty) {
      context.appWarning('这条任务的审批编号缺失，请刷新后重试');
      return;
    }
    await context.push<bool>(
      '${FinanceWorkflowRoutes.approvalTasks}/${Uri.encodeComponent(task.caseId)}',
    );
    if (mounted && owner == _ownerGeneration) {
      // A different reviewer may have decided while this user only inspected
      // the case. Every real return revalidates the authorized server queue.
      await _refreshCurrent();
    }
  }

  /// 次要入口：跳共享只读订货单详情（财务想看订单全貌时用）。
  Future<void> _openSourceOrder(FinanceProcurementApprovalTask task) async {
    final route = task.detailRoute;
    if (route == null) {
      context.appWarning('该任务缺少有效的订货类型或单据编号，请刷新后重试');
      return;
    }
    final owner = _ownerGeneration;
    await context.push(route);
    if (mounted && owner == _ownerGeneration) await _refreshCurrent();
  }

  List<FinanceProcurementApprovalTask> get _selectedTasks => [
    for (final id in _selectedIds)
      if (_selectedTasksById[id] != null) _selectedTasksById[id]!,
  ];

  bool _allowsTaskAction(FinanceProcurementApprovalTask task, String action) =>
      !task.isClosureRequest && task.allowedActions.contains(action);

  bool _canSelectTask(FinanceProcurementApprovalTask task) =>
      !task.isClosureRequest &&
      _taskDrafts(task).isEmpty &&
      task.decisionItem != null &&
      (_allowsTaskAction(task, 'APPROVE') || _allowsTaskAction(task, 'REJECT'));

  List<FormDraft> _taskDrafts(FinanceProcurementApprovalTask task) =>
      reviewTaskDraftsFor(
        ref.read(formDraftsProvider),
        FormDraftCatalog.financeProcurementReview,
        task.caseId,
      );

  void _setSelectedIds(Set<String> next) {
    if (_batchClaim != null) return;
    final currentItems = _tableRows.items;
    final capped = next.length > _maxBatchSize;
    final normalized = capped ? next.take(_maxBatchSize).toSet() : next;
    setState(() {
      _selectedIds = normalized;
      _selectedTasksById.removeWhere((id, _) => !normalized.contains(id));
      for (final task in currentItems) {
        if (normalized.contains(task.caseId)) {
          _selectedTasksById[task.caseId] = task;
        }
      }
    });
    if (capped) {
      context.appWarning('单次最多处理 $_maxBatchSize 笔，已保留前 $_maxBatchSize 笔');
    }
  }

  String? _selectionIssue(String action) {
    if (_selectedIds.isEmpty) return '请先选择待审订货单';
    final tasks = _selectedTasks;
    if (tasks.length != _selectedIds.length ||
        tasks.any((task) => task.decisionItem == null)) {
      return '部分任务已变化，请刷新后重新选择';
    }
    if (tasks.any((task) => !_allowsTaskAction(task, action))) {
      return action == 'APPROVE'
          ? '所选任务中有不可通过的订货单，请调整选择'
          : '所选任务中有不可驳回的订货单，请调整选择';
    }
    return null;
  }

  List<FinanceProcurementDecisionItem> get _selectedCommands => [
    for (final task in _selectedTasks) task.decisionItem!,
  ];

  String _selectedBillSummary() {
    final tasks = _selectedTasks;
    final visible = tasks.take(5).map((task) => task.billNo).join('、');
    return tasks.length > 5 ? '$visible 等 ${tasks.length} 笔' : visible;
  }

  Future<void> _approveSelected() async {
    if (_busyDecision || _batchClaim != null) return;
    final issue = _selectionIssue('APPROVE');
    if (issue != null) {
      context.appWarning(issue);
      return;
    }
    final count = _selectedIds.length;
    final commands = _selectedCommands;
    final summary = _selectedBillSummary();
    final claim = await _claimSelection(commands, 'APPROVE');
    if (claim == null || !mounted) return;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => UtenAlertDialog(
          title: Text('批量通过($count 笔)'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const UtenReviewerResponsibilityNotice(
                  actionLabel: '批量订货财务审核',
                  description: '确认后，系统将以此登录员工记录整批订货财务审核责任。',
                ),
                const SizedBox(height: 12),
                Text('$summary。整批通过后订货立即生效，并分别生成仓库预计到货任务。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FinanceReviewClaimButton(
              claim: claim,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认批量通过'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _runBatchAction(
        () => ref
            .read(financeProcurementWorkflowRepositoryProvider)
            .approveOrdersBatch([
              for (final command in commands)
                command.withClaimId(
                  claim.claimIdFor(
                    'PROCUREMENT_FINANCE_APPROVE',
                    command.caseId,
                  )!,
                ),
            ]),
        '已批量通过 $count 笔订货审批',
      );
    } finally {
      await _releaseBatchClaim(claim);
    }
  }

  Future<void> _rejectSelected() async {
    if (_busyDecision || _batchClaim != null) return;
    final issue = _selectionIssue('REJECT');
    if (issue != null) {
      context.appWarning(issue);
      return;
    }
    final count = _selectedIds.length;
    final commands = _selectedCommands;
    final claim = await _claimSelection(commands, 'REJECT');
    if (claim == null || !mounted) return;
    try {
      final reason = await showDialog<String>(
        context: context,
        builder: (ctx) {
          var value = '';
          return StatefulBuilder(
            builder: (ctx, setDialogState) => UtenAlertDialog(
              title: Text('批量驳回($count 笔)'),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const UtenReviewerResponsibilityNotice(
                      actionLabel: '批量驳回订货财务审核',
                      description: '确认后，系统将以此登录员工记录整批退回责任。',
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Text('${_selectedBillSummary()}将使用同一个驳回原因，整批原子提交。'),
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      autofocus: true,
                      minLines: 3,
                      maxLines: 5,
                      maxLength: 1000,
                      onChanged: (v) => setDialogState(() => value = v.trim()),
                      decoration: const UtenInputDecoration(
                        InputDecoration(
                          labelText: '退回原因(必填)',
                          hintText: '请写清需要制单人修改的内容',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FinanceReviewClaimButton(
                  claim: claim,
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  ),
                  onPressed: value.isEmpty
                      ? null
                      : () => Navigator.pop(ctx, value),
                  child: const Text('确认批量驳回'),
                ),
              ],
            ),
          );
        },
      );
      if (reason == null || reason.isEmpty || !mounted) return;
      await _runBatchAction(
        () => ref
            .read(financeProcurementWorkflowRepositoryProvider)
            .rejectOrdersBatch([
              for (final command in commands)
                command.withClaimId(
                  claim.claimIdFor(
                    'PROCUREMENT_FINANCE_APPROVE',
                    command.caseId,
                  )!,
                ),
            ], reason),
        '已批量驳回 $count 笔订货审批',
      );
    } finally {
      await _releaseBatchClaim(claim);
    }
  }

  Future<void> _runBatchAction(
    Future<Object?> Function() action,
    String okMsg,
  ) async {
    setState(() => _busyDecision = true);
    try {
      final claim = _batchClaim;
      if (claim == null || !await claim.validateForDecision() || !mounted) {
        if (mounted) {
          context.appWarning(claim?.failureMessage ?? '审核认领已失效，请重新核对');
        }
        return;
      }
      await action();
      if (!mounted) return;
      context.appSuccess(okMsg);
      setState(_clearSelectionState);
      refreshBadges(ref);
      await _load(_tableRows.visiblePage ?? _result?.page ?? 1);
    } on Object catch (error) {
      if (mounted) {
        context.appApiError(
          error,
          fallback: AppLocalizations.of(
            context,
          ).financeBatchReviewResultUnknown,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(formDraftsProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.financeOrderApprovalView);
    final Widget main;
    if (!allowed) {
      main = _pinHostHeader(
        UtenEmpty.error(
          message: '无权查看订货审批任务',
          description: AppLocalizations.of(
            context,
          ).financeProcurementReviewAccessHint,
        ),
      );
    } else {
      main = _buildList(context);
    }
    final body = SafeArea(
      child: Stack(
        children: [
          main,
          // 批量审批提交期间的全屏居中遮罩（2026-09-25 统一口径：点按钮跑
          // 网络一律 UtenBusyOverlay，弃折叠头里的 LinearProgressIndicator）。
          if (_busyDecision)
            const Positioned.fill(
              child: UtenBusyOverlay(title: '正在处理批量审批，请稍候'),
            ),
        ],
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: UtenAppBar(
        title: '订货审批任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(
            context,
            defaultPath: FinanceWorkflowRoutes.approvalTasks.replaceFirst(
              '/procurement-approvals',
              '',
            ),
          ),
        ),
        actions: allowed
            ? [
                UtenAppBarActionButton(
                  key: const Key('finance-approval-refresh'),
                  label: '刷新',
                  icon: Icons.refresh_rounded,
                  isLoading: _loading,
                  onPressed: _loading || _busyDecision ? null : _refreshCurrent,
                ),
              ]
            : null,
      ),
      body: body,
    );
  }

  /// 骨架/错误/无权态钉住宿主分类栏：分类栏在、内容区给 [child]（数据到位后由
  /// [_buildList] 接管，分类栏随页滚走）。2026-10-01 用户口径：点击子分类的
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

  Widget _buildList(BuildContext context) {
    final result =
        _result ??
        const FinanceProcurementApprovalPage(
          items: <FinanceProcurementApprovalTask>[],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    final canApprove =
        result.items.any((task) => _allowsTaskAction(task, 'APPROVE')) ||
        _selectedTasks.any((task) => _allowsTaskAction(task, 'APPROVE'));
    final canReject =
        result.items.any((task) => _allowsTaskAction(task, 'REJECT')) ||
        _selectedTasks.any((task) => _allowsTaskAction(task, 'REJECT'));
    final selectable =
        (_status == 'PENDING' || _status == 'CLOSURE_PENDING') &&
        (canApprove || canReject);

    // 2026-09-24 对齐物料分析页口径：工具条/提示行进折叠头（上滑先收走，
    // 表头顶到头再表内滚），body 只剩表格；独立页与业务审核中心嵌入态同款。
    final content = UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 宿主大类行随页滚走（2026-09-24「表格滑到顶」）。
          if (widget.externalHeader != null) ...[
            widget.externalHeader!,
            const SizedBox(height: UtenFilterRow.rowGap),
          ],
          _buildToolbar(),
          if (!widget.embedded)
            const TaskDraftRecoveryNotice(
              scope: FormDraftCategoryScope(
                module: BadgeModule.finance,
                routePrefix: '/finance/procurement-approvals/',
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
      body: MasterDataTableView<FinanceProcurementApprovalTask>(
        expensiveRowMounts: false,
        rowsController: _tableRows,
        paginationRevision: _result,
        paginationScope: (
          _keyword,
          _orderType,
          _status,
          _columnFilters['billNo'],
        ),
        tableKey:
            'features.finance.pages.finance_procurement_approval_tasks_page.FinanceProcurementApprovalTasksPageState._buildList.1',
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        key: const Key('finance-approval-task-table'),
        columns: _columns(context),
        items: result.items,
        facets: {
          'status': [
            MasterFacetBucket(
              value: 'PURCHASE',
              count: 0,
              label: _typeStatusLabel('采购'),
            ),
            MasterFacetBucket(
              value: 'SUBCONTRACT',
              count: 0,
              label: _typeStatusLabel('委外'),
            ),
          ],
          // 订货单号表头值筛选（2026-09-25 单号列统一）：服务端分组计数桶。
          'billNo': _columnFilters.bucketOf('billNo'),
        },
        nullCounts: const {},
        filters: {
          'status': _orderType?.name.toUpperCase(),
          'billNo': _columnFilters['billNo'],
        },
        // 表头排序走服务端（2026-09-25 单号列统一）。
        sortColumn: _columnFilters.sortColumn,
        sortAscending: _columnFilters.sortAscending,
        onSortChange: _onSortChange,
        onFilterChanged: (key, value) {
          if (_busyDecision) return;
          if (key == 'billNo') {
            // 订货单号值筛选（2026-09-25 单号列统一）：服务端精确匹配。
            _columnFilters.handleFilterChanged(
              key,
              value,
              onChanged: () {
                if (mounted) setState(_clearSelectionState);
                _load(1);
              },
            );
            return;
          }
          if (key != 'status') return;
          _selectType(switch (value) {
            'PURCHASE' => FinanceProcurementOrderType.purchase,
            'SUBCONTRACT' => FinanceProcurementOrderType.subcontract,
            _ => null,
          });
        },
        selectable: selectable,
        idOf: (task) => _canSelectTask(task) ? task.caseId : null,
        selectedIds: _selectedIds,
        onSelectedIdsChanged: _setSelectedIds,
        batchActionsBuilder: selectable ? _batchActions : null,
        onRowTap: _open,
        canOpenRow: (task) => task.canOpen,
        rowMenuBuilder: (task) => [
          UtenMenuItem(
            label: '打开审核详情',
            icon: Icons.fact_check_outlined,
            onTap: () => _open(task),
          ),
          if (task.detailRoute != null)
            UtenMenuItem(
              label: '查看原订货单详情',
              icon: Icons.open_in_new_rounded,
              onTap: () => _openSourceOrder(task),
            ),
        ],
        canShowRowMenu: (task) => task.canOpen,
        isLoading: _loading,
        loadingMore: _loading && _result != null,
        error: result.items.isEmpty ? _error : null,
        onRetry: () => _load(_tableRows.visiblePage ?? result.page),
        emptyMessage: _keyword.isNotEmpty || _orderType != null
            ? '没有匹配的待审订货单'
            : '目前没有待审核的订货单',
        currentPage: result.page,
        totalPages: result.totalPages,
        onPageChange: _navigatePage,
      ),
    );
    // 嵌入形态不复套容器与内边距（业务审核中心已提供），避免双重 gutter。
    if (widget.embedded) return content;
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: content,
      ),
    );
  }

  String _typeStatusLabel(String type) => switch (_status) {
    'PENDING' => '$type待审批',
    'APPROVED' => '$type已生效',
    'REJECTED' => '$type已驳回',
    _ => '$type订货',
  };

  String _taskStatusLabel(FinanceProcurementApprovalTask task) {
    final type = switch (task.orderType) {
      FinanceProcurementOrderType.purchase => '采购',
      FinanceProcurementOrderType.subcontract => '委外',
      FinanceProcurementOrderType.unknown => '未知类型',
    };
    final drafts = _taskDrafts(task);
    if (drafts.isNotEmpty) return '$type · ${taskDraftStatus(drafts)}';
    if (task.isClosureRequest) {
      final l10n = AppLocalizations.of(context);
      if (task.isDirectClosure && task.status == 'APPROVED') {
        return '$type · ${l10n.orderClosureDirectEnded}';
      }
      return '$type · ${switch (task.status) {
        'APPROVED' => l10n.orderClosureApproved,
        'REJECTED' => l10n.orderClosureRejected,
        null || 'PENDING' => l10n.orderClosurePending,
        _ => task.status ?? '',
      }}';
    }
    return switch (task.status) {
      'APPROVED' => '$type已批准',
      'REJECTED' => '$type已驳回',
      'CANCELED' => '$type已撤回',
      'SUPERSEDED' => '$type · 已被新一轮替代',
      null || 'PENDING' =>
        task.changeCount > 0
            ? '$type · ${AppLocalizations.of(context).procurementApprovalStatusChanged(task.changeCount)}'
            : (task.attempt ?? 1) > 1
            ? '$type · 重新提交待审批'
            : '$type待审批',
      _ => '$type · 未知审批状态',
    };
  }

  UtenStatusBadgeType _taskStatusType(FinanceProcurementApprovalTask task) {
    if (_taskDrafts(task).isNotEmpty) return UtenStatusBadgeType.neutral;
    return switch (task.status) {
      'REJECTED' => UtenStatusBadgeType.danger,
      'APPROVED' => UtenStatusBadgeType.success,
      null || 'PENDING' =>
        task.isClosureRequest || task.changeCount > 0 || (task.attempt ?? 1) > 1
            ? UtenStatusBadgeType.orange
            : task.orderType == FinanceProcurementOrderType.purchase
            ? UtenStatusBadgeType.success
            : task.orderType == FinanceProcurementOrderType.subcontract
            ? UtenStatusBadgeType.accent
            : UtenStatusBadgeType.neutral,
      _ => UtenStatusBadgeType.neutral,
    };
  }

  Widget _buildToolbar() {
    final history = _status == 'ALL' || _status == 'APPROVED';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<String>(
          enabled: !_busyDecision,
          segmentsKey: const Key('finance-approval-status-segments'),
          searchKey: const Key('finance-approval-search'),
          segments: [
            UtenFilterSegment(
              value: 'PENDING',
              label: '待审批',
              count: ref.watch(
                badgeFactOrNullProvider(BadgeFact.procurementApproval),
              ),
              countForm: UtenSegmentCountForm.actionable,
            ),
            const UtenFilterSegment(value: 'CLOSURE_PENDING', label: '历史结束申请'),
            const UtenFilterSegment(
              value: 'REJECTED',
              label: '已驳回',
              countForm: UtenSegmentCountForm.inProgress,
            ),
            const UtenFilterSegment(value: 'ALL', label: '历史单据'),
          ],
          selected: {history ? 'ALL' : _status},
          onSelectionChanged: _selectStatus,
          searchHint: '搜索订货单号 / 供应商 / 提交人',
          initialSearchValue: _keyword,
          onSearchInputChanged: (_) => _requestVersion++,
          onSearchChanged: _applyKeyword,
        ),
        if (history) ...[
          const SizedBox(height: UtenSpacing.s8),
          UtenFilterToolbar<String>(
            autoSelectBadge: false,
            segments: const [
              UtenFilterSegment(value: 'ALL', label: '全部记录'),
              UtenFilterSegment(value: 'APPROVED', label: '已生效'),
            ],
            selected: {_status},
            onSelectionChanged: _selectStatus,
          ),
        ],
      ],
    );
  }

  List<MasterColumnDef<FinanceProcurementApprovalTask>> _columns(
    BuildContext context,
  ) => [
    // 批准后改量（2026-09-05）：改过数量的任务显示橙色档，
    // 改量与退回重提都提示财务查看审核详情中的整行前后对比。
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 180,
      value: (task) => _taskStatusLabel(task),
      // 类型不冒充风险；正常采购待审用绿、委外待审用青区分，
      // 修改/重提仍是橙色提示，已驳回用红、退出队列用中性灰。
      cellColor: (context, task) =>
          utenStatusBadgeCellColor(_taskStatusType(task)),
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '订货单号',
      width: 170,
      sortable: true, // 2026-09-25 单号列统一：表头排序 + 值筛选。
      value: (task) => task.billNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 210,
      value: (task) => task.supplierName ?? '—',
    ),
    // 2026-10-10 中心列对齐详情页口径：明细行数/超收损耗%/汇率直接进中心表格，
    // 批量通过不必再逐笔进详情页核对（金额链三列红字强调）；仓库/货品只进详情页。
    MasterColumnDef(
      key: 'lineCount',
      label: '明细行数',
      width: 84,
      type: 'count',
      value: (task) =>
          (task.lineCount ?? 0) > 0 ? task.lineCount.toString() : '—',
    ),
    MasterColumnDef(
      key: 'tolerance',
      label: '允许超收 / 损耗',
      width: 120,
      type: 'number',
      info: '采购=允许超收%、委外=允许损耗%（全部行未填显示「不允许」；多行不同值显示区间）。',
      emphasized: true,
      value: (task) => task.toleranceText ?? '不允许',
    ),
    // ADR-128：订货金额按订货币种金额后自动带单位（2026-10-10 后缀口径），
    // 折合人民币另列；金额链（金额/汇率/折合）红字加粗逐行核对。
    MasterColumnDef(
      key: 'totalOriginal',
      label: '订货金额',
      width: 160,
      type: 'money',
      emphasized: true,
      value: (task) => financeMoneyWithUnitSuffix(
        task.totalOriginal,
        currencyName: task.currencyName,
      ),
    ),
    // 待审 case 的缺省折算汇率（已批→快照→1 缺省链的快照档）：批量通过不填
    // 汇率时即按它折算。
    MasterColumnDef(
      key: 'exchangeRate',
      label: '汇率',
      width: 80,
      type: 'number',
      emphasized: true,
      info: '提交快照里的订单表头汇率；批量通过未单独填汇率时按它折算（详情页「汇率」列可改）。',
      value: (task) => financeExactTrimmed(task.exchangeRate) ?? '—',
    ),
    MasterColumnDef(
      key: 'amount',
      label: '折合人民币',
      width: 140,
      type: 'money',
      emphasized: true,
      value: (task) => financeLocalMoneyWithUnitSuffix(task.amount),
    ),
    MasterColumnDef(
      key: 'expectedDate',
      label: '预计到货日',
      width: 120,
      type: 'date',
      value: (task) => task.expectedDate ?? '—',
    ),
    MasterColumnDef(
      key: 'submittedByName',
      label: '提交人',
      width: 140,
      value: (task) => task.submittedByName ?? '—',
    ),
    MasterColumnDef(
      key: 'submittedAt',
      label: '提交时间',
      width: 180,
      type: 'date',
      value: (task) => DisplayDateTime.beijing(
        task.submittedAt,
        fallback: task.submittedAt ?? '—',
      ),
    ),
    MasterColumnDef(
      key: 'attempt',
      label: '审批轮次',
      width: 100,
      type: 'number',
      value: (task) => task.attempt?.toString() ?? '—',
    ),
  ];

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final canApprove =
        (_result?.items.any((task) => _allowsTaskAction(task, 'APPROVE')) ??
            false) ||
        _selectedTasks.any((task) => _allowsTaskAction(task, 'APPROVE'));
    final canReject =
        (_result?.items.any((task) => _allowsTaskAction(task, 'REJECT')) ??
            false) ||
        _selectedTasks.any((task) => _allowsTaskAction(task, 'REJECT'));
    final approveIssue = _selectionIssue('APPROVE');
    final rejectIssue = _selectionIssue('REJECT');
    return [
      if (canReject)
        UtenButton(
          key: const Key('finance-approval-batch-reject'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.reply_rounded,
          onPressed: rejectIssue == null && !_busyDecision
              ? _rejectSelected
              : null,
          onDisabledTap: rejectIssue == null
              ? null
              : () => context.appWarning(rejectIssue),
          child: Text('批量驳回(${selectedIds.length})'),
        ),
      if (canApprove)
        UtenButton(
          key: const Key('finance-approval-batch-approve'),
          type: UtenButtonType.success,
          size: UtenButtonSize.large,
          icon: Icons.check_circle_outline_rounded,
          onPressed: approveIssue == null && !_busyDecision
              ? _approveSelected
              : null,
          onDisabledTap: approveIssue == null
              ? null
              : () => context.appWarning(approveIssue),
          child: Text('批量通过(${selectedIds.length})'),
        ),
    ];
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(message)),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            size: UtenButtonSize.large,
            type: UtenButtonType.tonal,
            icon: Icons.refresh_rounded,
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
