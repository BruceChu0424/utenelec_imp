import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../shared/models/retained_async_page.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_refresh_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../expense/pages/expense_list_page.dart';
import '../../expense/providers/expense_providers.dart';
import '../models/business_application.dart';
import '../providers/business_application_providers.dart';
import '../repositories/business_application_repository.dart';

/// 前端伪分类：「报销申请」段（2026-11-04 我的申请改版）。
/// 报销与业务申请是两条独立数据链（不同单据/工作流，服务端各自权威），此段只做
/// 入口整合——选中后嵌入报销列表内容体，绝不把 EXPENSE 当 kind 发给业务申请接口。
const String kExpenseSegmentKind = 'EXPENSE';

typedef BusinessApplicationQuery = ({
  String queue,
  String? kind,
  String? status,
  String? stage,
  String? departmentCode,
  Object scope,
});
final businessApplicationReadProvider = Provider.autoDispose
    .family<
      ScopedPagedReadProviderLease<BusinessApplication>,
      BusinessApplicationQuery
    >(
      (ref, query) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(businessApplicationRepositoryProvider);
        return ScopedPagedReadProviderLease<BusinessApplication>(
          ref,
          query: query,
        );
      },
      dependencies: [
        masterDataSessionKeyProvider,
        exportContextEpochProvider,
        businessApplicationRepositoryProvider,
      ],
    );
final businessApplicationListProvider = FutureProvider.autoDispose
    .family<PagedResult<BusinessApplication>, BusinessApplicationQuery>(
      (ref, query) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(exportContextEpochProvider);
        final repository = ref.watch(businessApplicationRepositoryProvider);
        Future<PagedResult<BusinessApplication>> fetch(int page, int size) =>
            repository.list(
              queue: query.queue,
              kind: query.kind,
              status: query.status,
              approvalStage: query.stage,
              departmentCode: query.departmentCode,
              page: page,
              size: size,
            );
        return ref
            .watch(businessApplicationReadProvider(query))
            .read(
              1,
              fetchPage: (page) => fetch(page, 100),
              fetchPageSized: fetch,
              idOf: (row) => row.id,
            );
      },
      retry: pagedReadProviderRetry,
      dependencies: [
        masterDataSessionKeyProvider,
        exportContextEpochProvider,
        businessApplicationRepositoryProvider,
        businessApplicationReadProvider,
      ],
    );

class BusinessApplicationListPage extends StatelessWidget {
  const BusinessApplicationListPage({
    super.key,
    this.embedded = false,
    this.kind,
  });
  final bool embedded;
  final String? kind;
  @override
  Widget build(BuildContext context) =>
      _ApplicationsPage(embedded: embedded, kind: kind, approval: false);
}

class BusinessApplicationApprovalListPage extends StatelessWidget {
  const BusinessApplicationApprovalListPage({
    super.key,
    this.embedded = false,
    this.approvalStage,
    this.departmentCode,
    this.initialHistory = false,
    this.initialQueue,
    this.historyOnly = false,
    this.resumeLocation,
    this.kind,
    this.refreshTick = 0,
    this.externalHeader,
  });
  final bool embedded;
  final String? approvalStage;
  final String? departmentCode;
  final bool initialHistory;
  final String? initialQueue;
  final bool historyOnly;
  final String? resumeLocation;
  final String? kind;

  /// 宿主(审批中心)右上角刷新的递增计数；变化时本页重拉列表与计数。
  final int refreshTick;

  /// 宿主父分类行：由本页挂进折叠头随页滚走（上滑先把表格钉顶，
  /// 2026-09-24「表格滑到顶」口径，同仓库任务中心/业务审核中心范式）。
  final Widget? externalHeader;
  @override
  Widget build(BuildContext context) => _ApplicationsPage(
    embedded: embedded,
    approval: true,
    kind: kind,
    stage: approvalStage,
    departmentCode: departmentCode,
    initialHistory: initialHistory,
    initialQueue: initialQueue,
    historyOnly: historyOnly,
    resumeLocation: resumeLocation,
    refreshTick: refreshTick,
    externalHeader: externalHeader,
  );
}

