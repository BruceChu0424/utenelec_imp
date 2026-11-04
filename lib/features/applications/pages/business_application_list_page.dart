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
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/business_application.dart';
import '../providers/business_application_providers.dart';
import '../repositories/business_application_repository.dart';

typedef BusinessApplicationQuery = ({
  String queue,
  String? kind,
  String? status,
  String? stage,
  String? departmentCode,
  int page,
  Object scope,
});
final businessApplicationListProvider = FutureProvider.autoDispose
    .family<PagedResult<BusinessApplication>, BusinessApplicationQuery>(
      (ref, query) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(exportContextEpochProvider);
        return ref
            .watch(businessApplicationRepositoryProvider)
            .list(
              queue: query.queue,
              kind: query.kind,
              status: query.status,
              approvalStage: query.stage,
              departmentCode: query.departmentCode,
              page: query.page,
            );
      },
      dependencies: [
        masterDataSessionKeyProvider,
        exportContextEpochProvider,
        businessApplicationRepositoryProvider,
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
  });
  final bool embedded;
  final String? approvalStage;
  final String? departmentCode;
  final bool initialHistory;
  final String? initialQueue;
  final bool historyOnly;
  final String? resumeLocation;
  final String? kind;
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
    required this.approval,
  });
  final bool embedded, approval, initialHistory, historyOnly;
  final String? kind, stage, departmentCode, resumeLocation, initialQueue;
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
  int _page = 1;
  int _refreshGeneration = 0;
  final _retainedPage = RetainedAsyncPage<PagedResult<BusinessApplication>>();
  @override
  void initState() {
    super.initState();
    _kind = widget.kind;
    _history = widget.initialHistory;
    _posting = widget.initialQueue == 'prepayment-posting';
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
      _queueChosen = widget.initialHistory || widget.initialQueue != null;
      _page = 1;
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
    kind: _posting ? 'PREPAYMENT' : _kind,
    status: widget.approval ? null : _status,
    stage: widget.stage,
    departmentCode: widget.departmentCode,
    page: _page,
    scope: (
      ref.read(masterDataSessionKeyProvider),
      ref.read(exportContextEpochProvider),
    ),
  );
  Future<void> _refresh() async {
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

  @override
  Widget build(BuildContext context) {
    ref.watch(masterDataSessionKeyProvider);
    ref.watch(exportContextEpochProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    final canHandle =
        Perm.applicationApprovalPermissions.any(permissions.contains) &&
        !ref.watch(sessionProvider).impersonationReadOnly;
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
    final result = _retainedPage.resolveFor(ref, (
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

    final content = Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.kind == null && !_posting)
              Padding(
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
                  ],
                  selected: {_kind ?? 'ALL'},
                  onSelectionChanged: (value) => setState(() {
                    _kind = value == 'ALL' ? null : value;
                    _page = 1;
                    _queueChosen = true;
                  }),
                  autoSelectBadge: false,
                ),
              ),
            UtenFilterToolbar<String>(
              segmentsKey: const Key('application-status-filter'),
              trailing: widget.embedded
                  ? UtenRefreshButton(onRefresh: _refresh, busy: _refreshing)
                  : null,
              segments: widget.approval
                  ? [
                      if (!widget.historyOnly)
                        UtenFilterSegment(
                          value: 'pending',
                          label: '待审核',
                          count: canHandle
                              ? scopedPending()
                              : (!_history ? result.value?.total : null),
                          countForm: canHandle
                              ? UtenSegmentCountForm.actionable
                              : UtenSegmentCountForm.browsing,
                        ),
                      if (canSeePosting && !widget.historyOnly)
                        UtenFilterSegment(
                          value: 'prepayment-posting',
                          label: '预付待入账',
                          count: number('prepaymentPostingTodoCount'),
                          inProgressCount: number(
                            'prepaymentPostingInProgressCount',
                          ),
                          countForm: UtenSegmentCountForm.actionable,
                        ),
                      const UtenFilterSegment(value: 'history', label: '历史记录'),
                    ]
                  : [
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
              selected: {
                widget.approval
                    ? (_posting
                          ? 'prepayment-posting'
                          : _history
                          ? 'history'
                          : 'pending')
                    : _status,
              },
              onSelectionChanged: (value) => setState(() {
                if (widget.approval) {
                  _history = value == 'history';
                  _posting = value == 'prepayment-posting';
                  _queueChosen = true;
                } else {
                  _status = value;
                }
                _page = 1;
              }),
              autoSelectBadge: false,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Expanded(
              child: _withLocalDrafts(
                MasterDataTableView<BusinessApplication>(
                  key: ValueKey((
                    _query.scope,
                    widget.stage,
                    widget.departmentCode,
                  )),
                  paginationScope: (
                    _query.scope,
                    _kind,
                    _status,
                    _history,
                    widget.stage,
                    widget.departmentCode,
                  ),
                  tableKey:
                      'applications.${widget.approval ? 'approval' : 'mine'}.${widget.stage ?? 'all'}',
                  columns: _columns,
                  items: result.value?.items ?? const [],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  primary: true,
                  isLoading: result.isLoading && !result.hasValue,
                  isRefreshing: result.isLoading && result.hasValue,
                  error: result.hasError && !result.hasValue
                      ? '申请读取失败，请刷新重试'
                      : null,
                  refreshError: result.hasError && result.hasValue
                      ? '申请更新失败，请刷新重试'
                      : null,
                  onRetry: _refresh,
                  onRowTap: _open,
                  currentPage: result.value?.page ?? _page,
                  totalPages: result.value?.totalPages ?? 1,
                  onPageChange: (value) => setState(() => _page = value),
                  emptyMessage: widget.approval
                      ? (_posting
                            ? '暂无待入账供应商预付'
                            : _history
                            ? '暂无已处理的申请'
                            : '暂无待审核申请')
                      : '暂无申请',
                  bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
                ),
              ),
            ),
          ],
        ),
        if (_refreshing)
          const UtenBusyOverlay(title: '正在刷新申请', showDoNotLeaveHint: false),
      ],
    );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.approval ? '申请审批' : '我的申请记录',
        showBackButton: true,
        actions: [UtenRefreshButton(onRefresh: _refresh, busy: _refreshing)],
      ),
      body: UtenContentContainer.wide(child: content),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: !widget.approval && createKind != null
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
