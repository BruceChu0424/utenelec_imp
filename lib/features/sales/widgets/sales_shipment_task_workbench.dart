import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/providers/sales_shipment_finance_count_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/models/client_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import 'shipment_finance_change_summary.dart';

enum SalesShipmentTaskWorkbenchMode { financeAudit, warehouseOutbound }

/// 销售出货跨部门任务的共享只读投影视图。
///
/// 财务和仓库各自拥有独立路由、标题、默认过滤和权限入口；这里只复用同一套
/// 响应式骨架与权威出货 DTO。
/// - 财务（出货财务审核，2026-09-12 对齐订货审批任务中心）：表格多选 +
///   批量放行/批量退回（整批原子），双击/行菜单进财务专用审核详情页
///   `/finance/sales-shipment-audits/:id`，与销售端出货详情彻底分离；
/// - 仓库（销售出库）：保持只读列表，双击进共享出货详情做仓库作业。
class SalesShipmentTaskWorkbench extends ConsumerStatefulWidget {
  const SalesShipmentTaskWorkbench({super.key, required this.mode});

  final SalesShipmentTaskWorkbenchMode mode;

  @override
  ConsumerState<SalesShipmentTaskWorkbench> createState() =>
      _SalesShipmentTaskWorkbenchState();
}

class _SalesShipmentTaskWorkbenchState
    extends ConsumerState<SalesShipmentTaskWorkbench> {
  static const int _maxBatchSize = 100;

  PagedResult<SalesDocListItem>? _result;
  bool _loading = false;
  String? _error;
  int _page = 1;
  String _keyword = '';
  Timer? _searchDebounce;
  int _requestGeneration = 0;

  int? _financeAudit;
  // V578：「已退回」专段——被财务退回待销售处理的单据集中可见，避免两侧失联。
  bool _financeRejected = false;
  String? _warehouseWorkStatus;

  // ===== 财务批量审批（仅 financeAudit 模式；仓库模式恒空）=====
  final Set<String> _selectedIds = <String>{};
  final Map<String, SalesDocListItem> _selectedById = {};
  bool _busyDecision = false;
  TaskClaimSession? _batchClaim;

  bool get _isFinance =>
      widget.mode == SalesShipmentTaskWorkbenchMode.financeAudit;

  String get _requiredPermission =>
      _isFinance ? Perm.financeShipmentAudit : Perm.salesShipmentWarehouseWork;

  String get _route => _isFinance
      ? RouteName.financeSalesShipmentAudit
      : RouteName.warehouseSalesOutbound;

  String get _backRoute => _isFinance ? RouteName.finance : RouteName.warehouse;

  String get _title => _isFinance ? '出货财务审核' : '仓库销售出库';

  String get _emptyMessage {
    if (_isFinance) {
      if (_financeRejected) return '暂无被退回的出货单';
      return _financeAudit == 1 ? '暂无已财务审核的出货单' : '暂无待财务审核的出货单';
    }
    return switch (_warehouseWorkStatus) {
      SalesWarehouseWorkStatus.pendingPick => '暂无待出库销售出货',
      SalesWarehouseWorkStatus.shipped => '暂无已出库销售出货',
      _ => '暂无财务已放行的销售出货',
    };
  }

  bool get _hasRequiredPermission =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(_requiredPermission);

  @override
  void initState() {
    super.initState();
    _financeAudit = _isFinance ? 0 : 1;
    if (!_isFinance) {
      _warehouseWorkStatus = SalesWarehouseWorkStatus.pendingPick;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasRequiredPermission) return;
      unawaited(
        ref.read(salesMasterNameServiceProvider).ensureLoaded().whenComplete(
          () {
            if (mounted) setState(() {});
          },
        ),
      );
      _load(1);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _batchClaim?.releaseAll().ignore();
    super.dispose();
  }

  Future<void> _load([int? page]) async {
    // 路由守卫之外再失败关闭；权限撤销或独立 widget 场景都不得旁路请求数据。
    if (!_hasRequiredPermission) return;
    final requestedPage = page ?? _page;
    final generation = ++_requestGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _page = requestedPage;
    });
    try {
      final value = await ref
          .read(salesRepositoryProvider(SalesDocType.shipment))
          .list(
            page: requestedPage,
            filter: SalesDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
              // 两个专页都是“当前人工任务”，历史已出库/红冲仍从销售历史页查。
              status: kSalesStatusDraft,
              financeAudit: _financeAudit,
              financeRejected: _financeRejected ? true : null,
              warehouseWorkStatus: _isFinance
                  ? SalesWarehouseWorkStatus.pendingPick
                  : _warehouseWorkStatus,
            ),
          );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _result = value;
        _loading = false;
        for (final item in value.items) {
          if (_selectedIds.contains(item.id)) _selectedById[item.id] = item;
        }
      });
    } on ApiException catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = _isFinance ? '出货财务审核任务加载失败' : '销售出库任务加载失败';
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String value) {
    _keyword = value;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _load(1);
    });
  }

  /// 财务：双击/行菜单 → 财务专用审核详情页（右下角放行/退回，不必回本列表即可决策）；
  /// 决策完成 pop(true) → 回列表刷新并清空勾选。仓库：共享出货详情做仓库作业。
  Future<void> _open(SalesDocListItem item) async {
    if (_isFinance) {
      final decided = await context.push<bool>(
        '${RouteName.financeSalesShipmentAudit}/${Uri.encodeComponent(item.id)}',
      );
      if (decided == true && mounted) {
        _clearSelection();
        await _load();
      }
      return;
    }
    context.push(
      SalesRoutePath.docDetail(SalesDocType.shipment.pathSegment, item.id),
    );
  }

  /// 次要入口（财务）：共享只读销售出货详情，看单据全貌时用。
  void _openSalesDetail(SalesDocListItem item) {
    context.push(
      SalesRoutePath.docDetail(SalesDocType.shipment.pathSegment, item.id),
    );
  }

  // ======================= 财务批量审批（对齐订货审批任务中心） =======================

  /// 行可选条件：待财审 + 销售已确认提交（financeReviewPending）。
  bool _canSelectItem(SalesDocListItem item) =>
      _isFinance &&
      item.financeAudit == 0 &&
      item.shipmentWorkflow.financeReviewPending;

  void _clearSelection() {
    _selectedIds.clear();
    _selectedById.clear();
  }

  void _setSelectedIds(Set<String> next) {
    if (_batchClaim != null) return;
    final capped = next.length > _maxBatchSize;
    final normalized = capped ? next.take(_maxBatchSize).toSet() : next;
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(normalized);
      _selectedById.removeWhere((id, _) => !normalized.contains(id));
      for (final item in _result?.items ?? const <SalesDocListItem>[]) {
        if (normalized.contains(item.id)) _selectedById[item.id] = item;
      }
    });
    if (capped) {
      context.appWarning('单次最多处理 $_maxBatchSize 笔，已保留前 $_maxBatchSize 笔');
    }
  }

  List<SalesDocListItem> get _selectedItems => [
    for (final id in _selectedIds)
      if (_selectedById[id] != null) _selectedById[id]!,
  ];

  String? _selectionIssue() {
    if (_selectedIds.isEmpty) return '请先选择待审出货单';
    final items = _selectedItems;
    if (items.length != _selectedIds.length ||
        items.any((item) => !_canSelectItem(item))) {
      return '部分出货单已变化或不可审，请刷新后重新选择';
    }
    return null;
  }

  String _selectedBillSummary() {
    final items = _selectedItems;
    final visible = items.map((item) => item.billNo ?? '未编号').take(5).join('、');
    return items.length > 5 ? '$visible 等 ${items.length} 笔' : visible;
  }

  static bool _paymentTypeClassified(ShipmentFinanceAuditInfo info) {
    if (info.billingMode == 'FREE') return true;
    return const {
      ClientSalesPaymentType.monthly,
      ClientSalesPaymentType.cash,
      ClientSalesPaymentType.deposit,
    }.contains(info.salesPaymentType?.trim());
  }

  static bool _readableSnapshot(ShipmentFinanceAuditInfo info) =>
      info.reviewRevision != null &&
      info.contentHash != null &&
      readableShipmentReviewSnapshot(info.commercialSnapshot) &&
      (info.previousCommercialSnapshot == null ||
          readableShipmentReviewSnapshot(info.previousCommercialSnapshot));

  /// 整批认领 + 逐笔拉审核快照核对（对齐订货审批 _claimSelection）：
  /// 任一笔认领失败/内容失效/客户未分类（放行）→ 整批不提交。
  Future<TaskClaimSession?> _claimSelection({required bool forApprove}) async {
    final claim = financeReviewClaim(
      ProviderScope.containerOf(context, listen: false),
    );
    _batchClaim = claim;
    setState(() => _busyDecision = true);
    final repo = ref.read(salesRepositoryProvider(SalesDocType.shipment));
    try {
      await claim.claimAll(
        'SALES_SHIPMENT_FINANCE_AUDIT',
        _selectedIds.toList(),
      );
      if (!mounted || !claim.isReady) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '整批未取得审核占用，请重试');
        }
        await _releaseBatchClaim(claim);
        return null;
      }
      for (final id in _selectedIds) {
        final info = await repo.financeAuditInfo(id);
        if (!mounted || !claim.isReady || !_readableSnapshot(info)) {
          if (mounted) {
            context.appWarning('部分出货内容或占用已变化，请刷新后重新核对');
          }
          await _releaseBatchClaim(claim);
          return null;
        }
        if (forApprove && !_paymentTypeClassified(info)) {
          if (mounted) {
            final item = _selectedById[id];
            context.appWarning(
              '出货单 ${item?.billNo ?? ''} 的客户尚未完成销售货款分类（月结/现金/定金），'
              '不能放行；请先在审核详情处理或从选择中移除。',
            );
          }
          await _releaseBatchClaim(claim);
          return null;
        }
      }
      if (mounted) setState(() => _busyDecision = false);
      return claim;
    } on Object {
      if (mounted) {
        context.appError('无法核对整批审核内容，请检查网络或权限后重试');
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

  Future<void> _approveSelected() async {
    if (_busyDecision || _batchClaim != null) return;
    final issue = _selectionIssue();
    if (issue != null) {
      context.appWarning(issue);
      return;
    }
    final count = _selectedIds.length;
    final claim = await _claimSelection(forApprove: true);
    if (claim == null || !mounted) return;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('批量放行($count 笔)'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const UtenReviewerResponsibilityNotice(
                  actionLabel: '批量出货财务审核',
                  description: '确认后，系统将以此登录员工记录整批放行责任；放行仅开放仓库作业，应收在仓库确认出库后生成。',
                  compact: true,
                ),
                const SizedBox(height: UtenSpacing.s12),
                Text('${_selectedBillSummary()}。整批原子提交：任一笔失败全部回滚。'),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FinanceReviewClaimButton(
              claim: claim,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认批量放行'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _runBatch(
        (decisions) => ref
            .read(salesRepositoryProvider(SalesDocType.shipment))
            .financeAuditBatch(decisions),
        claim,
        '已批量放行 $count 笔出货',
      );
    } finally {
      await _releaseBatchClaim(claim);
    }
  }

  Future<void> _rejectSelected() async {
    if (_busyDecision || _batchClaim != null) return;
    final issue = _selectionIssue();
    if (issue != null) {
      context.appWarning(issue);
      return;
    }
    final count = _selectedIds.length;
    final claim = await _claimSelection(forApprove: false);
    if (claim == null || !mounted) return;
    try {
      final controller = TextEditingController();
      String? errorText;
      final reason = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text('批量退回($count 笔)'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const UtenReviewerResponsibilityNotice(
                    actionLabel: '批量退回出货财务审核',
                    description: '确认后，系统将以此登录员工记录整批退回责任。',
                    compact: true,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Text('${_selectedBillSummary()}将使用同一个退回原因，整批原子提交。'),
                  const SizedBox(height: UtenSpacing.s12),
                  TextField(
                    key: const Key('finance-shipment-batch-reject-reason'),
                    controller: controller,
                    autofocus: true,
                    maxLength: 500,
                    maxLines: 3,
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        labelText: '退回原因(必填)',
                        border: const OutlineInputBorder(),
                        error: utenFieldError(errorText),
                      ),
                      info: '写明需要销售修改的内容；整批共用同一原因。',
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
                onPressed: () {
                  final value = controller.text.trim();
                  if (value.isEmpty) {
                    setDialogState(() => errorText = '请填写退回原因');
                    return;
                  }
                  Navigator.pop(ctx, value);
                },
                child: const Text('确认批量退回'),
              ),
            ],
          ),
        ),
      );
      controller.dispose();
      if (reason == null || reason.isEmpty || !mounted) return;
      await _runBatch(
        (decisions) => ref
            .read(salesRepositoryProvider(SalesDocType.shipment))
            .rejectShipmentFinanceBatch(decisions, reason),
        claim,
        '已批量退回 $count 笔出货',
      );
    } finally {
      await _releaseBatchClaim(claim);
    }
  }

  /// 提交前重拉整批快照并组装乐观锁三元组（认领心跳复检），再整批原子提交。
  Future<void> _runBatch(
    Future<void> Function(List<ShipmentFinanceBatchDecision>) action,
    TaskClaimSession claim,
    String okMsg,
  ) async {
    setState(() => _busyDecision = true);
    try {
      if (!await claim.validateForDecision() || !mounted) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核占用已失效，请重新核对');
        }
        return;
      }
      final repo = ref.read(salesRepositoryProvider(SalesDocType.shipment));
      final decisions = <ShipmentFinanceBatchDecision>[];
      for (final id in _selectedIds) {
        final info = await repo.financeAuditInfo(id);
        decisions.add(
          ShipmentFinanceBatchDecision(
            id: id,
            expectedRevision: info.reviewRevision!,
            expectedContentHash: info.contentHash!,
            expectedClaimId: claim.claimIdFor(
              'SALES_SHIPMENT_FINANCE_AUDIT',
              id,
            )!,
          ),
        );
      }
      await action(decisions);
      if (!mounted) return;
      context.appSuccess(okMsg);
      setState(_clearSelection);
      ref.invalidate(salesShipmentFinanceCountProvider);
      await _load(1);
    } on ApiException catch (e) {
      if (mounted) context.appError('整批未提交：${e.message}');
    } catch (_) {
      if (mounted) context.appError('整批未提交，请检查网络后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(_route, () => _load());
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(_requiredPermission);
    return Scaffold(
      appBar: UtenAppBar(
        title: _title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: _backRoute),
        ),
        actions: allowed
            ? [
                IconButton(
                  key: const Key('sales-shipment-task-refresh'),
                  tooltip: '刷新',
                  onPressed: _loading ? null : () => _load(1),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ]
            : null,
      ),
      // 局部 SelectionArea：销售发货审核工作台文字可框选复制（准则 §3.4；
      // 仅搜索防抖无周期轮询，可包）。
      body: SelectionArea(
        child: SafeArea(
          child: Stack(
            children: [
              !allowed
                  ? UtenEmpty.error(
                      message: '无权查看$_title',
                      description: '请在本页权限中授予 $_requiredPermission。',
                    )
                  : _loading && _result == null
                  ? const UtenSkeletonList()
                  : _error != null && _result == null
                  ? UtenEmpty.error(
                      message: _error,
                      actionLabel: '重新加载',
                      onAction: () => _load(1),
                    )
                  : _body(),
              // 2026-09-12 口径：批量提交等一段必须屏幕中央加载动画（跟随网络段）。
              if (_busyDecision)
                const Positioned.fill(
                  child: UtenBusyOverlay(title: '正在提交批量审核决定'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final result =
        _result ??
        const PagedResult<SalesDocListItem>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    final names = ref.watch(salesMasterNameServiceProvider);
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 财务模式大小屏统一走响应式表格（多选/批量/双击与窄屏同款）；
            // 仓库模式保持 桌面表格 / 窄屏卡片 的既有形态。
            final desktop = breakpointForWidth(constraints.maxWidth).isExpanded;
            return _isFinance || desktop
                ? _table(result, names)
                : _compact(result, names);
          },
        ),
      ),
    );
  }

  /// 财务+桌面共用的表格形态（财务含多选与批量动作；仓库纯只读）。
  Widget _table(
    PagedResult<SalesDocListItem> result,
    SalesMasterNameService names,
  ) {
    final selectable =
        _isFinance &&
        ((result.items.any(_canSelectItem)) || _selectedItems.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _summary(result.total),
        const SizedBox(height: UtenSpacing.s12),
        _filters(),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          _InlineTaskError(message: _error!, onRetry: _load),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Expanded(
          child: AbsorbPointer(
            absorbing: _busyDecision,
            child: MasterDataTableView<SalesDocListItem>(
              key: Key(
                _isFinance
                    ? 'finance-shipment-audit-table'
                    : 'warehouse-sales-outbound-table',
              ),
              columns: _columns(names),
              items: result.items,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              onRowTap: _open,
              selectable: selectable,
              idOf: (item) => _canSelectItem(item) ? item.id : null,
              selectedIds: _selectedIds,
              onSelectedIdsChanged: _setSelectedIds,
              batchActionsBuilder: selectable ? _batchActions : null,
              rowMenuBuilder: _isFinance
                  ? (item) => [
                      UtenMenuItem(
                        label: '打开审核详情',
                        icon: Icons.fact_check_outlined,
                        onTap: () => _open(item),
                      ),
                      UtenMenuItem(
                        label: '查看销售出货单',
                        icon: Icons.open_in_new_rounded,
                        onTap: () => _openSalesDetail(item),
                      ),
                    ]
                  : null,
              isLoading: _loading,
              emptyMessage: _emptyMessage,
              currentPage: result.page,
              totalPages: result.totalPages,
              onPageChange: _load,
            ),
          ),
        ),
      ],
    );
  }

  Widget _compact(
    PagedResult<SalesDocListItem> result,
    SalesMasterNameService names,
  ) {
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        key: Key(
          _isFinance
              ? 'finance-shipment-audit-compact-list'
              : 'warehouse-sales-outbound-compact-list',
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
        children: [
          _summary(result.total),
          const SizedBox(height: UtenSpacing.s12),
          _filters(),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            _InlineTaskError(message: _error!, onRetry: _load),
          ],
          if (_loading && _result != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: UtenSpacing.s12),
          if (result.items.isEmpty)
            SizedBox(
              height: 300,
              child: UtenEmpty(
                icon: _isFinance
                    ? Icons.fact_check_outlined
                    : Icons.inventory_2_outlined,
                message: _emptyMessage,
                description: _isFinance
                    ? '新的出货草稿会在这里等待财务逐张人工放行。'
                    : '财务放行后，销售出货会进入这里等待仓库作业。',
              ),
            )
          else
            for (final item in result.items) ...[
              _CompactShipmentTaskCard(
                item: item,
                clientName: names.client(item.clientId),
                warehouseName: names.warehouse(item.warehouseId),
                currencyName: names.currency(item.currencyId),
                onOpen: () => _open(item),
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
          if (result.totalPages > 1)
            _TaskPager(
              page: result.page,
              totalPages: result.totalPages,
              loading: _loading,
              onPage: _load,
            ),
        ],
      ),
    );
  }

  Widget _summary(int total) {
    final theme = Theme.of(context);
    final description = _isFinance
        ? '默认只看待审核。双击进入审核详情逐张核对客户货款类型、应收、铺底和可用预收(真实已审到账)后再人工放行；也可多选后批量放行/退回（整批原子提交）。'
        : '固定只看财务已放行的出货。仓库核对后一步确认出库，届时才正式扣库存并形成应收。';
    return Semantics(
      container: true,
      label: '$_title，共 $total 笔。$description',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.34),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _isFinance
                  ? Icons.fact_check_outlined
                  : Icons.inventory_2_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '共 $total 笔',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filters() {
    final search = SizedBox(
      width: 320,
      child: UtenSearchBar(
        key: const Key('sales-shipment-task-search'),
        hint: '搜索出货单号 / 客户',
        initialValue: _keyword,
        onChanged: _onSearchChanged,
        onSubmitted: (_) {
          _searchDebounce?.cancel();
          _load(1);
        },
      ),
    );
    final chips = _isFinance ? _financeChips() : _warehouseChips();
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < UtenBreakpoints.expandedStart;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: double.infinity, child: search),
              const SizedBox(height: UtenSpacing.s8),
              chips,
              if (_isFinance)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s4),
                  child: Text(
                    '单击选择，双击或长按打开审核详情',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                search,
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: chips),
              ],
            ),
            if (_isFinance)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s4),
                child: Text(
                  _financeRejected
                      ? '共 ${_result?.total ?? 0} 笔 · 已退回销售处理；双击进入可「撤回退回」恢复审核'
                      : '共 ${_result?.total ?? 0} 笔 · 单击选择，双击打开审核详情',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _financeChips() => Wrap(
    spacing: UtenSpacing.s4,
    runSpacing: UtenSpacing.s4,
    children: [
      _financeChip('待审核', 0, rejected: false),
      _financeChip('已退回', 0, rejected: true),
      _financeChip('已审核', 1, rejected: false),
      _financeChip('全部', null, rejected: false),
    ],
  );

  Widget _financeChip(String label, int? value, {required bool rejected}) =>
      ChoiceChip(
        label: Text(label),
        selected: _financeAudit == value && _financeRejected == rejected,
        onSelected: (_) {
          setState(() {
            _financeAudit = value;
            _financeRejected = rejected;
          });
          _clearSelection();
          _load(1);
        },
      );

  Widget _warehouseChips() => Wrap(
    spacing: UtenSpacing.s4,
    runSpacing: UtenSpacing.s4,
    children: [
      _warehouseChip('待出库', SalesWarehouseWorkStatus.pendingPick),
      _warehouseChip('已出库', SalesWarehouseWorkStatus.shipped),
    ],
  );

  Widget _warehouseChip(String label, String? value) => ChoiceChip(
    label: Text(label),
    selected: _warehouseWorkStatus == value,
    onSelected: (_) {
      setState(() => _warehouseWorkStatus = value);
      _load(1);
    },
  );

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final issue = _selectionIssue();
    return [
      UtenButton(
        key: const Key('finance-shipment-batch-reject'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.reply_rounded,
        isLoading: _busyDecision,
        onPressed: issue == null && !_busyDecision ? _rejectSelected : null,
        onDisabledTap: issue == null ? null : () => context.appWarning(issue),
        child: Text('批量退回(${selectedIds.length})'),
      ),
      UtenButton(
        key: const Key('finance-shipment-batch-approve'),
        size: UtenButtonSize.large,
        icon: Icons.fact_check_outlined,
        isLoading: _busyDecision,
        onPressed: issue == null && !_busyDecision ? _approveSelected : null,
        onDisabledTap: issue == null ? null : () => context.appWarning(issue),
        child: Text('批量放行(${selectedIds.length})'),
      ),
    ];
  }

  List<MasterColumnDef<SalesDocListItem>> _columns(
    SalesMasterNameService names,
  ) => [
    MasterColumnDef(
      key: 'billNo',
      label: '出货单号',
      width: 170,
      value: (item) => item.billNo ?? '—',
    ),
    MasterColumnDef(
      key: 'client',
      label: '客户',
      width: 190,
      value: (item) => names.client(item.clientId),
    ),
    MasterColumnDef(
      key: 'shipmentKind',
      label: '发货类型',
      width: 160,
      value: (item) => item.shipmentWorkflow.isDirect
          ? (item.shipmentWorkflow.isFree ? '客户零星 · 不收费' : '客户零星 · 收费')
          : '订货发货',
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '出货日期',
      width: 120,
      type: 'date',
      value: (item) => _shortDate(item.billDate),
    ),
    MasterColumnDef(
      key: 'warehouse',
      label: '仓库',
      width: 150,
      value: (item) => names.warehouse(item.warehouseId),
    ),
    const MasterColumnDef(
      key: 'totalOriginal',
      label: '出货金额',
      width: 140,
      type: 'money',
      value: _amount,
    ),
    MasterColumnDef(
      key: 'financeAudit',
      label: '财务审核',
      width: 120,
      value: (item) => item.shipmentWorkflow.financeRejected
          ? '已退回销售'
          : salesShipmentFinanceAuditLabel(item.financeAudit),
      cellColor: (context, item) => item.shipmentWorkflow.financeRejected
          ? Theme.of(context).colorScheme.errorContainer
          : null,
    ),
    MasterColumnDef(
      key: 'warehouseWorkStatus',
      label: '仓库作业',
      width: 160,
      value: (item) => salesWarehouseWorkStatusLabel(item.warehouseWorkStatus),
    ),
  ];
}