class _ApplicationsPage extends ConsumerStatefulWidget {
  const _ApplicationsPage({
    this.embedded = false,
    this.kind,
    this.stage,
    this.departmentCode,
    this.initialHistory = false,
    this.initialQueue,
    this.historyOnly = false,
    this.resumeLocation,
    this.refreshTick = 0,
    this.externalHeader,
    required this.approval,
  });
  final bool embedded, approval, initialHistory, historyOnly;
  final String? kind, stage, departmentCode, resumeLocation, initialQueue;
  final int refreshTick;
  final Widget? externalHeader;
  @override
  ConsumerState<_ApplicationsPage> createState() => _ApplicationsPageState();
}

class _ApplicationsPageState extends ConsumerState<_ApplicationsPage> {
  String _status = 'DRAFT';
  String? _kind;
  bool _history = false,
      _refreshing = false,
      _posting = false,
      _queueChosen = false;
  int _refreshGeneration = 0;
  final _retainedPage = RetainedAsyncPage<PagedResult<BusinessApplication>>();
  @override
  void initState() {
    super.initState();
    _kind = widget.kind;
    _history = widget.initialHistory;
    _posting = widget.initialQueue == 'prepayment-posting';
    // 入账队列只列预付申请：进入时分类行显式选中「预付申请」，
    // 不整行隐藏分类行（避免行跳动与来路不明的数据切换）。
    if (_posting) _kind = 'PREPAYMENT';
    _queueChosen = widget.initialHistory || widget.initialQueue != null;
  }

