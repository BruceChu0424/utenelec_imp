import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/master_server_column_filters.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import 'shipment_finance_change_summary.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/list_refresh_provider.dart';

enum SalesShipmentTaskWorkbenchMode { financeAudit, warehouseOutbound }

/// 销售出货跨部门任务的共享只读投影视图。
///
/// 财务和仓库各自拥有独立路由、标题、默认过滤和权限入口；这里只复用同一套
/// 响应式骨架与权威出货 DTO。
/// - 财务（出货财务审核，2026-09-12 对齐订货审批任务中心）：表格多选 +
///   批量放行/批量退回（整批原子），双击/行菜单进财务专用审核详情页
///   `/finance/sales-shipment-audits/:id`，与销售端出货详情彻底分离；
/// - 仓库（销售出库）：保持只读列表，双击进共享出货详情做仓库作业。
///
/// [embedded]：财务模式嵌入「业务审核中心」分段时为 true——去掉本工作台的
/// AppBar 与内容容器（外层提供标题/刷新/容器）；[refreshTick] 由外层刷新
/// 信号递增触发重拉。仓库模式不使用嵌入形态。
class SalesShipmentTaskWorkbench extends ConsumerStatefulWidget {
  const SalesShipmentTaskWorkbench({
    super.key,
    required this.mode,
    this.embedded = false,
    this.externalHeader,
    this.refreshTick = 0,
  });

  final SalesShipmentTaskWorkbenchMode mode;
  final bool embedded;

  /// 宿主（业务审核中心）的大类行：挂进本页折叠头，随页一起滚走
  /// （2026-09-24 用户口径「表格滑到顶」，置顶后只剩表格自身工具条）。
  final Widget? externalHeader;

  /// 外层（业务审核中心）触发的刷新信号；数值变化时重拉当前页。
  final int refreshTick;

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
  int _requestGeneration = 0;

  int? _financeAudit;
  // V578：「已退回」专段——被财务退回待销售处理的单据集中可见，避免两侧失联。
  bool _financeRejected = false;
  String? _warehouseWorkStatus;

  // 2026-09-25 单号列统一：出货单号列排序 + 表头值筛选 + 桶 + 防串台代数
  // （共享状态，见 MasterServerColumnFilters）。
  final _columnFilters = MasterServerColumnFilters();

  // ===== 财务批量审批（仅 financeAudit 模式；仓库模式恒空）=====
  final _tableRows = MasterDataTableRowsController<SalesDocListItem>();
  final Set<String> _selectedIds = <String>{};
  final Map<String, SalesDocListItem> _selectedById = {};
  bool _busyDecision = false;
  TaskClaimSession? _batchClaim;

  bool get _isFinance =>
      widget.mode == SalesShipmentTaskWorkbenchMode.financeAudit;