class _CompactShipmentTaskCard extends StatelessWidget {
  const _CompactShipmentTaskCard({
    required this.item,
    required this.clientName,
    required this.warehouseName,
    required this.currencyName,
    required this.onOpen,
  });

  final SalesDocListItem item;
  final String clientName;
  final String warehouseName;
  final String currencyName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = salesShipmentFinanceAuditLabel(item.financeAudit);
    final warehouse = salesWarehouseWorkStatusLabel(item.warehouseWorkStatus);
    final amount = _amount(item);
    return Semantics(
      container: true,
      button: true,
      label:
          '${item.billNo ?? '未编号出货'}，客户 $clientName，财务 $finance，仓库 $warehouse',
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.mdAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              borderRadius: UtenRadius.mdAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.billNo ?? '未编号出货',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      item.priceMasked ? '***' : '$currencyName $amount',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '$clientName · $warehouseName · ${_shortDate(item.billDate)}',
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '财务：$finance · 仓库：$warehouse',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Align(
                  alignment: Alignment.centerRight,
                  child: UtenButton(
                    size: UtenButtonSize.small,
                    type: UtenButtonType.secondary,
                    icon: Icons.open_in_new_rounded,
                    onPressed: onOpen,
                    child: const Text('查看详情'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineTaskError extends StatelessWidget {
  const _InlineTaskError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _TaskPager extends StatelessWidget {
  const _TaskPager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPage,
  });

  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: '上一页',
        onPressed: loading || page <= 1 ? null : () => onPage(page - 1),
        icon: const Icon(Icons.chevron_left_rounded),
      ),
      Text('$page / $totalPages'),
      IconButton(
        tooltip: '下一页',
        onPressed: loading || page >= totalPages
            ? null
            : () => onPage(page + 1),
        icon: const Icon(Icons.chevron_right_rounded),
      ),
    ],
  );
}

String _shortDate(String? value) {
  if (value == null || value.isEmpty) return '—';
  return value.length > 10 ? value.substring(0, 10) : value;
}

String _amount(SalesDocListItem item) {
  if (item.priceMasked) return '***';
  if (item.shipmentWorkflow.isFree) return '不收费（货款 0）';
  return item.exactDecimals['totalOriginal'] ??
      item.exactDecimals['totalLocal'] ??
      (item.totalOriginal ?? item.totalLocal)?.toStringAsFixed(2) ??
      '—';
}