  @override
  void didUpdateWidget(covariant _ApplicationsPage old) {
    super.didUpdateWidget(old);
    if (old.approval != widget.approval ||
        old.kind != widget.kind ||
        old.stage != widget.stage ||
        old.departmentCode != widget.departmentCode ||
        old.initialHistory != widget.initialHistory ||
        old.initialQueue != widget.initialQueue) {
      _kind = widget.kind;
      _history = widget.initialHistory;
      _posting = widget.initialQueue == 'prepayment-posting';
      if (_posting) _kind = 'PREPAYMENT';
      _queueChosen = widget.initialHistory || widget.initialQueue != null;
    }
    // 宿主(审批中心)右上角刷新：递增 tick 触发本页重拉，请求登记到
    // 宿主 UtenRefreshScope，让按钮等待真实请求收尾。延迟到帧后执行，
    // 避免在 build 期间 invalidate provider。
    if (old.refreshTick != widget.refreshTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) UtenRefreshScope.track(context, _refresh());
      });
    }
  }

  FormDraftCategoryScope get _formDraftScope => FormDraftCategoryScope(
    kind: 'business_application',
    routePath: '/applications/new',
    query: {'kind': ?_kind},
  );
  Widget _withLocalDrafts(MasterDataTableView<BusinessApplication> table) =>
      !widget.approval && _status == 'DRAFT'
      ? FormDraftCategoryTable<BusinessApplication>(
          scope: _formDraftScope,
          table: table,
          formalId: (value) => value.id,
        )
      : table;

  BusinessApplicationQuery get _query => (
    queue: widget.approval
        ? (_posting
              ? 'prepayment-posting'
              : _history
              ? 'history'
              : 'pending')
        : 'mine',
    kind: _posting
        ? 'PREPAYMENT'
        : _kind == kExpenseSegmentKind
        ? null
        : _kind,
    status: widget.approval ? null : _status,
    stage: widget.stage,
    departmentCode: widget.departmentCode,
    scope: (
      ref.read(masterDataSessionKeyProvider),
      ref.read(exportContextEpochProvider),
    ),
  );
  Future<void> _refresh() async {
    if (!widget.approval && _kind == kExpenseSegmentKind) {
      await _refreshExpense();
      return;
    }
    if (_refreshing) return;
    final query = _query;
    final generation = ++_refreshGeneration;
    bool current() =>
        mounted && generation == _refreshGeneration && _query == query;
    setState(() => _refreshing = true);
    try {
      ref.invalidate(businessApplicationListProvider(query));
      ref.invalidate(businessApplicationCountsProvider);
      await ref.read(businessApplicationListProvider(query).future);
    } catch (e) {
      if (mounted && current()) {
        setState(() => _refreshing = false);
        context.appApiError(e);
      }
    } finally {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _open(BusinessApplication value) async {
    await context.push('/applications/${value.id}');
    if (mounted) await _refresh();
  }

  /// 报销分类的刷新：与报销列表页「返回即刷新」同一组动作。
  Future<void> _refreshExpense() async {
    await ref.read(expenseListProvider.notifier).refresh();
    ref.invalidate(expenseMineFacetsProvider);
    await refreshBadges(ref);
  }

  /// 报销分类的「新建报销」悬浮按钮；口径与报销列表页一致——
  /// 无申请权限不显示；草稿段由表格批量动作组提供入口，悬浮按钮让位。
  Widget? _expenseFloatingAction() {
    if (!ref.watch(currentPermissionsProvider).contains(Perm.expenseApply)) {
      return null;
    }
    final draftTableReady =
        ref.watch(expenseFilterProvider) == ExpenseFilter.draft &&
        ref.watch(expenseListProvider).hasValue;
    if (draftTableReady) return null;
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          size: UtenButtonSize.large,
          icon: Icons.add_rounded,
          onPressed: () => context.push(RouteName.expenseNew),
          child: const Text('新建报销'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(masterDataSessionKeyProvider);
    ref.watch(exportContextEpochProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    // 「报销申请」段（2026-11-04 我的申请改版）：仅我的记录页提供，入口权限与
    // 原「我的报销」卡同口径（/expense → expenseApply）；审批中心不并入报销。
    final viewingExpense = !widget.approval && _kind == kExpenseSegmentKind;
    final canViewExpense =
        !widget.approval &&
        locationAllowedFor(
          permissions,
          ref.watch(isSuperAdminProvider),
          RouteName.expense,
        );
    final canSeePosting =
        widget.approval &&
        widget.stage == 'FINANCE' &&
        const [
          Perm.applicationPay,
          Perm.applicationPrepaymentLinkFinance,
        ].any(permissions.contains);
    final counts = ref.watch(businessApplicationCountsProvider).value;
    if (_posting && !canSeePosting) _posting = false;
    if (canSeePosting &&
        !_queueChosen &&
        counts != null &&
        !widget.historyOnly) {
      int n(String key) => (counts[key] as num?)?.toInt() ?? 0;
      final pending =
          n('financePendingCount') +
          n('financeReceivePendingCount') +
          n('payableCount');
      if (pending == 0 &&
          n('prepaymentPostingTodoCount') +
                  n('prepaymentPostingInProgressCount') >
              0) {
        _posting = true;
        _kind = 'PREPAYMENT';
      }
      _queueChosen = true;
    }
    final createKind =
        (_kind != null ? [_kind!] : businessApplicationKinds.keys)
            .where(
              (kind) =>
                  permissions.contains('application:apply') ||
                  permissions.contains(
                    'application:apply:${kind.toLowerCase()}',
                  ),
            )
            .firstOrNull;
    ref.onPageResume(
      widget.resumeLocation ??
          (widget.approval ? '/applications/approval' : '/applications/mine'),
      _refresh,
    );
    final query = _query;
    if (!viewingExpense) {
      ref
          .watch(businessApplicationReadProvider(query))
          .bindView(context, currentQuery: () => _query);
    }
    // 报销段挂的是另一条数据链：不订阅业务申请列表（避免无谓请求），
    // 切回申请分类时 scope 未变、缓存仍在，照常复用。
    final result = viewingExpense
        ? null
        : _retainedPage.resolveFor(ref, (
            query.scope,
            query.queue,
            query.kind,
            query.status,
            query.stage,
            query.departmentCode,
          ), businessApplicationListProvider(query));
    final localDraftCount = !widget.approval
        ? ref.watch(formDraftCategoryCountProvider(_formDraftScope))
        : 0;
    int? number(String key) {
      if (counts == null) return null;
      return (counts[key] as num?)?.toInt();
    }

    int? mine(String status) {
      if (counts == null) return null;
      final byKind = counts['mineByKind'] as Map?;
      if (_kind != null) {
        final m = byKind?[_kind] as Map? ?? const {};
        if (status == 'PROCESSING') {
          return [
            'SUBMITTED',
            'REVIEWING',
            'APPROVED',
            'POSTING_PENDING',
          ].fold<int>(0, (sum, s) => sum + ((m[s] as num?)?.toInt() ?? 0));
        }
        if (status == 'ACTION_REQUIRED') {
          return ((m['REJECTED'] as num?)?.toInt() ?? 0) +
              ((m['ROUTING_STALE'] as num?)?.toInt() ?? 0);
        }
        return ((m[status] as num?)?.toInt() ?? 0) +
            (status == 'DRAFT' ? localDraftCount : 0);
      }
      if (status == 'ACTION_REQUIRED') {
        return (number('mineRejectedCount') ?? 0) +
            (number('mineRoutingStaleCount') ?? 0);
      }
      final count = number(switch (status) {
        'DRAFT' => 'mineDraftCount',
        'REJECTED' => 'mineRejectedCount',
        _ => 'mineProcessingCount',
      });
      return count == null
          ? null
          : count + (status == 'DRAFT' ? localDraftCount : 0);
    }

    int? kindPending(String kind) {
      if (counts == null) return null;
      final scope = widget.stage == 'DEPARTMENT'
          ? widget.departmentCode
          : widget.stage;
      final map = counts['pendingByScopeKind'] as Map?;
      return ((map?[scope] as Map?)?[kind] as num?)?.toInt() ?? 0;
    }

    int? scopedPending() {
      if (counts == null) return null;
      if (_kind != null) return kindPending(_kind!);
      final scope = widget.stage == 'DEPARTMENT'
          ? widget.departmentCode
          : widget.stage;
      if (scope == null) return number('pendingCount');
      final map =
          ((counts['pendingByScopeKind'] as Map?)?[scope] as Map?) ?? const {};
      return map.values.fold<int>(
        0,
        (total, value) => total + ((value as num?)?.toInt() ?? 0),
      );
    }

    (int?, int?) kindMine(String kind) {
      if (counts == null) return (null, null);
      final map = (counts['mineByKind'] as Map?)?[kind] as Map? ?? const {};
      int n(String key) => (map[key] as num?)?.toInt() ?? 0;
      final local = ref.watch(
        formDraftCategoryCountProvider(
          FormDraftCategoryScope(
            kind: 'business_application',
            routePath: '/applications/new',
            query: {'kind': kind},
          ),
        ),
      );
      return (
        n('DRAFT') + n('REJECTED') + n('ROUTING_STALE') + local,
        n('SUBMITTED') + n('REVIEWING') + n('APPROVED') + n('POSTING_PENDING'),
      );
    }

    // 申请视图构建器：仅非报销分类时求值（此时 result 非空）。
    // 2026-11-04 审批中心分类栏精简：审批态第三行状态栏退役——待审核/预付待入账
    // 由首列「状态」表头筛选驱动（同订货审批任务中心 status→分段联动范式）；
    // 嵌入态历史记录不在筛选里（宿主父分类行已有），独立路由保留历史桶保深链。
    final statusFilterable = widget.approval && !widget.historyOnly;
    final approvalStatusFacets = statusFilterable
        ? <String, List<MasterFacetBucket>>{
            'status': [
              MasterFacetBucket(
                value: 'pending',
                label: '待审核',
                count: scopedPending() ?? 0,
              ),
              if (canSeePosting && (_kind == null || _kind == 'PREPAYMENT'))
                MasterFacetBucket(
                  value: 'prepayment-posting',
                  label: '预付待入账',
                  count: number('prepaymentPostingTodoCount') ?? 0,
                ),
              // 嵌入态历史走宿主父分类行，不出桶；独立路由与「深链直入历史
              // 队列」时保留历史桶，保证 ?queue=history 仍能落到已选值。
              if (!widget.embedded || _history)
                const MasterFacetBucket(
                  value: 'history',
                  label: '历史记录',
                  count: 0,
                ),
            ],
          }
        : const <String, List<MasterFacetBucket>>{};
    final approvalStatusFilter = statusFilterable
        ? <String, String?>{
            'status': _posting
                ? 'prepayment-posting'
                : _history
                ? 'history'
                : 'pending',
          }
        : const <String, String?>{};
    Widget applicationsView() {
      final applications = result!;
      return _withLocalDrafts(
        MasterDataTableView<BusinessApplication>(
          key: ValueKey((_query.scope, widget.stage, widget.departmentCode)),
          paginationScope: (
            _query.scope,
            _kind,
            _status,
            _history,
            _posting,
            widget.stage,
            widget.departmentCode,
          ),
          tableKey:
              'applications.${widget.approval ? 'approval' : 'mine'}.${widget.stage ?? 'all'}',
          columns: _columns,
          items: applications.value?.items ?? const [],
          facets: approvalStatusFacets,
          nullCounts: const {},
          filters: approvalStatusFilter,
          onFilterChanged: (key, value) {
            if (!statusFilterable || key != 'status') return;
            // 与原状态栏分段切换同一套状态迁移（含入账队列→预付申请联动）。
            setState(() {
              _history = value == 'history';
              _posting = value == 'prepayment-posting';
              if (_posting) _kind = 'PREPAYMENT';
              _queueChosen = true;
            });
          },
          primary: true,
          isLoading: applications.isLoading && !applications.hasValue,
          isRefreshing: applications.isLoading && applications.hasValue,
          error: applications.hasError && !applications.hasValue
              ? '申请读取失败，请刷新重试'
              : null,
          refreshError: applications.hasError && applications.hasValue
              ? '申请更新失败，请刷新重试'
              : null,
          onRetry: _refresh,
          onRowTap: _open,
          emptyMessage: widget.approval
              ? (_posting
                    ? '暂无待入账供应商预付'
                    : _history
                    ? '暂无已处理的申请'
                    : '暂无待审核申请')
              : '暂无申请',
          bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
        ),
      );
    }

    // 申请类别行（审批态与我的记录共用；2026-11-04 审批中心精简后审批态只剩
    // 这一行自带导航，状态行已下沉为表格首列「状态」表头筛选）。
    final kindBar = widget.kind == null
        ? Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: UtenFilterToolbar<String>(
              segmentsKey: const Key('application-kind-filter'),
              segments: [
                const UtenFilterSegment(value: 'ALL', label: '全部申请'),
                for (final e in businessApplicationKinds.entries)
                  UtenFilterSegment(
                    value: e.key,
                    label: e.value,
                    count: widget.approval
                        ? kindPending(e.key)
                        : kindMine(e.key).$1,
                    inProgressCount: widget.approval
                        ? null
                        : kindMine(e.key).$2,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                // 报销入口徽章与原 hub「我的报销」卡同口径：红=本人待办
                // （草稿+待修订），黄=已提交流转中；来源徽章汇总单一数据源。
                if (canViewExpense)
                  UtenFilterSegment(
                    value: kExpenseSegmentKind,
                    label: '报销申请',
                    count: ref.watch(
                      badgeEntryTodoProvider(BadgeEntry.expenseMine),
                    ),
                    inProgressCount: ref.watch(
                      badgeEntryInProgressProvider(BadgeEntry.expenseMine),
                    ),
                    countForm: UtenSegmentCountForm.actionable,
                  ),
              ],
              selected: {_kind ?? 'ALL'},
              onSelectionChanged: (value) => setState(() {
                _kind = value == 'ALL' ? null : value;
                // 入账队列只属于预付申请：切到其他类别即退出该队列。
                if (_posting && value != 'PREPAYMENT') _posting = false;
                _queueChosen = true;
              }),
              autoSelectBadge: false,
            ),
          )
        : null;
    // 审批态（嵌入审批中心/独立审批路由）：宿主父分类行 + 类别行进折叠头，
    // 上滑先把表格钉顶（2026-09-24「表格滑到顶」口径）；我的申请记录保留
    // 固定两行导航（报销段内嵌报销列表自带折叠容器，不与其嵌套）。
    final Widget pageBody = widget.approval && !viewingExpense
        ? UtenCollapsingHeaderScrollView(
            collapsingHeader: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.externalHeader != null) ...[
                  widget.externalHeader!,
                  const SizedBox(height: UtenFilterRow.rowGap),
                ],
                ?kindBar,
              ],
            ),
            body: applicationsView(),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?kindBar,
              if (!viewingExpense && !widget.approval)
                UtenFilterToolbar<String>(
                  segmentsKey: const Key('application-status-filter'),
                  segments: [
                    UtenFilterSegment(
                      value: 'DRAFT',
                      label: '草稿',
                      count: mine('DRAFT'),
                      countForm: UtenSegmentCountForm.actionable,
                    ),
                    UtenFilterSegment(
                      value: 'ACTION_REQUIRED',
                      label: '待处理',
                      count: mine('ACTION_REQUIRED'),
                      countForm: UtenSegmentCountForm.actionable,
                    ),
                    UtenFilterSegment(
                      value: 'PROCESSING',
                      label: '处理中',
                      count: mine('PROCESSING'),
                      countForm: UtenSegmentCountForm.inProgress,
                    ),
                    const UtenFilterSegment(value: 'FINISHED', label: '历史记录'),
                  ],
                  selected: {_status},
                  onSelectionChanged: (value) => setState(() {
                    _status = value;
                  }),
                  autoSelectBadge: false,
                ),
              const SizedBox(height: UtenSpacing.s8),
              Expanded(
                child: viewingExpense
                    ? const ExpenseListPage(
                        key: Key('applications-mine-expense-embedded'),
                        embedded: true,
                        resumeLocation: '/applications/mine',
                      )
                    : applicationsView(),
              ),
            ],
          );
    final content = Stack(
      children: [
        pageBody,
        if (_refreshing)
          const UtenBusyOverlay(title: '正在刷新申请', showDoNotLeaveHint: false),
      ],
    );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.approval ? '申请审批' : '我的申请记录',
        showBackButton: true,
        actions: [
          UtenRefreshButton(
            onRefresh: viewingExpense ? _refreshExpense : _refresh,
            busy: viewingExpense
                ? ref.watch(expenseListProvider).isLoading
                : _refreshing,
          ),
        ],
      ),
      body: UtenContentContainer.wide(child: content),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: !widget.approval
          ? (viewingExpense
                ? _expenseFloatingAction()
                : createKind != null
                ? UtenFloatingActionGroup(
                    children: [
                      UtenButton(
                        size: UtenButtonSize.large,
                        icon: Icons.add,
                        onPressed: () =>
                            context.push('/applications/new?kind=$createKind'),
                        child: const Text('新建申请'),
                      ),
                    ],
                  )
                : null)
          : null,
    );
  }
}

