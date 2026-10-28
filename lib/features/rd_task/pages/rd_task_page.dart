// 工程研发部任务中心(三分段: 待处理 / 进行中 / 已完成)。
//
//  待处理 OPEN        —— 还没人开工, 红徽章: 轮到研发动手。
//  进行中 IN_PROGRESS —— 已经在做、还没交, 黄徽章(ADR-100): 在办但此刻不用催。
//  已完成 DONE/CANCELED —— 终态只读, 不挂数。
//
// 2026-09-21 把裸 TabBar「待完成 / 已完成」换成 UtenFilterToolbar 三分段: 原来
// OPEN 与 IN_PROGRESS 混在「待完成」一段里, 黄色数字点进去没有落脚的地方, 用户
// 也分不清「没人接」和「有人在做」。分段拆开后两个数字各自可点开核对。
// 行可「标记完成」——需 rd_task:resolve 权限且 allowedActions 含 RESOLVE。
//
// 类别通过表头固定 code 桶下推服务端，全结果分页查询；页面不另起类别下拉。
// 状态列同时显示任务类别与办理状态，沿用状态语义色；主工作阶段与草稿入口保留。
//
// 结构克隆：
//  - operations_workbench_page.dart —— race-guard _load / connectionRecovery 重载 /
//    _Filters（关键词 + 类别）。原克隆自它的 _Overview 指标卡
//    已按 2026-10-01 用户口径删除（分段徽章计数已给同口径数字）。
//
// 路由：/rd/tasks → RouteName.rdTaskCenter。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../widgets/rd_initial_basic_unit_dialog.dart';
import '../../../shared/drafts/form_draft_category.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/server_config.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../core/network/connection_recovery.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart'
    show nativeReadAccessDenied;
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/rd_task.dart';
import '../providers/rd_task_count_provider.dart';
import '../repositories/rd_task_repository.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/search/table_column_query.dart';

/// 任务中心的三个分段 —— 值同时是列表接口的 `status` 过滤参数。
///
/// 后端 `RdTaskService.scopeStatuses` 的白名单: `pending` = 只 OPEN,
/// `in_progress` = 只 IN_PROGRESS, `done` = DONE/CANCELED; 默认值 `open` 是
/// 两档合集, 留给老调用点, 本页三段都不用它。**改了这里就要同步后端白名单**,
/// 这三个字符串是本页与服务端之间唯一的契约。
enum _RdTaskSeg {
  draft('', '草稿'),
  pending('pending', '待处理'),
  inProgress('in_progress', '进行中'),
  done('done', '历史单据');

  const _RdTaskSeg(this.apiStatus, this.label);

  /// 列表接口 `status` 查询参数。
  final String apiStatus;
  final String label;

  /// 终态段: 只读浏览, 不挂任何计数。
  bool get isClosed => this == _RdTaskSeg.done;
}

class RdTaskPage extends ConsumerStatefulWidget {
  const RdTaskPage({super.key, this.initialTab = 0});

  /// 旧入口的 Tab 序号(0 = 未完成, 1 = 已完成); 未完成落在「待处理」段。
  final int initialTab;

  @override
  ConsumerState<RdTaskPage> createState() => _RdTaskPageState();
}

class _RdTaskPageState extends ConsumerState<RdTaskPage> {
  late _RdTaskSeg _seg;
  final _searchController = TextEditingController();
  String _keyword = '';
  final _panelKey = GlobalKey<_RdTaskListPanelState>();

