// 访客审批列表(HR)：待审批 / 已批准 / 已拒绝。
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 列：访客姓名/公司/事由/接待人/接待人部门/计划到访/状态。顶部分段用
// UtenFilterToolbar(2026-09-21 从 UtenSegmentedFilter 迁过来, 为了挂三形态计数)。
// 2026-09-10 表头筛选 + 批量拒绝/转接待人（审计 A2-visitor-approval）：
//   * 「状态」「接待人部门」两列筛选桶来自 GET /visitor-approval/facets（按分段状态集
//     全量聚合），选中后下推 status / hostDepartmentId 参数并回第 1 页（非页内裁剪）；
//   * 待审批段多选批量：批准 / 拒绝（公共 UtenBatchRejectDialog 一次填原因）/
//     转接待人确认（仅 pending 行可转，已转接待人的行前端跳过并计入提示）；
//   * 三个确认弹窗均带 UtenReviewerResponsibilityNotice（actionLabel「访客审批」）；
//   * 全部逐单复用单审 API（无后端批量端点），失败聚合提示。
//
// 响应式：compact 自套 UtenContentContainer 收敛（medium+ 外壳已收敛，
// 内层水平 padding 相应让位）；窄屏表格横向滚动即可。
// 2026-09-18 UI 统一收口：错误态改 ApiException 提取 message、分段行间距
// 对齐报销审批队列口径（top 12 / bottom 8）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_batch_reject_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../visitor/models/visitor_application.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../visitor/widgets/visitor_status_ui.dart';
import '../providers/visitor_approval_providers.dart';
import '../../../shared/badges/badge_registry.dart';

enum ApprovalTab { pending, approved, rejected }

/// 单次批量上限：逐单循环单审 API，超过则提示分批（无后端批量端点）。
const int kVisitorBatchLimit = 50;

class VisitorApprovalListPage extends ConsumerStatefulWidget {
  const VisitorApprovalListPage({super.key});

  @override
  ConsumerState<VisitorApprovalListPage> createState() =>
      _VisitorApprovalListPageState();
}

