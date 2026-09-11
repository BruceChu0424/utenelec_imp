// HR 个人修改审批队列（/hr/profile-changes）
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（表头 autofilter 筛选 +
// 列对齐 + 分页）。页面顶部 UtenSegmentedFilter 分段（待审核/已生效/已驳回）管状态、
// 表头筛选管列，两层并存是全站范式。
// 2026-09-10 表头筛选接后端 + 批量驳回：
//   * 「部门」桶来自 GET /hr/profile-changes/facets（按分段状态全量聚合），选中后
//     下推 departmentId 参数并回第 1 页——此前 bucket 只从当前页 items 聚合、
//     过滤也只裁剪当前页，命中行落在其他页时看不到（审计 A2-hr-profile-changes）；
//   * 「状态」桶 = 三个队列状态，选中即切顶部分段并回第 1 页（与分段同一口径）；
//   * 待审段多选新增「批量驳回(N)」，复用公共 UtenBatchRejectDialog 一次填原因；
//   * 两个确认弹窗均带 UtenReviewerResponsibilityNotice（actionLabel「信息变更审核」）；
//   * 行双击改 goFrom（写 returnTo），详情页返回键按全站契约回本队列。
//
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 文档：docs/03-页面/我的页.md（§HR 端：员工修改审批）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_batch_reject_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/pending_review_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../profile/models/profile_change_request.dart';
import '../../profile/providers/profile_change_providers.dart';
import '../../profile/repositories/profile_change_repository.dart';

/// 单次批量上限：逐批循环单审 API，超过则提示分批（无后端批量端点）。
const int kProfileChangeBatchLimit = 50;

class HrProfileChangesListPage extends ConsumerStatefulWidget {
  const HrProfileChangesListPage({super.key});

  @override
  ConsumerState<HrProfileChangesListPage> createState() =>
      _HrProfileChangesListPageState();
}