final _columns = <MasterColumnDef<BusinessApplication>>[
  MasterColumnDef(
    key: 'status',
    label: '状态',
    info:
        '显示当前业务环节。供应商预付可先记录真实付款；待同一供应商、金额、付款日期的已审核预付记录具备后，由独立授权人员关联财务入账，不会生成费用。',
    width: 170,
    value: (v) => v.statusLabel,
    cellColor: (context, v) => utenStatusBadgeCellColor(
      v.approvalRoutingStale
          ? UtenStatusBadgeType.danger
          : v.postingStatus == 'PENDING'
          ? UtenStatusBadgeType.warning
          : switch (v.status) {
              'DRAFT' || 'CANCELLED' => UtenStatusBadgeType.neutral,
              'REJECTED' => UtenStatusBadgeType.danger,
              'PAID' || 'COMPLETED' => UtenStatusBadgeType.success,
              'APPROVED' => UtenStatusBadgeType.warning,
              _ => UtenStatusBadgeType.info,
            },
    ),
  ),
  MasterColumnDef(
    key: 'applicationNo',
    label: '申请单号',
    width: 240,
    value: (v) => v.applicationNo,
  ),
  MasterColumnDef(
    key: 'kind',
    label: '申请类别',
    width: 150,
    value: (v) => v.kindLabel,
  ),
  MasterColumnDef(key: 'title', label: '标题', width: 240, value: (v) => v.title),
  MasterColumnDef(
    key: 'applicantName',
    label: '申请人',
    width: 110,
    value: (v) => v.applicantName,
  ),
  MasterColumnDef(
    key: 'departmentName',
    label: '部门',
    width: 140,
    value: (v) => v.departmentName ?? '',
  ),
  MasterColumnDef(
    key: 'amount',
    label: '金额',
    width: 140,
    type: 'money',
    value: (v) => '${v.amount} 元',
  ),
  MasterColumnDef(
    key: 'rejectReason',
    label: '驳回原因',
    width: 240,
    value: (v) => v.rejectReason ?? '',
  ),
];