class _VisitorApprovalListPageState
    extends ConsumerState<VisitorApprovalListPage> {
  ApprovalTab _tab = ApprovalTab.pending;
  int _page = 1;

  /// 表头「状态」筛选：在当前分段状态集内再收敛（待审批段 = pending|hostReviewing）。
  String? _statusFilter;

  /// 表头「接待人部门」筛选：部门 id，下推后端 hostDepartmentId。
  String? _hostDepartmentId;

  /// 待审批段多选：申请 id（跨页保留）。换分段/换筛选清空。
  Set<String> _selectedIds = {};

  /// 批量动作进行中（防并发 + 按钮加载态）。
  bool _batchBusy = false;

  /// 分段自身的状态口径（null = 后端待办状态集 pending + hostReviewing）。
  String? get _tabStatus => switch (_tab) {
    ApprovalTab.pending => null,
    ApprovalTab.approved => 'approved',
    ApprovalTab.rejected => 'rejected',
  };

  VisitorApprovalQuery get _query => (
    status: _statusFilter ?? _tabStatus,
    hostDepartmentId: _hostDepartmentId,
    page: _page,
  );

  bool get _isPendingTab => _tab == ApprovalTab.pending;

  void _onTabChanged(ApprovalTab v) {
    setState(() {
      _tab = v;
      _page = 1;
      _statusFilter = null; // 段内状态收敛属于旧分段
      _selectedIds = {}; // 选中的是旧分段内的申请
      // 「接待人部门」与状态正交，换段保留（桶随新状态重算，选中值不在桶里时
      // 表格空态会给「清除筛选」出口）。
    });
  }

  /// 表头筛选：状态 → 分段内收敛（选到别的分段的状态则切分段）；部门 → 下推 id。
  /// 两者都回第 1 页并清空选中；状态与部门正交，互不清除。
  void _onFilterChanged(String key, String? value) {
    setState(() {
      switch (key) {
        case 'status':
          switch (value) {
            case 'approved':
              _tab = ApprovalTab.approved;
              _statusFilter = null;
            case 'rejected':
              _tab = ApprovalTab.rejected;
              _statusFilter = null;
            case null:
              _statusFilter = null;
            default:
              _tab = ApprovalTab.pending;
              _statusFilter = value;
          }
        case 'hostDepartment':
          _hostDepartmentId = value;
        default:
          return;
      }
      _page = 1;
      _selectedIds = {};
    });
  }

  /// 单次批量上限守卫（逐单循环 HTTP，超限提示分批）。
  bool _withinBatchLimit(int count) {
    final l10n = AppLocalizations.of(context);
    if (count <= kVisitorBatchLimit) return true;
    context.appError(l10n.visitorBatchLimitError(kVisitorBatchLimit, count));
    return false;
  }

  // ---- 批量批准 / 拒绝 / 转接待人 -------------------------------------------

  Future<void> _batchApprove(Set<String> ids) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final l10n = AppLocalizations.of(context);
    final count = ids.length;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: l10n.visitorBatchApproveTitle(count),
      message: l10n.visitorBatchApproveMessage(count),
      confirmLabel: l10n.visitorBatchApproveConfirm,
      actionLabel: l10n.visitorBatchActionLabel,
      responsibilityDescription: l10n.visitorBatchApproveResponsibility(count),
    );
    if (!confirmed || !mounted) return;
    await _runBatch(
      ids,
      verb: l10n.visitorBatchVerbApprove,
      call: (repo, id) => repo.action(id, action: 'approve'),
    );
  }

  Future<void> _batchReject(Set<String> ids) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final l10n = AppLocalizations.of(context);
    final reason = await showUtenBatchRejectDialog(
      context,
      count: ids.length,
      actionLabel: l10n.visitorBatchActionLabel,
      subjectLabel: l10n.visitorBatchSubjectLabel,
      title: l10n.visitorBatchRejectTitle(ids.length),
      description: l10n.visitorBatchRejectDescription(ids.length),
      confirmLabel: l10n.visitorBatchRejectConfirm,
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    await _runBatch(
      ids,
      verb: l10n.visitorBatchVerbReject,
      call: (repo, id) =>
          repo.action(id, action: 'reject', rejectReason: reason),
    );
  }

  /// 批量转接待人确认：后端 forward 只接受 pending，已转接待人的行前端跳过
  /// （避免整批被 BUSINESS 错误刷屏），跳过数计入提示。
  Future<void> _batchForward(
    Set<String> ids,
    List<VisitorApplication> pageItems,
  ) async {
    if (_batchBusy || ids.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final statusById = {for (final app in pageItems) app.id: app.status};
    final forwardable = ids
        .where(
          (id) =>
              statusById[id] == null ||
              statusById[id] == VisitorApplicationStatus.pending,
        )
        .toSet();
    final skipped = ids.length - forwardable.length;
    if (forwardable.isEmpty) {
      context.appError(l10n.visitorBatchForwardNoneSelected);
      return;
    }
    if (!_withinBatchLimit(forwardable.length)) return;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: l10n.visitorBatchForwardTitle(forwardable.length),
      message:
          l10n.visitorBatchForwardMessage(forwardable.length) +
          (skipped > 0 ? l10n.visitorBatchForwardSkippedNote(skipped) : ''),
      confirmLabel: l10n.visitorBatchForwardConfirm,
      actionLabel: l10n.visitorBatchActionLabel,
      responsibilityDescription: l10n.visitorBatchForwardResponsibility(
        forwardable.length,
      ),
    );
    if (!confirmed || !mounted) return;
    await _runBatch(
      forwardable,
      verb: l10n.visitorBatchVerbForward,
      skipped: skipped,
      call: (repo, id) => repo.action(id, action: 'forward'),
    );
  }

  /// 批量执行体：逐单调用单审 API（幂等），单条失败不中断整批，失败聚合提示。
  Future<void> _runBatch(
    Set<String> ids, {
    required String verb,
    required Future<void> Function(VisitorStaffRepository repo, String id) call,
    int skipped = 0,
  }) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _batchBusy = true);
    final repo = ref.read(visitorStaffRepositoryProvider);
    var okCount = 0;
    final failures = <String>[];
    for (final id in ids) {
      try {
        await call(repo, id);
        okCount++;
      } on ApiException catch (e) {
        failures.add(e.message);
      } catch (_) {
        failures.add(l10n.commonError);
      }
    }
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _selectedIds = {};
    });
    if (okCount > 0) {
      context.appSuccess(
        l10n.visitorBatchResult(verb, okCount) +
            (failures.isNotEmpty
                ? l10n.visitorBatchResultFailures(failures.length)
                : '') +
            (skipped > 0 ? l10n.visitorBatchResultSkipped(skipped) : ''),
      );
    }
    if (failures.isNotEmpty) {
      context.appError(l10n.visitorBatchIncomplete(verb, failures.first));
    }
    // 刷新当前分段队列、筛选桶与徽章计数（forward 会推给接待人，两个徽章都变）。
    ref.invalidate(visitorApprovalListProvider(_query));
    ref.invalidate(visitorApprovalFacetsProvider(_tabStatus));
    refreshBadges(ref);
  }

  List<Widget> _batchActions(
    BuildContext context,
    Set<String> selectedIds,
    List<VisitorApplication> pageItems,
  ) {
    final l10n = AppLocalizations.of(context);
    final enabled = selectedIds.isNotEmpty && !_batchBusy;
    return [
      UtenButton(
        key: const Key('visitor-approval-batch-approve'),
        type: UtenButtonType.success,
        size: UtenButtonSize.large,
        icon: Icons.check_circle_outline_rounded,
        isLoading: _batchBusy,
        onPressed: enabled
            ? () => _batchApprove(Set<String>.of(selectedIds))
            : null,
        child: Text(l10n.visitorBatchApproveButton(selectedIds.length)),
      ),
      UtenButton(
        key: const Key('visitor-approval-batch-forward'),
        size: UtenButtonSize.large,
        icon: Icons.forward_to_inbox_outlined,
        isLoading: _batchBusy,
        onPressed: enabled
            ? () => _batchForward(Set<String>.of(selectedIds), pageItems)
            : null,
        child: Text(l10n.visitorBatchForwardButton(selectedIds.length)),
      ),
      UtenButton(
        key: const Key('visitor-approval-batch-reject'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.cancel_outlined,
        isLoading: _batchBusy,
        onPressed: enabled
            ? () => _batchReject(Set<String>.of(selectedIds))
            : null,
        child: Text(l10n.visitorBatchRejectButton(selectedIds.length)),
      ),
    ];
  }

  /// 「状态」列筛选桶：后端桶只带状态码，这里按 l10n 重贴中文标签。
  /// 未知状态码（后端新增态尚未接前端）保留原值，不让列头因解析异常整页崩。
  List<MasterFacetBucket> _statusBuckets(
    List<MasterFacetBucket> raw,
    AppLocalizations l10n,
  ) => [
    for (final bucket in raw)
      MasterFacetBucket(
        value: bucket.value,
        count: bucket.count,
        label: _statusLabelOrCode(bucket.value, l10n),
      ),
  ];

  String _statusLabelOrCode(String code, AppLocalizations l10n) {
    try {
      return visitorStatusLabel(visitorStatusFromCode(code), l10n);
    } on FormatException {
      return code;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final list = ref.watch(visitorApprovalListProvider(_query));
    final facets = ref.watch(visitorApprovalFacetsProvider(_tabStatus));
    final isCompact = context.breakpoint.isCompact;

    Widget body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s8,
          ),
          // 全平台统一筛选工具条(2026-09-21 由 UtenSegmentedFilter 换过来: 旧组件
          // 把计数拼成 `标签 (N)` 字符串, 没有形态之分, 挂不了三形态计数)。
          //
          // 待审批 = 等 HR 动手 -> 红; 已批准 = 人已放行、访客还没来核验, 事情在跑
          // 但不用 HR 动手 -> 黄(ADR-100); 已拒绝是终态 -> 不挂数。
          //
          // 注意黄数字的口径: 取的是「已批准且还没来核验」的在办数(与工作台访客卡
          // 同源同数), 列表本身仍列出全部已批准记录(含已经来过的), 所以徽章数会
          // 小于行数 —— 这是刻意的, 黄色回答的是「还有几拨人没来」。
          child: UtenFilterToolbar<ApprovalTab>(
            segmentsKey: const Key('visitor-approval-segments'),
            selected: {_tab},
            onSelectionChanged: _onTabChanged,
            segments: [
              UtenFilterSegment(
                value: ApprovalTab.pending,
                label: l10n.visitorApprovalPending,
                count: ref.watch(
                  badgeEntryTodoProvider(BadgeEntry.visitorApproval),
                ),
                countForm: UtenSegmentCountForm.actionable,
              ),
              UtenFilterSegment(
                value: ApprovalTab.approved,
                label: l10n.visitorFilterApproved,
                count: ref.watch(
                  badgeEntryInProgressProvider(BadgeEntry.visitorApproval),
                ),
                countForm: UtenSegmentCountForm.inProgress,
              ),
              UtenFilterSegment(
                value: ApprovalTab.rejected,
                label: l10n.visitorFilterRejected,
              ),
            ],
          ),
        ),
        Expanded(
          child: list.when(
            loading: () => const UtenSkeletonList(itemCount: 6),
            error: (e, _) => UtenEmpty.error(
              // 与信息变更审核/通知列表同款：ApiException 提取 message，兜底通用文案。
              message: e is ApiException ? e.message : l10n.commonError,
              actionLabel: l10n.commonRetry,
              onAction: () =>
                  ref.invalidate(visitorApprovalListProvider(_query)),
            ),
            data: (page) => RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(visitorApprovalListProvider(_query));
                ref.invalidate(visitorApprovalFacetsProvider(_tabStatus));
              },
              child: MasterDataTableView<VisitorApplication>(
                key: const Key('visitor-approval-table'),
                columns: _columns(l10n),
                items: page.items,
                facets: {
                  'status': _statusBuckets(
                    facets.valueOrNull?['status'] ?? const [],
                    l10n,
                  ),
                  'hostDepartment':
                      facets.valueOrNull?['hostDepartment'] ?? const [],
                },
                nullCounts: const {},
                filters: {
                  'status': _statusFilter ?? _tabStatus,
                  'hostDepartment': _hostDepartmentId,
                },
                onFilterChanged: _onFilterChanged,
                // 待审批段开多选 + 悬浮批量动作；已批准/已拒绝段只读浏览。
                selectable: _isPendingTab,
                idOf: (app) => app.id,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: (next) =>
                    setState(() => _selectedIds = next),
                batchActionsBuilder: _isPendingTab
                    ? (context, ids) => _batchActions(context, ids, page.items)
                    : null,
                // 双击行进入审批详情：push（2026-09-24 起，原来 go 会抹掉列表实例，
                // 详情返回只能落 default；push 后详情 pop 回本页，数据由
                // autoDispose family 失效自动换新）。
                onRowTap: (app) => context.push('/visitor-approval/${app.id}'),
                emptyMessage: l10n.visitorApprovalEmpty,
                currentPage: page.page,
                totalPages: page.totalPages,
                onPageChange: (p) => setState(() => _page = p),
              ),
            ),
          ),
        ),
      ],
    );
    if (isCompact) body = UtenContentContainer(child: body);

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.visitorApprovalTitle,
        showBackButton: true,
      ),
      body: body,
    );
  }

  List<MasterColumnDef<VisitorApplication>> _columns(AppLocalizations l10n) => [
    MasterColumnDef(
      key: 'visitorName',
      label: l10n.visitorColVisitorName,
      width: 130,
      value: (app) => app.visitorName,
    ),
    MasterColumnDef(
      key: 'company',
      label: l10n.visitorColCompany,
      width: 170,
      value: (app) => app.company,
    ),
    MasterColumnDef(
      key: 'visitPurpose',
      label: l10n.visitorColPurpose,
      width: 260,
      value: (app) => app.visitPurpose,
    ),
    MasterColumnDef(
      key: 'hostName',
      label: l10n.visitorColHost,
      width: 120,
      value: (app) => app.hostName,
    ),
    MasterColumnDef(
      key: 'hostDepartment',
      label: l10n.visitorColHostDepartment,
      width: 150,
      info: l10n.visitorApprovalHostDeptColInfo,
      value: (app) => app.hostDepartment,
    ),
    MasterColumnDef(
      key: 'plannedVisitAt',
      label: l10n.visitorColPlannedVisit,
      width: 180,
      type: 'date',
      value: (app) => fmtDateTime(app.plannedVisitAt),
    ),
    MasterColumnDef(
      key: 'status',
      label: l10n.visitorColStatus,
      width: 110,
      value: (app) => visitorStatusLabel(app.status, l10n),
    ),
  ];
}