class _HrProfileChangesListPageState
    extends ConsumerState<HrProfileChangesListPage> {
  String? _status; // null = 默认待审
  int _page = 1; // 当前页（服务端真分页）

  /// 表头「部门」筛选：部门 id，下推后端 departmentId（非页内裁剪）。
  String? _departmentId;

  final List<UtenSegment<String?>> _segments = [];

  /// 待审段多选：批业务 id（batchId，跨页保留）。换分段/换筛选清空。
  Set<String> _selectedIds = {};

  /// 批量通过/驳回进行中（防并发 + 按钮加载态）。
  bool _batchBusy = false;

  /// 待审段（_status null = pending）才开多选批量。
  bool get _isPendingSegment => _status == null;

  /// 列表/筛选桶的状态口径（后端空值 = pending）。
  String get _effectiveStatus => _status ?? 'pending';

  ({String? status, String? departmentId, int page}) get _query =>
      (status: _status, departmentId: _departmentId, page: _page);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(hrProfileChangeQueueProvider);
      ref.read(pendingReviewCountProvider.notifier).refresh();
    });
  }

  void _onSegmentChanged(String? v) {
    setState(() {
      _status = v;
      _page = 1; // 换筛选回到第 1 页
      _departmentId = null; // 分段换了口径，部门桶随之重算
      _selectedIds = {}; // 选中的是旧分段内的批
    });
  }

  /// 表头筛选：部门 → 下推 departmentId；状态 → 切分段。两者都回第 1 页。
  void _onFilterChanged(String key, String? value) {
    setState(() {
      switch (key) {
        case 'departmentName':
          _departmentId = value;
        case 'status':
          // 'pending' 即默认待审段（后端空值口径），与分段值对齐。
          _status = (value == null || value == 'pending') ? null : value;
          _departmentId = null;
        default:
          return;
      }
      _page = 1;
      _selectedIds = {};
    });
  }

  /// 「状态」列筛选桶：三个队列状态（value = 后端状态码）。
  /// 桶不带计数（列表按页拉取，计数口径在部门桶）。
  List<MasterFacetBucket> _statusFacets(AppLocalizations l10n) => [
    MasterFacetBucket(
      value: 'pending',
      count: 0,
      label: l10n.profileChangeFilterPending,
    ),
    MasterFacetBucket(
      value: 'applied',
      count: 0,
      label: l10n.profileChangeFilterApplied,
    ),
    MasterFacetBucket(
      value: 'rejected',
      count: 0,
      label: l10n.profileChangeFilterRejected,
    ),
  ];

  /// 单次批量上限守卫（逐批循环 HTTP，超限提示分批）。
  bool _withinBatchLimit(int count) {
    if (count <= kProfileChangeBatchLimit) return true;
    context.appError('单次最多批量处理 $kProfileChangeBatchLimit 批，请分批操作（当前 $count 批）');
    return false;
  }

  // ---- 批量通过 / 批量驳回 --------------------------------------------------

  /// 逐批复用 review 单审 API（幂等）：单批失败不中断整批，失败原因聚合提示。
  Future<void> _batchApprove(Set<String> ids) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final count = ids.length;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: '批量通过($count 批)',
      message:
          '将逐批通过所选 $count 批员工信息修改申请，通过后立即写入员工档案。'
          '如需核对修改内容，请双击行进入详情逐批审阅。',
      confirmLabel: '确认批量通过',
      actionLabel: '信息变更审核',
      responsibilityDescription: '确认后，系统将以此登录员工记录所选 $count 批修改申请的审核责任。',
    );
    if (!confirmed || !mounted) return;
    await _runBatch(ids, action: 'approve', reason: null, verb: '通过');
  }

  /// 批量驳回：公共原因对话框一次填写（含责任提示），逐批应用同一原因。
  Future<void> _batchReject(Set<String> ids) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final reason = await showUtenBatchRejectDialog(
      context,
      count: ids.length,
      actionLabel: '信息变更审核',
      subjectLabel: '修改申请',
      description: '驳回原因将同步给 ${ids.length} 位申请人，请说明具体问题。',
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    await _runBatch(ids, action: 'reject', reason: reason, verb: '驳回');
  }

  /// 批量执行体：逐批调用单审 API，失败聚合提示，结束后刷新队列与徽章。
  Future<void> _runBatch(
    Set<String> ids, {
    required String action,
    required String? reason,
    required String verb,
  }) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _batchBusy = true);
    final repo = ref.read(profileChangeRepositoryProvider);
    var okCount = 0;
    final failures = <String>[];
    for (final batchId in ids) {
      try {
        await repo.review(batchId, action, reason);
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
        '已$verb $okCount 批修改申请'
        '${failures.isNotEmpty ? '，${failures.length} 批失败' : ''}',
      );
    }
    if (failures.isNotEmpty) {
      context.appError('批量$verb未全部完成：${failures.first}');
    }
    // 刷新队列、筛选桶与导航徽章（员工详情页的「待审修改」区块共用旧 key，一并失效）。
    ref.invalidate(hrProfileChangeQueueProvider);
    ref.invalidate(hrProfileChangesProvider);
    ref.invalidate(hrProfileChangeFacetsProvider(_effectiveStatus));
    ref.read(pendingReviewCountProvider.notifier).refresh();
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    return [
      UtenButton(
        key: const Key('hr-profile-changes-batch-approve'),
        type: UtenButtonType.success,
        size: UtenButtonSize.large,
        icon: Icons.check_circle_outline_rounded,
        isLoading: _batchBusy,
        onPressed: selectedIds.isNotEmpty && !_batchBusy
            ? () => _batchApprove(Set<String>.of(selectedIds))
            : null,
        child: Text('批量通过(${selectedIds.length})'),
      ),
      UtenButton(
        key: const Key('hr-profile-changes-batch-reject'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.cancel_outlined,
        isLoading: _batchBusy,
        onPressed: selectedIds.isNotEmpty && !_batchBusy
            ? () => _batchReject(Set<String>.of(selectedIds))
            : null,
        child: Text('批量驳回(${selectedIds.length})'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    _segments
      ..clear()
      ..addAll([
        UtenSegment(value: null, label: l10n.profileChangeFilterPending),
        UtenSegment(value: 'applied', label: l10n.profileChangeFilterApplied),
        UtenSegment(value: 'rejected', label: l10n.profileChangeFilterRejected),
      ]);

    final async = ref.watch(hrProfileChangeQueueProvider(_query));

    Widget body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          child: UtenSegmentedFilter<String?>(
            segments: _segments,
            selected: _status,
            onChanged: _onSegmentChanged,
          ),
        ),
        Expanded(child: _buildBody(l10n, async)),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.profileChangeHrQueueTitle,
        showBackButton: true,
      ),
      body: body,
    );
  }

  Widget _buildBody(
    AppLocalizations l10n,
    AsyncValue<ProfileChangePage<HrProfileChangeListItem>> async,
  ) {
    final facets = ref.watch(hrProfileChangeFacetsProvider(_effectiveStatus));
    return async.when(
      data: (page) => RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(hrProfileChangeQueueProvider);
          ref.invalidate(hrProfileChangeFacetsProvider(_effectiveStatus));
          ref.read(pendingReviewCountProvider.notifier).refresh();
          await ref.read(hrProfileChangeQueueProvider(_query).future);
        },
        child: MasterDataTableView<HrProfileChangeListItem>(
          key: const Key('hr-profile-changes-table'),
          columns: _columns(l10n),
          items: page.items,
          // 部门桶来自后端全量聚合；状态桶即三个队列分段。
          facets: {
            'departmentName':
                facets.valueOrNull?['departmentName'] ??
                const <MasterFacetBucket>[],
            'status': _statusFacets(l10n),
          },
          nullCounts: const {},
          filters: {
            'departmentName': _departmentId,
            'status': _effectiveStatus,
          },
          onFilterChanged: _onFilterChanged,
          // 待审段开多选 + 悬浮批量通过/驳回；已生效/已驳回段只读浏览。
          selectable: _isPendingSegment,
          idOf: (item) => item.batchId,
          selectedIds: _selectedIds,
          onSelectedIdsChanged: (next) => setState(() => _selectedIds = next),
          batchActionsBuilder: _isPendingSegment ? _batchActions : null,
          // 双击行进入批次详情审阅（goFrom 写 returnTo，详情返回键回本队列）。
          onRowTap: (item) =>
              goFrom(context, RoutePath.hrProfileChangeDetail(item.batchId)),
          emptyMessage: l10n.profileChangeHrQueueEmpty,
          currentPage: page.page,
          totalPages: page.totalPages,
          onPageChange: (p) => setState(() => _page = p),
        ),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => UtenEmpty.error(
        message: e is ApiException ? e.message : l10n.commonError,
        actionLabel: l10n.commonRetry,
        onAction: () => ref.invalidate(hrProfileChangeQueueProvider),
      ),
    );
  }

  List<MasterColumnDef<HrProfileChangeListItem>> _columns(
    AppLocalizations l10n,
  ) => [
    MasterColumnDef(
      key: 'employeeName',
      label: '员工姓名',
      width: 130,
      value: (m) => m.employeeName,
    ),
    MasterColumnDef(
      key: 'employeeCode',
      label: '工号',
      width: 90,
      value: (m) => m.employeeCode,
    ),
    MasterColumnDef(
      key: 'departmentName',
      label: '部门',
      width: 150,
      info: '员工当前所属部门（非提交时快照）；表头筛选按此下推后端 departmentId 参数。',
      value: (m) => m.departmentName,
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '变更项数',
      width: 90,
      type: 'number',
      value: (m) => m.itemCount.toString(),
    ),
    MasterColumnDef(
      key: 'fieldCodes',
      label: '变更字段',
      width: 280,
      info: '本批修改涉及的员工档案字段（机器码，顿号连接）；双击行可查看逐字段新旧值对比。',
      value: (m) => m.fieldCodes.join('、'),
    ),
    MasterColumnDef(
      key: 'submittedAt',
      label: '提交时间',
      width: 150,
      type: 'date',
      value: (m) => _formatTime(m.submittedAt),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (m) => _statusLabel(l10n, m.status),
    ),
  ];
}

/// 批次状态 → 文案。
String _statusLabel(AppLocalizations l10n, ProfileChangeStatus s) {
  switch (s) {
    case ProfileChangeStatus.pending:
      return l10n.profileChangeStatusPending;
    case ProfileChangeStatus.applied:
      return l10n.profileChangeStatusApplied;
    case ProfileChangeStatus.approved:
      return l10n.profileChangeStatusApproved;
    case ProfileChangeStatus.rejected:
      return l10n.profileChangeStatusRejected;
    case ProfileChangeStatus.cancelled:
      return l10n.profileChangeStatusCancelled;
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