  String get _requiredPermission => _isFinance
      ? Perm.salesShipmentFinanceView
      : Perm.warehouseSalesOutboundView;

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
  void didUpdateWidget(SalesShipmentTaskWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) _load();
  }

  @override
  void dispose() {
    _batchClaim?.releaseAll().ignore();
    super.dispose();
  }

  Future<void> _load([int? page]) async {
    // 路由守卫之外再失败关闭；权限撤销或独立 widget 场景都不得旁路请求数据。
    if (!_hasRequiredPermission) return;
    final requestedPage = page ?? _page;
    final generation = ++_requestGeneration;
    // 单号桶随列表口径重取（2026-09-25 单号列统一）。
    unawaited(_loadBillNoFacets());
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
              // 2026-09-25 单号列统一：出货单号表头值筛选（服务端精确匹配）。
              billNo: _columnFilters['billNo'],
            ),
            // 2026-09-25 单号列统一：列排序（billNo 已入服务端白名单）。
            sort: _columnFilters.sortColumn,
            order: _columnFilters.sortColumn == null
                ? null
                : (_columnFilters.sortAscending ? 'asc' : 'desc'),
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

  /// 出货单号值筛选桶随过滤上下文重取（2026-09-25 单号列统一；失败静默保持旧桶）。
  Future<void> _loadBillNoFacets() {
    if (!_hasRequiredPermission) return Future.value();
    return _columnFilters.loadFacets(
      () async => {
        'billNo': await ref
            .read(salesRepositoryProvider(SalesDocType.shipment))
            .billNoFacets(
              filter: SalesDocFilter(
                keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
                status: kSalesStatusDraft,
                financeAudit: _financeAudit,
                financeRejected: _financeRejected ? true : null,
                warehouseWorkStatus: _isFinance
                    ? SalesWarehouseWorkStatus.pendingPick
                    : _warehouseWorkStatus,
              ),
            ),
      },
      onLoaded: () {
        if (mounted) setState(() {});
      },
    );
  }

  /// 服务端列筛选/排序落地后：setState 刷新表头 + 重拉回第 1 页。
  void _refilter() {
    if (mounted) setState(() {});
    _load(1);
  }

  // 搜索防抖由 UtenSearchBar 自带（2026-10-09 删掉页内二次 Timer：
  // 双层防抖叠加约 600ms，输入明显迟滞）。

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
      for (final item in _tableRows.items) {
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
      return '部分出货单已变化或暂时不能审核，请刷新后重新选择';
    }
    return null;
  }

  String _selectedBillSummary() {
    final items = _selectedItems;
    final visible = items.map((item) => item.billNo ?? '未编号').take(5).join('、');
    return items.length > 5 ? '$visible 等 ${items.length} 笔' : visible;
  }

  static bool _readableSnapshot(ShipmentFinanceAuditInfo info) =>
      info.reviewRevision != null &&
      info.contentHash != null &&
      readableShipmentReviewSnapshot(info.commercialSnapshot) &&
      (info.previousCommercialSnapshot == null ||
          readableShipmentReviewSnapshot(info.previousCommercialSnapshot));

  /// 整批认领 + 逐笔拉审核快照核对（对齐订货审批 _claimSelection）：
  /// 任一笔认领失败/内容失效 → 整批不提交。
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
          context.appWarning(
            claim.failureMessage ?? '这批出货单还没有认领成功，可能正被别人处理，请稍后重试',
          );
        }
        await _releaseBatchClaim(claim);
        return null;
      }
      for (final id in _selectedIds) {
        final info = await repo.financeAuditInfo(id);
        if (!mounted || !claim.isReady || !_readableSnapshot(info)) {
          if (mounted) {
            context.appWarning('部分出货单的内容或处理权已变化，请刷新后重新核对');
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
                  description:
                      '确认后，系统会按当前登录员工记录整批放行责任；放行后单据交给仓库出库，应收在仓库确认出库后生成。',
                  compact: true,
                ),
                const SizedBox(height: UtenSpacing.s12),
                Text('${_selectedBillSummary()}。整批一起提交：只要有一笔失败，这一批都不会生效。'),
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
                  Text('${_selectedBillSummary()}将使用同一个退回原因，整批一起提交。'),
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
          context.appWarning(claim.failureMessage ?? '这批单据的审核认领已失效，请刷新后重新核对');
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
      refreshBadges(ref);
      // 整批放行/退回会改变出货单状态：bump 出货列表精准刷新（栈下的销售出货
      // 列表立即换新，与单笔审核详情页的口径一致）。
      bumpListRefresh(ref, SalesDocConfig.by(SalesDocType.shipment).refreshKey);
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
    final Widget main;
    if (!allowed) {
      main = _pinHostHeader(
        UtenEmpty.error(
          message: '无权查看$_title',
          description: '请联系负责人或超级管理员开通这项查看权限。',
        ),
      );
    } else if (_loading && _result == null) {
      main = _pinHostHeader(const UtenSkeletonList());
    } else if (_error != null && _result == null) {
      main = _pinHostHeader(
        UtenEmpty.error(
          message: _error,
          actionLabel: '重新加载',
          onAction: () => _load(1),
        ),
      );
    } else {
      main = _body();
    }
    // 局部 SelectionArea：销售发货审核工作台文字可框选复制（准则 §3.4；
    // 仅搜索防抖无周期轮询，可包）。
    final body = SelectionArea(
      child: SafeArea(
        child: Stack(
          children: [
            main,
            // 2026-09-12 口径：批量提交等一段必须屏幕中央加载动画（跟随网络段）。
            if (_busyDecision)
              const Positioned.fill(
                child: UtenBusyOverlay(title: '正在提交批量审核决定'),
              ),
          ],
        ),
      ),
    );
    if (widget.embedded) return body;
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
      body: body,
    );
  }

  /// 骨架/错误/无权态钉住宿主分类栏：分类栏在、内容区给 [child]（数据到位后由
  /// [_body] 接管，分类栏随页滚走）。2026-10-01 用户口径：点击子分类的瞬间
  /// 整条分类栏不得消失。
  Widget _pinHostHeader(Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.externalHeader != null) ...[
        widget.externalHeader!,
        const SizedBox(height: UtenSpacing.s12),
      ],
      Expanded(child: child),
    ],
  );

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
    // 2026-10-09 用户口径：大小屏同一张表（窄屏横向滚动），仓库模式自绘
    // 窄屏卡片列表退役，不再维护两套渲染。
    final table = _table(result, names);

    if (widget.embedded) {
      // 嵌入形态不复套容器与内边距（业务审核中心已提供），避免双重 gutter。
      return table;
    }
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
        child: table,
      ),
    );
  }

  /// 财务+桌面共用的表格形态（财务含多选与批量动作；仓库纯只读）。
  ///
  /// 摘要卡/筛选行进折叠头——上滑先收它们（表头随之顶到视口顶），继续滚动才滚
  /// 表格内容，竖向滚动条由联动门控（全站表格滚动口径 2026-09-22）。独立路由与
  /// 业务审核中心嵌入态统一走这套（2026-09-24 用户口径「都要能表格置顶到头」，
  /// 此前嵌入态保持常驻头 + 默认内滚，大字号下固定头挤压表格）。
  Widget _table(
    PagedResult<SalesDocListItem> result,
    SalesMasterNameService names,
  ) {
    final selectable =
        _isFinance &&
        ((result.items.any(_canSelectItem)) || _selectedItems.isNotEmpty);
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 宿主大类行随页滚走（2026-09-24「表格滑到顶」）。
        if (widget.externalHeader != null) ...[
          widget.externalHeader!,
          const SizedBox(height: UtenSpacing.s12),
        ],
        // 2026-10-02 用户口径：「共 N 笔」说明卡退役（与全站提示卡口径一致）。
        _filters(),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          _InlineTaskError(message: _error!, onRetry: _load),
        ],
        const SizedBox(height: UtenSpacing.s12),
      ],
    );
    final table = AbsorbPointer(
      absorbing: _busyDecision,
      child: MasterDataTableView<SalesDocListItem>(
        rowsController: _tableRows,
        paginationRevision: _result,
        paginationScope: (
          _keyword,
          _isFinance,
          _financeAudit,
          _financeRejected,
          _warehouseWorkStatus,
        ),
        tableKey:
            'features.sales.widgets.sales_shipment_task_workbench.SalesShipmentTaskWorkbenchState._table.1',
        // primary 联动（折叠头收完 → 表格内滚），独立/嵌入两态同款。
        primary: true,
        key: Key(
          _isFinance
              ? 'finance-shipment-audit-table'
              : 'warehouse-sales-outbound-table',
        ),
        columns: _columns(names),
        items: result.items,
        // 2026-09-25 单号列统一：出货单号表头值筛选 + 桶 + 列排序。
        facets: {'billNo': _columnFilters.bucketOf('billNo')},
        nullCounts: const {},
        filters: {'billNo': _columnFilters['billNo']},
        onFilterChanged: (key, value) {
          if (key != 'billNo') return;
          _columnFilters.handleFilterChanged(key, value, onChanged: _refilter);
        },
        sortColumn: _columnFilters.sortColumn,
        sortAscending: _columnFilters.sortAscending,
        onSortChange: (column, ascending) => _columnFilters.handleSortChanged(
          column,
          ascending,
          onChanged: _refilter,
        ),
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
    );
    // 独立页与嵌入态（业务审核中心分段）统一折叠联动：上滑先收摘要/筛选，
    // 表头顶到头再表内滚（2026-09-24，对齐物料分析页口径）。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: header,
      body: table,
    );
  }

  Widget _filters() {
    // 2026-10-10 用户口径：出货审核的子分类行统一为全平台筛选工具条——
    // 业务审核中心其余分段（销售订单确认/订货审批/IQC）都是 UtenFilterToolbar，
    // 此前这里是裸 ChoiceChip 行 + 独立搜索框；「单击选择…」「已退回…」两行
    // 操作提示随切换退役（全站提示卡口径）。
    if (_isFinance) {
      return UtenFilterToolbar<String>(
        segmentsKey: const Key('finance-shipment-audit-segments'),
        searchKey: const Key('sales-shipment-task-search'),
        segments: const [
          // 「待审核」= 等我放行的队列（进页面默认选中）；
          // 「已退回」= 被我退回、销售还没改回来的单（V578 专段）。
          UtenFilterSegment(value: 'pending', label: '待审核'),
          UtenFilterSegment(value: 'rejected', label: '已退回'),
          UtenFilterSegment(value: 'audited', label: '已审核'),
          UtenFilterSegment(value: 'all', label: '全部'),
        ],
        selected: {_financeSegment},
        onSelectionChanged: _changeFinanceSegment,
        searchHint: '搜索出货单号 / 客户',
        initialSearchValue: _keyword,
        onSearchChanged: (value) {
          _keyword = value;
          _load(1);
        },
        onSearchSubmitted: (value) {
          _keyword = value;
          _load(1);
        },
      );
    }
    // 仓库模式（销售出库已由 WarehouseSalesOutboundPage 承接，本分支无调用方）：
    // 维持原搜索框 + Chip 行形态。
    final search = SizedBox(
      width: 160,
      child: UtenSearchBar(
        key: const Key('sales-shipment-task-search'),
        hint: '搜索出货单号 / 客户',
        initialValue: _keyword,
        onChanged: (value) {
          _keyword = value;
          _load(1);
        },
        onSubmitted: (value) {
          _keyword = value;
          _load(1);
        },
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < UtenBreakpoints.expandedStart;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: double.infinity, child: search),
              const SizedBox(height: UtenSpacing.s8),
              _warehouseChips(),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            search,
            const SizedBox(width: UtenSpacing.s12),
            Expanded(child: _warehouseChips()),
          ],
        );
      },
    );
  }

  /// 财务分段值 ↔ (financeAudit, financeRejected) 的当前态推导。
  String get _financeSegment => switch ((_financeAudit, _financeRejected)) {
    (0, true) => 'rejected',
    (1, false) => 'audited',
    (null, false) => 'all',
    _ => 'pending',
  };

  void _changeFinanceSegment(String value) {
    final (int? audit, bool rejected) = switch (value) {
      'rejected' => (0, true),
      'audited' => (1, false),
      'all' => (null, false),
      _ => (0, false),
    };
    setState(() {
      _financeAudit = audit;
      _financeRejected = rejected;
    });
    _clearSelection();
    _load(1);
  }

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
    // 2026-10-08 用户口径「状态或进度列默认放最前」：财务审核 / 仓库作业是
    // 出货任务的两条行级结论列（审核结论 + 作业状态，推翻 2026-10-06 批次
    // 「无状态字样不动」的豁免），一起前置。
    MasterColumnDef(
      key: 'financeAudit',
      label: '财务审核',
      width: 120,
      value: (item) => item.shipmentWorkflow.financeRejected
          ? '已退回销售'
          : salesShipmentFinanceAuditLabel(item.financeAudit),
      // 退回格底色走 danger 档（ADR-169 状态列口径），与销售列表同款实底。
      cellColor: (context, item) => item.shipmentWorkflow.financeRejected
          ? utenStatusBadgeCellColor(UtenStatusBadgeType.danger)
          : null,
    ),
    MasterColumnDef(
      key: 'warehouseWorkStatus',
      label: '仓库作业',
      width: 160,
      value: (item) => salesWarehouseWorkStatusLabel(item.warehouseWorkStatus),
      // 仓库作业整格底色（ADR-169，按模式取视角，映射见
      // salesWarehouseWorkStatusBadgeType）：仓库模式待出库=绿（就绪可动手，
      // 轮到仓库出库）、已出库=灰（办结）；财务模式待出库=青（等仓库出货）；
      // 两模式历史迁移异常/已红冲均=红、已取消=灰。
      cellColor: (context, item) {
        final type = salesWarehouseWorkStatusBadgeType(
          item.warehouseWorkStatus,
          warehouseAction: !_isFinance,
        );
        return type == null ? null : utenStatusBadgeCellColor(type);
      },
    ),
    MasterColumnDef(
      // 2026-09-25 单号列统一：可排序 + 表头值筛选（服务端 billNo 白名单/桶）。
      key: 'billNo',
      sortable: true,
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
    MasterColumnDef(
      key: 'totalOriginal',
      label: '出货金额',
      width: 150,
      type: 'money',
      value: (item) => _amount(item, names.currency(item.currencyId)),
    ),
  ];
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

String _shortDate(String? value) {
  if (value == null || value.isEmpty) return '—';
  return value.length > 10 ? value.substring(0, 10) : value;
}

/// 出货金额(ADR-128)：本单币种金额后自动带单位（2026-10-10 后缀口径）；价格遮蔽与不收费照旧。
String _amount(SalesDocListItem item, String currencyName) {
  if (item.priceMasked) return '***';
  if (item.shipmentWorkflow.isFree) return '不收费（货款 0）';
  return financeMoneyWithUnitSuffix(
    item.exactDecimals['totalOriginal'] ?? item.totalOriginal?.toString(),
    currencyName: currencyName,
  );
}
