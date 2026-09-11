import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../finance_workflow_routes.dart';
import '../models/finance_procurement_workflow.dart';
import '../providers/finance_procurement_approval_count_provider.dart';
import '../repositories/finance_procurement_workflow_repository.dart';

class FinanceProcurementApprovalTasksPage extends ConsumerStatefulWidget {
  const FinanceProcurementApprovalTasksPage({super.key});

  @override
  ConsumerState<FinanceProcurementApprovalTasksPage> createState() =>
      _FinanceProcurementApprovalTasksPageState();
}

class _FinanceProcurementApprovalTasksPageState
    extends ConsumerState<FinanceProcurementApprovalTasksPage> {
  static const int _maxBatchSize = 100;

  FinanceProcurementApprovalPage? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  /// 类型筛选卡：null = 全部待审；否则只看采购/委外。
  /// 进页面不预选（不选=不过滤），点分段后才算选中。
  FinanceProcurementOrderType? _orderType;
  bool _typeSelected = false;

  /// 按类型计数（后端全量口径）；null = 尚未返回，卡片显示 '—'。
  Map<String, int>? _typeCounts;
  String _keyword = '';
  Set<String> _selectedIds = <String>{};
  final Map<String, FinanceProcurementApprovalTask> _selectedTasksById = {};
  bool _busyDecision = false;
  TaskClaimSession? _batchClaim;

  @override
  void dispose() {
    _batchClaim?.releaseAll().ignore();
    super.dispose();
  }

  Future<TaskClaimSession?> _claimSelection(
    List<FinanceProcurementDecisionItem> commands,
    String action,
  ) async {
    final claim = financeReviewClaim(
      ProviderScope.containerOf(context, listen: false),
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
          context.appWarning(claim.failureMessage ?? '整批未取得审核占用，请重试');
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
            !review.allowedActions.contains(action)) {
          if (mounted) context.appWarning('部分订货内容、资格或占用已变化，请刷新后重新核对');
          await _releaseBatchClaim(claim);
          return null;
        }
      }
      if (mounted) setState(() => _busyDecision = false);
      return claim;
    } on Object {
      if (mounted) context.appError('无法核对整批审核内容，请检查网络或权限后重试');
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  void _selectType(FinanceProcurementOrderType? type) {
    if (_orderType == type && _typeSelected) return;
    setState(() {
      _orderType = type;
      _typeSelected = true;
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

  void _refreshCurrent() {
    setState(_clearSelectionState);
    _load(_result?.page ?? 1);
  }

  /// 当前筛选口径的提示文案：卡片内不放说明文字（与资产与待摊工作台的指标卡一致），
  /// 口径说明放卡片下方的整行提示条，点击卡片随选中态切换。
  String get _scopeHint => switch (_orderType) {
    FinanceProcurementOrderType.purchase => '显示财务审核组共享的采购订货待审任务。',
    FinanceProcurementOrderType.subcontract => '显示财务审核组共享的委外订货待审任务。',
    _ => '显示财务审核组共享的采购和委外订货待审任务。',
  };

  int? _typeCount(FinanceProcurementOrderType type) {
    final counts = _typeCounts;
    if (counts == null) return null;
    return switch (type) {
      FinanceProcurementOrderType.purchase => counts['PURCHASE'] ?? 0,
      FinanceProcurementOrderType.subcontract => counts['SUBCONTRACT'] ?? 0,
      _ => 0,
    };
  }

  Future<void> _load(int page) async {
    if (!_allowed) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(financeProcurementWorkflowRepositoryProvider);
      final result = await repo.approvalTasks(
        page: page,
        orderType: _orderType,
        keyword: _keyword.isEmpty ? null : _keyword,
      );
      // 类型计数失败不阻断列表（卡片降级为 '—'）。
      repo
          .approvalTypeCounts()
          .then((counts) {
            if (mounted) setState(() => _typeCounts = counts);
          })
          .catchError((_) {});
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        for (final task in result.items) {
          if (_selectedIds.contains(task.caseId)) {
            _selectedTasksById[task.caseId] = task;
          }
        }
      });
      ref.invalidate(financeProcurementApprovalCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
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

  Future<void> _open(FinanceProcurementApprovalTask task) async {
    // 双击/行菜单主入口 → 财务专用审核详情页（底部通过/驳回，不退回本列表即可决策）；
    // 与采购/委外业务订货详情页彻底分离（ADR-027 §五 2026-09-03 增补）。
    if (task.caseId.isEmpty) {
      context.appWarning('该任务缺少有效的审批身份，请刷新后重试');
      return;
    }
    final decided = await context.push<bool>(
      '${FinanceWorkflowRoutes.approvalTasks}/${Uri.encodeComponent(task.caseId)}',
    );
    if (decided == true && mounted) {
      // 审核详情页已办结该笔：回列表即刷新，勾选状态清空避免指向已变化任务。
      setState(_clearSelectionState);
      await _load(_result?.page ?? 1);
    }
  }

  /// 次要入口：跳共享只读订货单详情（财务想看订单全貌时用）。
  void _openSourceOrder(FinanceProcurementApprovalTask task) {
    final route = task.detailRoute;
    if (route == null) {
      context.appWarning('该任务缺少有效的订货类型或单据编号，请刷新后重试');
      return;
    }
    context.push(route);
  }

  List<FinanceProcurementApprovalTask> get _selectedTasks => [
    for (final id in _selectedIds)
      if (_selectedTasksById[id] != null) _selectedTasksById[id]!,
  ];

  bool _canSelectTask(FinanceProcurementApprovalTask task) =>
      task.decisionItem != null &&
      (task.allowedActions.contains('APPROVE') ||
          task.allowedActions.contains('REJECT'));

  void _setSelectedIds(Set<String> next) {
    if (_batchClaim != null) return;
    final currentItems =
        _result?.items ?? const <FinanceProcurementApprovalTask>[];
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
    if (tasks.any((task) => !task.allowedActions.contains(action))) {
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
        builder: (dialogContext) => AlertDialog(
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
            builder: (ctx, setDialogState) => AlertDialog(
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
                      decoration: const InputDecoration(
                        labelText: '退回原因(必填)',
                        hintText: '请写清需要制单人修改的内容',
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
          context.appWarning(claim?.failureMessage ?? '审核占用已失效，请重新核对');
        }
        return;
      }
      await action();
      if (!mounted) return;
      context.appSuccess(okMsg);
      setState(_clearSelectionState);
      ref.invalidate(financeProcurementApprovalCountProvider);
      await _load(_result?.page ?? 1);
    } on ApiException catch (e) {
      if (mounted) context.appError('整批未提交：${e.message}');
    } catch (_) {
      if (mounted) context.appError('整批未提交，请检查网络后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.financeOrderApprovalView);
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
                Padding(
                  padding: const EdgeInsets.only(right: UtenSpacing.s8),
                  child: UtenButton(
                    key: const Key('finance-approval-refresh'),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.refresh_rounded,
                    isLoading: (_loading && _result != null) || _busyDecision,
                    onPressed: _loading || _busyDecision
                        ? null
                        : _refreshCurrent,
                    child: const Text('刷新'),
                  ),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: !allowed
            ? UtenEmpty.error(
                message: '无权查看订货审批任务',
                description: '只有被授权的财务审核人员可以进入。',
              )
            : _loading && _result == null
            ? const UtenSkeletonList()
            : _error != null && _result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildList(context),
      ),
    );
  }

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
        result.items.any((task) => task.allowedActions.contains('APPROVE')) ||
        _selectedTasks.any((task) => task.allowedActions.contains('APPROVE'));
    final canReject =
        result.items.any((task) => task.allowedActions.contains('REJECT')) ||
        _selectedTasks.any((task) => task.allowedActions.contains('REJECT'));
    final selectable = canApprove || canReject;

    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AbsorbPointer(
              absorbing: _busyDecision,
              child: Opacity(
                opacity: _busyDecision ? 0.65 : 1,
                child: _buildToolbar(result),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              _InlineError(message: _error!, onRetry: () => _load(result.page)),
            ],
            if (_busyDecision) ...[
              const SizedBox(height: UtenSpacing.s8),
              const LinearProgressIndicator(
                key: Key('finance-approval-batch-progress'),
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            Expanded(
              child: AbsorbPointer(
                absorbing: _busyDecision,
                child: MasterDataTableView<FinanceProcurementApprovalTask>(
                  key: const Key('finance-approval-task-table'),
                  columns: _columns(context),
                  items: result.items,
                  facets: const {
                    'orderType': [
                      MasterFacetBucket(
                        value: 'PURCHASE',
                        count: 0,
                        label: '采购订货',
                      ),
                      MasterFacetBucket(
                        value: 'SUBCONTRACT',
                        count: 0,
                        label: '委外订货',
                      ),
                    ],
                  },
                  nullCounts: const {},
                  filters: {'orderType': _orderType?.name.toUpperCase()},
                  onFilterChanged: (key, value) {
                    if (key != 'orderType') return;
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
                  onRetry: () => _load(result.page),
                  emptyMessage: _keyword.isNotEmpty || _orderType != null
                      ? '没有匹配的待审订货单'
                      : '目前没有待审核的订货单',
                  currentPage: result.page,
                  totalPages: result.totalPages,
                  onPageChange: _load,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(FinanceProcurementApprovalPage result) {
    // 全平台统一筛选工具条：分段 + 胶囊搜索框，计数取后端全量口径。
    // 计数形态：本页整条工具条就是财务的待审队列，两个类型段都是「等我审」，
    // 挂红徽章（「全部待审」不传 count，故没有总量段与之重复）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<String>(
          segmentsKey: const Key('finance-approval-type-segments'),
          searchKey: const Key('finance-approval-search'),
          segments: [
            // 「全部待审」不挂徽章——徽章只挂各类型分段的待审数量。
            const UtenFilterSegment(value: 'all', label: '全部待审'),
            UtenFilterSegment(
              value: 'purchase',
              label: '采购订货',
              count: _typeCount(FinanceProcurementOrderType.purchase),
              countForm: UtenSegmentCountForm.actionable,
            ),
            UtenFilterSegment(
              value: 'subcontract',
              label: '委外订货',
              count: _typeCount(FinanceProcurementOrderType.subcontract),
              countForm: UtenSegmentCountForm.actionable,
            ),
          ],
          selected: _typeSelected
              ? {
                  _orderType == null
                      ? 'all'
                      : _orderType == FinanceProcurementOrderType.purchase
                      ? 'purchase'
                      : 'subcontract',
                }
              : const {},
          onSelectionChanged: (value) => _selectType(switch (value) {
            'purchase' => FinanceProcurementOrderType.purchase,
            'subcontract' => FinanceProcurementOrderType.subcontract,
            _ => null,
          }),
          searchHint: '搜索订货单号 / 供应商 / 提交人',
          initialSearchValue: _keyword,
          onSearchInputChanged: (_) => _requestVersion++,
          onSearchChanged: _applyKeyword,
          trailing: Builder(
            builder: (context) {
              final compact = MediaQuery.sizeOf(context).width < 840;
              return Text(
                compact
                    ? '单击选择，双击或长按打开审核详情'
                    : '共 ${result.total} 笔 · 单击选择，双击打开审核详情',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                _scopeHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<MasterColumnDef<FinanceProcurementApprovalTask>> _columns(
    BuildContext context,
  ) => [
    MasterColumnDef(
      key: 'orderType',
      label: '订货类型',
      width: 110,
      value: (task) => task.orderTypeLabel,
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '订货单号',
      width: 170,
      value: (task) => task.billNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 210,
      value: (task) => task.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'amount',
      label: '本币金额',
      width: 130,
      type: 'money',
      value: (task) => task.amount,
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
    // 批准后改量（2026-09-05）：改过数量的任务显示浅黄底徽标，
    // 提醒财务在审核详情先看「修改清单」（照销售确认列表样式）。
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 200,
      value: (task) => task.changeCount > 0
          ? AppLocalizations.of(
              context,
            ).procurementApprovalStatusChanged(task.changeCount)
          : AppLocalizations.of(context).procurementApprovalStatusPending,
      cellColor: (context, task) => task.changeCount > 0
          ? (Theme.of(context).brightness == Brightness.dark
                ? UtenColors.warning.withValues(alpha: 0.18)
                : UtenColors.warningBg)
          : null,
    ),
  ];

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final canApprove =
        (_result?.items.any(
              (task) => task.allowedActions.contains('APPROVE'),
            ) ??
            false) ||
        _selectedTasks.any((task) => task.allowedActions.contains('APPROVE'));
    final canReject =
        (_result?.items.any((task) => task.allowedActions.contains('REJECT')) ??
            false) ||
        _selectedTasks.any((task) => task.allowedActions.contains('REJECT'));
    final approveIssue = _selectionIssue('APPROVE');
    final rejectIssue = _selectionIssue('REJECT');
    return [
      if (canReject)
        UtenButton(
          key: const Key('finance-approval-batch-reject'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.reply_rounded,
          isLoading: _busyDecision,
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
          isLoading: _busyDecision,
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