  @override
  void initState() {
    super.initState();
    _seg = widget.initialTab == 1 ? _RdTaskSeg.done : _RdTaskSeg.pending;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 红 = 待处理(OPEN): 没人开工, 轮到研发动手。
    // 黄 = 进行中(IN_PROGRESS): 已认领在做, 此刻不用催。
    //
    // 2026-09-21: 两个数各读服务端一个字段, 不再用「count 减 inProgress」还原 open。
    // 相减有两处毛病: 卡面红徽章读的同一个 count 含 inProgress, 等于让黄色那批被红黄
    // 两条链各数一次(ADR-100 禁止的双计); 而且两支 provider 各自 60s 轮询、起拍时刻不同,
    // 一次 OPEN→IN_PROGRESS 跃迁后最长会偏 1 直到下次对齐。
    final pendingCount = ref.watch(
      badgeEntryTodoProvider(BadgeEntry.rdTaskCenter),
    );
    final inProgressCount = ref.watch(
      badgeEntryInProgressProvider(BadgeEntry.rdTaskCenter),
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: '工程研发部 · 任务中心',
        leading: UtenBackButton(
          // 本页由工作台卡片 push 进入；无 returnTo 时回到工作台。
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          if (_seg != _RdTaskSeg.draft)
            UtenRefreshButton(
              onRefresh: () async {
                await _panelKey.currentState?._refresh();
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 四个工作阶段共用“分类 + 搜索”头部；窄屏由共享工具条按空间换行。
            UtenContentContainer.wide(
              selectable: false,
              padding: const EdgeInsets.only(top: UtenSpacing.s12),
              child: UtenFilterToolbar<_RdTaskSeg>(
                key: const Key('rd-task-header'),
                compactBreakpoint: UtenBreakpoints.mediumStart,
                segmentsKey: const Key('rd-task-segments'),
                searchKey: const Key('rd-task-keyword'),
                searchController: _searchController,
                searchHint: _seg == _RdTaskSeg.draft
                    ? '搜索类别、草稿或备注'
                    : '搜索任务号、标题、来源单号或货品',
                onSearchChanged: (value) {
                  final keyword = value.trim();
                  if (keyword != _keyword) setState(() => _keyword = keyword);
                },
                segments: [
                  UtenFilterSegment(
                    value: _RdTaskSeg.draft,
                    label: '草稿',
                    count: ref.watch(
                      formDraftCategoryCountProvider(
                        const FormDraftCategoryScope(module: BadgeModule.rd),
                      ),
                    ),
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                  UtenFilterSegment(
                    value: _RdTaskSeg.pending,
                    label: _RdTaskSeg.pending.label,
                    count: pendingCount < 0 ? 0 : pendingCount,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                  UtenFilterSegment(
                    value: _RdTaskSeg.inProgress,
                    label: _RdTaskSeg.inProgress.label,
                    count: inProgressCount,
                    countForm: UtenSegmentCountForm.inProgress,
                  ),
                  // 终态只读, 不挂数(准则 §二: 历史集合不喊人)。
                  UtenFilterSegment(
                    value: _RdTaskSeg.done,
                    label: _RdTaskSeg.done.label,
                  ),
                ],
                selected: {_seg},
                onSelectionChanged: (value) => setState(() => _seg = value),
              ),
            ),
            Expanded(
              child: _seg == _RdTaskSeg.draft
                  ? UtenContentContainer.wide(
                      child: FormDraftCategoryList(
                        scope: const FormDraftCategoryScope(
                          module: BadgeModule.rd,
                        ),
                        search: _keyword,
                        showSearch: false,
                      ),
                    )
                  : _RdTaskListPanel(
                      key: _panelKey,
                      seg: _seg,
                      keyword: _keyword,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════ 单分段列表面板(待处理 / 进行中 / 已完成) ═══════════════════════

class _RdTaskListPanel extends ConsumerStatefulWidget {
  const _RdTaskListPanel({super.key, required this.seg, required this.keyword});
  final String keyword;

  /// 当前分段 —— 决定列表的 `status` 过滤与「标记完成」入口是否出现。
  final _RdTaskSeg seg;

  @override
  ConsumerState<_RdTaskListPanel> createState() => _RdTaskListPanelState();
}

class _RdTaskListPanelState extends ConsumerState<_RdTaskListPanel>
    with ScopedPagedReadViewMixin<_RdTaskListPanel> {
  int _unitOperationRevision = 0;
  bool _openingUnit = false;
  Object? _unitOpeningToken;
  BuildContext? _unitDialogContext;

  void _invalidateUnitOperation() {
    _unitOperationRevision++;
    _unitOpeningToken = null;
    if (_openingUnit && mounted) setState(() => _openingUnit = false);
    final dialog = _unitDialogContext;
    if (dialog == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!dialog.mounted || _unitDialogContext != dialog) return;
      final route = ModalRoute.of(dialog);
      if (route == null || !route.isActive) return;
      if (route.isCurrent) {
        Navigator.of(dialog).pop();
      } else {
        Navigator.of(dialog).removeRoute(route);
      }
    });
  }

  void _finishUnitOpening(Object token) {
    if (!mounted || !identical(_unitOpeningToken, token)) return;
    setState(() {
      _unitOpeningToken = null;
      _openingUnit = false;
    });
  }

  final _tableRows = MasterDataTableRowsController<RdTaskRow>();

  RdTaskData? _data;
  Object? _acceptedQuery;
  String? _error;
  bool _loading = true;
  int _page = 1;
  int _requestId = 0;
  String get _keyword => widget.keyword;
  String _category = ''; // '' = 全部类别
  bool _hasLoaded = false;
  bool _resolving = false;
  TableColumnQuery _columnsQuery = const TableColumnQuery();
  String? _statusFilter;
  String? _priorityFilter;

  /// 当前选中任务；办理动作悬浮在表体上，选中时不改变行与表头位置。
  String? _selectedTaskId;

  /// 是否有"标记完成"权限（rd_task:resolve 或超管）。仅用于决定是否暴露完成入口；
  /// 行级是否可完成还须看 row.allowedActions。
  bool get _canResolve =>
      ref.read(currentPermissionsProvider).contains(Perm.rdTaskResolve) ||
      ref.read(isSuperAdminProvider);

  /// 当前选中任务的最新行（从本次列表取，任务自动完成离开列表后返回 null → 上下文条自动消失）。
  RdTaskRow? get _selectedRow {
    final id = _selectedTaskId;
    if (id == null || _data == null) return null;
    for (final t in _data!.items) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 点行 / 卡片：打开关联货品的 BOM 维护整页（组装信息 Tab）。
  /// 保存 BOM 后后端经 GOODS_BOM_UPDATED→notifyBomUpdated 自动完成任务并通知计划员；
  /// 故对 BOM 类任务，维护即完成，「标记完成」仅作手动兜底。
  Future<void> _openGoodsBom(RdTaskRow row) async {
    if (row.allowedActions.contains('RECONCILE_BASIC_UNIT')) {
      await _reconcileInitialBasicUnit(row);
      return;
    }
    final goodsId = row.goodsId;
    if (goodsId == null || goodsId.isEmpty) {
      context.appInfo('该任务未关联货品，可直接「标记完成」');
      return;
    }
    final masterIssue = row.sourceDocType == 'MATERIAL_ANALYSIS_MASTER_ISSUE';
    final reportedIssue =
        masterIssue || row.sourceDocType == 'MATERIAL_ANALYSIS_BOM_ISSUE';
    if (reportedIssue && (row.description?.isNotEmpty ?? false)) {
      final open = await UtenDialog.show(
        context,
        title: row.title,
        content: SingleChildScrollView(child: SelectableText(row.description!)),
        confirmLabel: masterIssue
            ? AppLocalizations.of(context).materialBomIssueOpenGoods
            : AppLocalizations.of(context).materialBomIssueOpenBom,
      );
      if (open != true || !mounted) return;
    }
    // Missing units/colors are maintained on the basic tab; BOM structure uses the assembly tab.
    await context.push(
      RoutePath.basicinfoGoodsDetail(
        goodsId,
        tab: masterIssue ? 'basic' : 'bom',
      ),
    );
    // 返回后刷新：BOM 保存触发自动完成经 outbox ~2s，先即时刷一次，再延迟刷一次
    // 让已维护 BOM 的任务自然离开「待完成」（研发不必手动刷新或「标记完成」）。
    if (mounted) {
      refreshBadges(ref);
      await _load();
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (mounted) {
          refreshBadges(ref);
          _load();
        }
      });
    }
  }

  Future<void> _reconcileInitialBasicUnit(RdTaskRow row) async {
    if (_resolving ||
        _openingUnit ||
        !row.allowedActions.contains('RECONCILE_BASIC_UNIT')) {
      return;
    }
    final identity = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    final permissions = Set<String>.of(ref.read(currentPermissionsProvider));
    final session = ref.read(sessionProvider.notifier);
    final intent = session.requestIntentEpoch;
    final revision = _unitOperationRevision;
    final repo = ref.read(rdTaskRepositoryProvider);
    bool current() =>
        mounted &&
        identity != null &&
        !identity.readOnly &&
        _unitOperationRevision == revision &&
        ref.read(authenticatedScopeProvider) == identity &&
        ref.read(apiBaseUrlProvider) == server &&
        setEquals(ref.read(currentPermissionsProvider), permissions) &&
        identical(ref.read(sessionProvider.notifier), session) &&
        session.requestIntentEpoch == intent &&
        (_data?.items.any(
              (item) =>
                  item.id == row.id &&
                  item.rowVersion == row.rowVersion &&
                  item.allowedActions.contains('RECONCILE_BASIC_UNIT'),
            ) ??
            false);
    if (!current()) return;
    final openingToken = Object();
    setState(() {
      _unitOpeningToken = openingToken;
      _openingUnit = true;
    });
    AuthenticatedRequestScope scope;
    try {
      scope = await repo.captureRequestScope(isCurrent: current);
    } catch (_) {
      _finishUnitOpening(openingToken);
      return;
    }
    if (!mounted || !current()) {
      _finishUnitOpening(openingToken);
      return;
    }
    BuildContext? openedDialog;
    final input = await showDialog<RdInitialBasicUnitInput>(
      context: context,
      builder: (dialog) {
        openedDialog = dialog;
        _unitDialogContext = dialog;
        return RdInitialBasicUnitDialog(
          task: row,
          requestScope: scope,
          isCurrent: current,
        );
      },
    );
    if (_unitDialogContext == openedDialog) _unitDialogContext = null;
    _finishUnitOpening(openingToken);
    if (!mounted || input == null || !current()) return;
    try {
      await scope.verify();
    } catch (_) {
      return;
    }
    if (!mounted || !current()) return;
    if (input.openGoods && row.goodsId != null) {
      await context.push(
        RoutePath.basicinfoGoodsDetail(row.goodsId!, tab: 'basic'),
      );
      if (mounted) await _load();
      return;
    }
    setState(() => _resolving = true);
    final result = await context.guardAction(
      () => scope.run(() async {
        final result = await repo.reconcileInitialBasicUnit(
          row.id,
          row.rowVersion,
          input.unitId,
          input.evidence,
        );
        await scope.verify();
        if (!current()) throw AuthenticatedRequestScope.changed();
        return result;
      }),
      success: AppLocalizations.of(context).rdInitialUnitSaved,
      errorFallback: AppLocalizations.of(context).rdInitialUnitFailed,
    );
    if (!mounted) return;
    setState(() => _resolving = false);
    if (!current()) return;
    if (result != null) {
      refreshBadges(ref);
      await _load();
    }
  }

  @override
  void initState() {
    super.initState();
    _scheduleFirstLoad();
  }

  @override
  void didUpdateWidget(covariant _RdTaskListPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换分段 = 换服务端口径: 回到第一页并清掉旧选中任务。
    // 关键词与类别刻意保留 —— 用户常常拿同一个条件在三段之间来回看。
    if (widget.seg != oldWidget.seg || widget.keyword != oldWidget.keyword) {
      if (widget.seg != oldWidget.seg) _statusFilter = null;
      _page = 1;
      _selectedTaskId = null;
      _load();
    }
  }

  void _scheduleFirstLoad() {
    if (_hasLoaded) return;
    _hasLoaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _page = 1;
    _selectedTaskId = null;
    await _load();
  }

  @override
  void scopedPagedReadOwnerChanged() {
    _columnsQuery = const TableColumnQuery();
    _statusFilter = null;
    _priorityFilter = null;
    _invalidateUnitOperation();
    final rejection = scopedPagedReadRejection;
    final version = ++_requestId;
    setState(() {
      _tableRows.update(const []);
      _data = null;
      _acceptedQuery = null;
      _selectedTaskId = null;
      _page = 1;
      _error = rejection?.message;
      _loading = false;
    });
    if (rejection == null && ref.read(authenticatedScopeProvider) != null) {
      Future<void>.microtask(() {
        if (mounted && version == _requestId) _load();
      });
    }
  }

  Future<void> _load({bool useCache = false}) async {
    if (!mounted) return;
    _invalidateUnitOperation();
    final requestId = ++_requestId;
    final query = (
      ref.read(exportContextEpochProvider),
      widget.seg,
      _keyword,
      _category,
      _columnsQuery,
      _statusFilter,
      _priorityFilter,
    );
    final requestedPage = !useCache && _acceptedQuery == query
        ? _tableRows.visiblePage ?? _page
        : _page;
    final repository = ref.read(rdTaskRepositoryProvider);
    final segment = widget.seg;
    final keyword = _keyword;
    final category = _category;
    final columns = _columnsQuery;
    final statusFilter = _statusFilter, priorityFilter = _priorityFilter;
    setState(() {
      if (_acceptedQuery != query) _data = null;
      _loading = true;
      _error = null;
    });
    try {
      final cached = await readScopedPage<RdTaskRow>(
        requestedPage,
        query: (
          repository,
          segment,
          keyword,
          category,
          columns,
          statusFilter,
          priorityFilter,
        ),
        currentQuery: () => (
          ref.read(rdTaskRepositoryProvider),
          widget.seg,
          _keyword,
          _category,
          _columnsQuery,
          _statusFilter,
          _priorityFilter,
        ),
        useCache: useCache,
        fetchPage: (page) async {
          final data = await repository.load(
            status: segment.apiStatus,
            category: category.isEmpty ? null : category,
            keyword: keyword.isEmpty ? null : keyword,
            page: page,
            columns: {
              ...columns.searches,
              'search.status': ?statusFilter,
              'search.priority': ?priorityFilter,
            },
            sort: columns.sort,
            ascending: columns.ascending,
          );
          return PagedReadSnapshot(
            page: PagedResult(
              items: data.items,
              page: data.page,
              size: data.size,
              total: data.total,
              totalPages: data.totalPages,
            ),
            snapshot: data,
          );
        },
      );
      final next =
          (cached as PagedReadSnapshot<RdTaskRow, RdTaskData>).snapshot;
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _data = next;
        _acceptedQuery = query;
        _page = next.page;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      final message = error is ApiException ? error.message : '研发任务加载失败，请稍后重试';
      if (nativeReadAccessDenied(error)) {
        setState(() {
          _data = null;
          _acceptedQuery = null;
          _selectedTaskId = null;
        });
      }
      if (_data == null) {
        // 首次加载失败：整页错误占位。
        setState(() {
          _loading = false;
          _error = message;
        });
      } else {
        // 仍有旧数据：就地提示、保留筛选行与表格可继续操作——不整页替换，
        // 否则搜索中的焦点与输入法组合会被打断（2026-10-09 根因修复口径）。
        setState(() => _loading = false);
        context.appError(message);
      }
    }
  }

  void _applyFilter({String? category}) {
    final needsReload = category != null;
    setState(() {
      if (category != null) _category = category;
      if (needsReload) {
        _page = 1;
        _selectedTaskId = null;
      }
    });
    if (needsReload) _load();
  }

  /// 行级"标记完成"是否可用：任务未关闭 + 后端授权 RESOLVE + 当前账号有 resolve 权限。
  bool _resolveEligible(RdTaskRow row) =>
      row.isOpen && row.allowedActions.contains('RESOLVE') && _canResolve;

  /// 点击行 / 卡片"标记完成"按钮：确认弹窗 → 调 resolve → 刷新徽标与本页。
  /// 用 [guardAction] 统一走顶部通知（成功/失败均自动弹条），不再额外 appSuccess 以免重复。
  Future<void> _onResolve(RdTaskRow row) async {
    if (!_resolveEligible(row) || _resolving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
        title: const Text('标记任务完成'),
        content: Text('确认将任务 ${row.taskNo}「${row.title}」标记为已完成？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          UtenButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认完成'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _resolving = true);
    final ok = await context.guardAction(
      () => ref
          .read(rdTaskRepositoryProvider)
          .resolve(row.id, row.rowVersion, null),
      success: '已标记完成',
      errorFallback: '标记失败，请稍后重试',
    );
    if (!mounted) return;
    setState(() => _resolving = false);
    if (ok == null) return;
    // 任务关闭后徽标计数变化，立即刷新；并重拉本页 + 通知兄弟 Tab（已完成）重拉。
    refreshBadges(ref);
    ref.read(rdTaskRefreshTickProvider.notifier).state++;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    // 网络恢复后，不打扰老人、自动重载当前可见 Tab（同 operations_workbench）。
    ref.listen<int>(
      connectionRecoveryProvider.select((state) => state.recoveryEpoch),
      (previous, next) {
        if (next <= (previous ?? 0)) return;
        Future<void>.microtask(_load);
      },
    );
    // 本人或他人完成/转发任务后重拉: 完成的单会离开「待处理」「进行中」而落进
    // 「已完成」, 三段谁也别停在旧快照上。
    ref.listen<int>(rdTaskRefreshTickProvider, (previous, next) {
      if (next > (previous ?? 0) && _hasLoaded) _load();
    });
    return UtenContentContainer.wide(
      // 轮询页不包选择区：研发任务徽章定时刷新（结构性闪现）与拖选并发有
      // CME 风险（准则 §3.4，用户口径：轮询页不包）。
      selectable: false,
      padding: const EdgeInsets.only(
        top: UtenSpacing.s16,
        bottom: UtenSpacing.s16,
      ),
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final data =
        _data ??
        const RdTaskData(items: [], page: 1, size: 20, total: 0, totalPages: 0);

    // 大小屏共用一张表：统一用 MasterDataTableView，窄屏横向滚动（卡片形态已退役）。
    // 2026-10-01 用户口径：删除列表上方的「待处理/进行中/已完成任务」总数
    // 指标卡——分段工具条上的计数徽章已给出同口径数字，指标卡重复展示。
    final sel = _selectedRow;
    final reconcileUnit =
        sel?.allowedActions.contains('RECONCILE_BASIC_UNIT') ?? false;
    final canAct =
        sel != null &&
        !widget.seg.isClosed &&
        (reconcileUnit ? sel.isOpen : _resolveEligible(sel));
    return Stack(
      fit: StackFit.expand,
      children: [
        _DesktopTaskTable(
          key: const Key('rd-task-desktop-table'),
          rowsController: _tableRows,
          data: data,
          items: data.items,
          paginationScope: (
            widget.seg,
            _keyword,
            _category,
            _columnsQuery,
            _statusFilter,
            _priorityFilter,
          ),
          loading: _loading,
          error: _error,
          onRetry: _load,
          filters: {
            'category': _category.isEmpty ? null : _category,
            'status': _statusFilter,
            'priority': _priorityFilter,
            ..._columnsQuery.searches,
          },
          onFilterChanged: (key, value) {
            if (key == 'category') {
              _applyFilter(category: value ?? '');
              return;
            }
            if (key == 'status' &&
                (!widget.seg.isClosed ||
                    value != null &&
                        !const {'DONE', 'CANCELED'}.contains(value))) {
              return;
            }
            if (key == 'priority' &&
                value != null &&
                !const {'NORMAL', 'URGENT'}.contains(value)) {
              return;
            }
            if (key != 'status' &&
                key != 'priority' &&
                !key.startsWith('search.')) {
              return;
            }
            setState(() {
              if (key == 'status') {
                _statusFilter = value;
              } else if (key == 'priority') {
                _priorityFilter = value;
              } else {
                _columnsQuery = _columnsQuery.search(key, value);
              }
              _page = 1;
              _selectedTaskId = null;
            });
            _load();
          },
          extraFacets: {
            if (widget.seg.isClosed)
              'status': [
                for (final status in const ['DONE', 'CANCELED'])
                  MasterFacetBucket(
                    value: status,
                    label: rdTaskStatusLabel(status),
                    count: 0,
                  ),
              ],
            'priority': [
              for (final priority in const ['URGENT', 'NORMAL'])
                MasterFacetBucket(
                  value: priority,
                  label: _priorityLabel(priority),
                  count: 0,
                ),
            ],
          },
          sortColumn: _columnsQuery.sort,
          sortAscending: _columnsQuery.ascending,
          onSortChange: (key, ascending) {
            setState(() {
              _columnsQuery = _columnsQuery.sorted(key, ascending);
              _page = 1;
              _selectedTaskId = null;
            });
            _load();
          },
          onOpenGoods: _openGoodsBom,
          onSelectionChanged: (row) => setState(() => _selectedTaskId = row.id),
          canResolve: _resolveEligible,
          onResolve: _onResolve,
          onPageChanged: (page) {
            setState(() => _page = page);
            return _load(useCache: true);
          },
        ),
        if (canAct)
          PositionedDirectional(
            start: UtenSpacing.s16,
            end: UtenSpacing.s16,
            bottom: UtenSpacing.s16,
            child: Align(
              alignment: AlignmentDirectional.bottomEnd,
              child: UtenFloatingActionGroup(
                maxWidth: 680,
                children: [
                  _ResolveBar(
                    task: sel,
                    resolving: _resolving || _openingUnit,
                    actionLabel: reconcileUnit ? '核对基本单位' : '标记完成',
                    onResolve: () => reconcileUnit
                        ? _reconcileInitialBasicUnit(sel)
                        : _onResolve(sel),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════ 宽屏：MasterDataTableView ═══════════════════════

class _DesktopTaskTable extends StatelessWidget {
  const _DesktopTaskTable({
    super.key,
    required this.data,
    required this.items,
    required this.loading,
    this.error,
    this.onRetry,
    required this.filters,
    required this.onFilterChanged,
    required this.onOpenGoods,
    required this.onSelectionChanged,
    required this.onPageChanged,
    required this.paginationScope,
    required this.rowsController,
    this.canResolve,
    this.onResolve,
    this.extraFacets = const {},
    this.sortColumn,
    this.sortAscending = true,
    this.onSortChange,
  });

  final MasterDataTableRowsController<RdTaskRow> rowsController;
  final Map<String, List<MasterFacetBucket>> extraFacets;
  final String? sortColumn;
  final bool sortAscending;
  final void Function(String?, bool)? onSortChange;
  final RdTaskData data;
  final List<RdTaskRow> items;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  /// 类别的服务端表头筛选状态（页面持有；null=清除）。
  final Map<String, String?> filters;
  final void Function(String key, String? value) onFilterChanged;

  /// 点行 = 打开关联货品的 BOM 维护弹窗（不是确认完成）。
  final ValueChanged<RdTaskRow> onOpenGoods;

  /// 行被点选时回调（驱动悬浮办理条，不改变表格布局）。
  final ValueChanged<RdTaskRow> onSelectionChanged;
  final Future<void> Function(int) onPageChanged;
  final Object paginationScope;

  /// 「标记完成」可做判定与执行（行右键/长按菜单；窄屏卡片上完成动作也走这里）。
  final bool Function(RdTaskRow)? canResolve;
  final ValueChanged<RdTaskRow>? onResolve;

  /// 类别固定枚举使用服务端 code，当前页没有该类别也能完整查询。
  Map<String, List<MasterFacetBucket>> get _facets => {
    'category': [
      for (final code in const [
        'BOM',
        'DESIGN',
        'SAMPLE',
        'TRIAL',
        'ECN',
        'OTHER',
      ])
        MasterFacetBucket(
          value: code,
          count: 0,
          label: rdTaskCategoryLabel(code),
        ),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MasterDataTableView<RdTaskRow>(
      rowsController: rowsController,
      expensiveRowMounts: false,
      tableKey: 'features.rd_task.pages.rd_task_page.DesktopTaskTable.build.1',
      // 大小屏共用一张表：同一份列定义驱动，窄屏横向滚动（卡片形态已退役）。
      bottomContentPadding:
          UtenFloatingActionGroup.scrollClearance +
          UtenCapsuleNavScope.occlusionOf(context),
      columns: [
        MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 168,
          value: (item) =>
              '${rdTaskCategoryLabel(item.category)} · ${rdTaskStatusLabel(item.status)}',
          // 状态列整格底色（2026-09-27「整格底色」口径；档位按 ADR-169 锚定重定）：
          // 待处理=绿（就绪可动手——轮到研发动手；旧「品牌青沿用指标卡主色」的
          // 理由已随指标卡删除失效，accent 档也让给「他方执行中」）/ 进行中=蓝
          // （正在执行，不是等待外部）/ 已完成=绿 / 已取消=灰。绿在「待处理」与
          // 「已完成」两段各自独立出现（ADR-169 逐段独立），同段内互不撞色。
          cellColor: (context, item) =>
              utenStatusBadgeCellColor(switch (item.status) {
                'OPEN' => UtenStatusBadgeType.success,
                'IN_PROGRESS' => UtenStatusBadgeType.info,
                'DONE' => UtenStatusBadgeType.success,
                _ => UtenStatusBadgeType.neutral,
              }),
        ),
        MasterColumnDef(
          key: 'taskNo',
          label: '任务号',
          width: 148,
          sortable: true,
          value: (item) => item.taskNo,
        ),
        MasterColumnDef(
          key: 'category',
          label: '类别',
          width: 110,
          value: (item) => rdTaskCategoryLabel(item.category),
        ),
        // 货品身份格：主行名称、副行编号。研发任务多是「同名不同编号」的 BOM /
        // 打样件（V5 插面自制与委外两条），旧写法把编号和名称挤在一行且编号在前，
        // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
        // 颜色取 RdTaskRow.colorName（后端 join 货品主档色）：同名同编号的货品
        // 按颜色分行是常态，少了颜色照样认错货。
        MasterColumnDef(
          key: 'goods',
          label: '货品名称',
          width: 200,
          value: (item) => item.goodsName ?? item.goodsCode,
          cellBuilderHandlesSemantics: true,
          cellBuilder: (_, item) => UtenGoodsIdentityCell(name: item.goodsName),
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '编号',
          width: 130,
          value: (item) => UtenGoodsAttributeCell.text(item.goodsCode),
          cellBuilder: (_, item) => UtenGoodsAttributeCell(item.goodsCode),
        ),
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 96,
          value: (item) => UtenGoodsAttributeCell.text(item.colorName),
          cellBuilder: (_, item) => UtenGoodsAttributeCell(item.colorName),
        ),
        MasterColumnDef(
          key: 'title',
          label: '标题',
          width: 240,
          value: (item) => item.title,
        ),
        MasterColumnDef(
          key: 'assignee',
          label: '负责人',
          width: 120,
          value: (item) => item.assigneeName,
        ),
        MasterColumnDef(
          key: 'priority',
          label: '优先级',
          width: 90,
          facetSearchEnabled: true,
          value: (item) => _priorityLabel(item.priority),
        ),
        MasterColumnDef(
          key: 'dueDate',
          label: '截止',
          width: 120,
          type: 'date',
          columnSearchEnabled: true,
          sortable: true,
          value: (item) => item.dueDate ?? '—',
        ),
        MasterColumnDef(
          key: 'createdAt',
          label: '创建',
          width: 120,
          type: 'date',
          columnSearchEnabled: true,
          sortable: true,
          value: (item) => ChinaDateTime.formatIsoInstant(
            item.createdAt,
            fallback: '—',
            seconds: true,
          ),
        ),
      ],
      items: items,
      // 阶段限定资格；历史可再选已完成/已取消，各列均在服务器分页前查询。
      facets: {..._facets, ...extraFacets},
      serverColumnSearch: true,
      sortColumn: sortColumn,
      sortAscending: sortAscending,
      onSortChange: onSortChange,
      nullCounts: const {},
      filters: filters,
      onFilterChanged: onFilterChanged,
      // 单击选中更新悬浮条；双击打开对应办理入口，表头与行保持原位置。
      onRowTap: onOpenGoods,
      onSelectionChanged: onSelectionChanged,
      // 行菜单（右键/长按）：打开 BOM 之外承载「标记完成」。
      rowMenuBuilder: onResolve == null
          ? null
          : (item) => [
              UtenMenuItem(
                label: item.allowedActions.contains('RECONCILE_BASIC_UNIT')
                    ? '核对基本单位'
                    : item.sourceDocType == 'MATERIAL_ANALYSIS_MASTER_ISSUE'
                    ? '打开货品资料'
                    : '打开货品 BOM',
                onTap: () => onOpenGoods(item),
              ),
              if (!item.allowedActions.contains('RECONCILE_BASIC_UNIT') &&
                  (canResolve?.call(item) ?? false))
                UtenMenuItem(label: '标记完成', onTap: () => onResolve!(item)),
            ],
      rowColor: (item) => item.priority.toUpperCase() == 'URGENT'
          ? theme.colorScheme.error.withValues(alpha: 0.06)
          : null,
      isLoading: loading,
      error: error,
      onRetry: onRetry,
      emptyMessage: '当前筛选下没有研发任务',
      currentPage: data.page,
      totalPages: data.totalPages,
      paginationScope: paginationScope,
      onPageChange: onPageChanged,
    );
  }
}

class _ResolveBar extends StatelessWidget {
  const _ResolveBar({
    required this.task,
    required this.resolving,
    required this.actionLabel,
    required this.onResolve,
  });

  final RdTaskRow task;
  final bool resolving;
  final String actionLabel;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: UtenRadius.mdAll,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 360;
            final summary = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.task_alt_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '已选中 ${task.taskNo} · ${task.title}',
                    style: theme.textTheme.bodySmall,
                    maxLines: compact ? null : 1,
                    overflow: compact ? null : TextOverflow.ellipsis,
                  ),
                ),
              ],
            );
            final action = UtenButton(
              size: UtenButtonSize.large,
              isExpanded: compact,
              onPressed: resolving ? null : onResolve,
              icon: Icons.check_circle_outline_rounded,
              child: Text(resolving ? '处理中…' : actionLabel),
            );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  const SizedBox(height: UtenSpacing.s8),
                  action,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: summary),
                action,
              ],
            );
          },
        ),
      ),
    );
  }
}

// ═══════════════════════ 辅助：取值/配色 ═══════════════════════

String _priorityLabel(String priority) {
  switch (priority.toUpperCase()) {
    case 'URGENT':
      return '紧急';
    case 'NORMAL':
    default:
      return '普通';
  }
}
