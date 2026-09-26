// 委外业务列表页族（共用 _SubcontractBusinessListPage，按 _ListPresentation 参数化）。
//
// 2026-09-06 收口：
//  - 计划委外申请页退役并入「委外任务中心」（/subcontract/applications 列表路由
//    重定向；只读申请详情页保留深链）；委外回厂跟踪页退役（进度在任务中心
//    双击弹窗与订货单详情全链路查看；/subcontract/receipts 列表重定向到订货页）。
//  - 页头动作按钮统一进 UtenFilterToolbar trailing（与分类分段/搜索同一行）；
//    订货页只保留「创建新委外单」一个入口（从任务中心选申请下单）。
//  - 委外页面不放仓库/品质动作入口：仓库登记回厂、委外出仓分别在仓储模块
//    的预计到货与委外出仓工作台办理。
//
// 2026-09-23 分类层级对齐订单进度页：订货主类为草稿/进行中/历史记录，
// 待财审、财务退回、执行中归进行中子类；已结案、红冲归历史子类。
// 成品退回/余料退回/损耗审核即完成单据动作，主类为草稿/历史记录，
// 已审与红冲归历史子类，不把已完成记录误标为进行中。
// 主类、子类、历史时间一起随页头收起；默认不选不加载，历史仍须先选时间。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/doc_status_badge.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/document_status_counts_provider.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';
import '../repositories/subcontract_repository.dart';

/// 委外订货与全链路工作页：两种来源汇合后，从财务审批跟到 IQC 与结案。
class SubcontractOrderWorkspacePage extends StatelessWidget {
  const SubcontractOrderWorkspacePage({super.key, this.initialStatus});

  /// 深链预选（路由 `?status=draft`）：新建页「草稿(N)」按钮的落点。
  final String? initialStatus;

  @override
  Widget build(BuildContext context) => _SubcontractBusinessListPage(
    initialStatus: initialStatus,
    presentation: const _ListPresentation(
      type: SubcontractDocType.order,
      title: '委外订货与全链路',
      icon: Icons.precision_manufacturing_outlined,
      primaryAction: _PageAction(
        label: '创建新委外单',
        icon: Icons.add_rounded,
        route: '/subcontract/orders/new',
        requiredPermissions: [
          Perm.subcontractOrderView,
          Perm.subcontractOrderCreate,
        ],
      ),
      emptyMessage: '暂无委外订货单',
      columns: _orderColumns,
    ),
  );
}

/// V304 及更早材料/BOM 子件发料历史，仅供审计和反向兼容（只读，不放仓库动作）。
class SubcontractLegacyMaterialIssueHistoryPage extends StatelessWidget {
  const SubcontractLegacyMaterialIssueHistoryPage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.materialIssue,
      title: '历史委外发料记录',
      icon: Icons.history_rounded,
      emptyMessage: '暂无历史委外发料记录',
      columns: _legacyIssueColumns,
    ),
  );
}

/// 委外成品退回历史：只能从已经发生的回厂/IQC处置链进入，不开放空白新建。
class SubcontractFinishedReturnHistoryPage extends StatelessWidget {
  const SubcontractFinishedReturnHistoryPage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.returnDoc,
      title: '委外成品退回记录',
      icon: Icons.undo_outlined,
      primaryAction: _PageAction(
        label: '从回厂来源登记退回',
        icon: Icons.undo_rounded,
        route: '/subcontract/returns/new',
        requiredPermissions: [
          Perm.subcontractReturnView,
          Perm.subcontractReturnCreate,
        ],
      ),
      emptyMessage: '暂无委外成品退回记录',
      columns: _returnColumns,
    ),
  );
}

/// 委外商退回我方余料历史，绑定供应商处台账，不允许任意手输创造结存。
class SubcontractMaterialReturnHistoryPage extends StatelessWidget {
  const SubcontractMaterialReturnHistoryPage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.materialReturn,
      title: '委外余料退回记录',
      icon: Icons.assignment_return_outlined,
      primaryAction: _PageAction(
        label: '从在外结存登记余料',
        icon: Icons.assignment_return_outlined,
        route: '/subcontract/material-returns/new',
        requiredPermissions: [
          Perm.subcontractMaterialReturnView,
          Perm.subcontractMaterialReturnCreate,
        ],
      ),
      emptyMessage: '暂无委外余料退回记录',
      columns: _materialReturnColumns,
    ),
  );
}

/// 委外损耗与责任工作历史。实物损耗、责任认定、索赔履约、会计事实严格分层。
class SubcontractWasteResponsibilityPage extends StatelessWidget {
  const SubcontractWasteResponsibilityPage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.waste,
      title: '委外损耗与责任',
      icon: Icons.gavel_outlined,
      primaryAction: _PageAction(
        label: '从在外结存登记损耗',
        icon: Icons.playlist_add_rounded,
        route: '/subcontract/wastes/new',
        requiredPermissions: [
          Perm.subcontractWasteView,
          Perm.subcontractWasteCreate,
        ],
      ),
      emptyMessage: '暂无委外损耗记录',
      columns: _wasteColumns,
    ),
  );
}

/// 未启用询价历史。保留只读路由，不把零数据结构误导成可执行业务。
class SubcontractInquiryArchivePage extends StatelessWidget {
  const SubcontractInquiryArchivePage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.inquiry,
      title: '委外询价历史',
      icon: Icons.archive_outlined,
      emptyMessage: '暂无委外询价历史',
      columns: _inquiryColumns,
    ),
  );
}

typedef _ColumnsBuilder =
    List<MasterColumnDef<SubcontractDocListItem>> Function(
      mn.MasterNameService names,
      bool canViewCommercial,
    );

class _ListPresentation {
  const _ListPresentation({
    required this.type,
    required this.title,
    required this.icon,
    required this.emptyMessage,
    required this.columns,
    this.primaryAction,
  });

  final SubcontractDocType type;
  final String title;
  final IconData icon;
  final String emptyMessage;
  final _ColumnsBuilder columns;
  final _PageAction? primaryAction;
}

class _PageAction {
  const _PageAction({
    required this.label,
    required this.icon,
    required this.route,
    required this.requiredPermissions,
  });

  final String label;
  final IconData icon;
  final String route;
  final List<String> requiredPermissions;
}

class _SubcontractBusinessListPage extends ConsumerStatefulWidget {
  const _SubcontractBusinessListPage({
    required this.presentation,
    this.initialStatus,
  });

  final _ListPresentation presentation;

  /// 深链预选（路由 `?status=draft`）：新建页「草稿(N)」按钮进来时直接落在草稿段。
  final String? initialStatus;

  @override
  ConsumerState<_SubcontractBusinessListPage> createState() =>
      _SubcontractBusinessListPageState();
}

/// 主类聚合或子类切片，直接映射服务端过滤，分页前不在前端拼接或筛行。
class _BizSeg {
  const _BizSeg.stage(int this.status, [this.financeApproval, this.closed])
    : history = false;
  const _BizSeg.inProgress()
    : status = null,
      financeApproval = 'IN_PROGRESS',
      closed = null,
      history = false;
  const _BizSeg.history([this.status, this.closed])
    : financeApproval = null,
      history = true;

  final int? status;
  final String? financeApproval;
  final bool? closed;
  final bool history;

  @override
  bool operator ==(Object other) =>
      other is _BizSeg &&
      other.status == status &&
      other.financeApproval == financeApproval &&
      other.closed == closed &&
      other.history == history;

  @override
  int get hashCode => Object.hash(status, financeApproval, closed, history);
}

class _SubcontractBusinessListPageState
    extends ConsumerState<_SubcontractBusinessListPage> {
  final _controller = _BusinessPagedController();

  /// 当前选中分段；null = 未选择引导态（不发请求）。
  _BizSeg? _seg;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  /// 待处理段计数（中性括号 `(N)`）；null = 加载中（不渲染）。
  int? _actionableCount;

  /// 表头列筛选：委外商/执行仓库（dict 桶，value=UUID，回传 supplierId/warehouseId）。
  String? _supplierIdFilter;
  String? _warehouseIdFilter;

  String? _location;

  _ListPresentation get _p => widget.presentation;
  SubcontractDocConfig get _cfg => SubcontractDocConfig.by(_p.type);

  /// 订货单（走财务审批流）专属口径。
  bool get _isOrder => _p.type == SubcontractDocType.order;

  /// 「草稿」段：订货单额外带 NONE 切片（在审单归「等待财务审核」段，不算草稿）。
  _BizSeg get _draftSeg => _BizSeg.stage(0, _isOrder ? 'NONE' : null);

  _BizSeg? get _primarySeg {
    final seg = _seg;
    if (seg == null || seg == _draftSeg) return seg;
    return seg.history ? const _BizSeg.history() : const _BizSeg.inProgress();
  }

  /// 分段计数范围(2026-09-21 用户口径: 父分类有红徽章, 子分类也要有数): 订货/成品退回/
  /// 余料退回/损耗按状态分桶(订货另有等待财审 / 财务已退回桶), 一次请求; 其余单据无
  /// hub 徽章, 沿用 list(size:1) 草稿数。
  DocumentStatusScope? get _statusScope =>
      _cfg.draftKind == null ? null : DocumentStatusScope(_cfg.draftKind!);

  /// 待处理段：其余=草稿（待提交/待审）。历史兼容页（历史发料/询价）无待办
  /// 语义，不挂徽章。
  int? get _actionableStatus => switch (_p.type) {
    SubcontractDocType.materialIssue || SubcontractDocType.inquiry => null,
    _ => 0,
  };

  bool get _shouldLoad {
    final seg = _seg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    // 深链 ?status=draft：直接落在「草稿」段（新建页「草稿(N)」按钮的落点）。
    if (isDraftStatusQuery(widget.initialStatus)) {
      _seg = _draftSeg;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(mn.masterNameServiceProvider).ensureLoaded();
      if (_shouldLoad) _reload();
      _loadBadge();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<PagedResult<SubcontractDocListItem>> _fetch() {
    final seg = _seg!;
    final range = seg.history ? _historyTime.range : null;
    return ref
        .read(subcontractRepositoryProvider(_p.type))
        .list(
          page: _controller.page,
          filter: SubcontractDocFilter(
            keyword: _controller.keyword.trim(),
            supplierId: _supplierIdFilter,
            warehouseId: _warehouseIdFilter,
            status: seg.status,
            financeApproval: seg.financeApproval,
            closed: seg.closed,
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
          ),
        );
  }

  Future<void> _reload([int? page, bool silent = false]) {
    if (!_shouldLoad) return Future.value();
    return _controller.load(
      page ?? _controller.page,
      silent: silent,
      fetch: _fetch,
    );
  }

  void _selectSeg(_BizSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
    });
    if (!seg.history || !_historyTime.isNone) _reload(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _reload(1);
  }

  /// 表头筛选回调：值并进既有 repository.list 参数，重拉回第 1 页。
  void _onColumnFilterChanged(String key, String? value) {
    setState(() {
      if (key == 'supplier') {
        _supplierIdFilter = value;
      } else if (key == 'warehouse') {
        _warehouseIdFilter = value;
      }
    });
    _reload(1);
  }

  /// 待处理段计数（list size=1 取 total；失败保持 null 不渲染括号数字）。
  ///
  /// 订货单有两个计数段：「草稿」=status=0 且未提交（NONE），
  /// 「等待财务审核」=status=0 且在审（PENDING）——在审单已交由财务处理，
  /// 不再算草稿（与 hub 红徽章/服务端草稿计数同一口径）。
  Future<void> _loadBadge() async {
    // 订货/成品退回/余料退回/损耗: 分段计数走 documentStatusCountsProvider(全部桶一次
    // 请求), 这里只失效重取; 没有 hub 徽章的单据仍按下方 list(size:1) 数草稿。
    final statusScope = _statusScope;
    if (statusScope != null) {
      ref.invalidate(documentStatusCountsProvider(statusScope));
      return;
    }
    final status = _actionableStatus;
    if (status == null && !_isOrder) return;
    try {
      final repo = ref.read(subcontractRepositoryProvider(_p.type));
      final docs = await repo.list(
        size: 1,
        filter: SubcontractDocFilter(status: status),
      );
      if (!mounted) return;
      setState(() => _actionableCount = docs.total);
    } catch (_) {
      // 计数失败静默：徽章不显示，不影响列表。
    }
  }

  bool _canUse(_PageAction action) {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return action.requiredPermissions.every(permissions.contains);
  }

  bool get _canViewCommercial {
    if (ref.watch(isSuperAdminProvider)) return true;
    return _cfg.canViewCommercial(ref.watch(currentPermissionsProvider));
  }

  @override
  Widget build(BuildContext context) {
    // 分段计数(有 hub 徽章的四类单据一次请求带回全部桶); 加载中或无权限为 null, 不渲染数字。
    final statusScope = _statusScope;
    final staged = statusScope != null;
    final statusCounts = statusScope == null
        ? null
        : ref.watch(documentStatusCountsProvider(statusScope)).valueOrNull;
    // 条件表达式里直接写 `? statusCounts?[key]` 会被 Dart 解析器当成两个 `?`, 走局部函数。
    int? bucket(String key) => statusCounts?[key];
    // 返回即刷新(ADR-108): 回到本列表时, 只有本端写过数据或离开超过 30 秒才重拉,
    // 且推迟到返回转场结束; 详情/编辑页保存成功 bump 的 tick 在本页就在栈顶时立即重拉,
    // 被详情页盖着时只记下、返回再拉——此前 tick 与返回各拉一次, 一次保存重拉两遍。
    final pendingCount = bucket(DocumentStatusBucket.pendingFinance);
    final executingCount = bucket(DocumentStatusBucket.executing);
    final ongoingCount = pendingCount == null || executingCount == null
        ? null
        : pendingCount + executingCount;
    _location ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_location!, () {
      _reload(null, true);
      _loadBadge();
    }, refreshKeys: [_cfg.refreshKey]);
    final names = ref.watch(mn.masterNameServiceProvider);
    final seg = _seg;
    final primarySeg = _primarySeg;
    // 2026-09-06 页头动作进工具条 trailing：与分类分段/搜索同一行
    // （紧凑断点自动换行到搜索下方），不再单独占一行。
    final action = _p.primaryAction;
    final actionReady = action != null && _canUse(action);
    return Scaffold(
      appBar: UtenAppBar(
        title: _p.title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: SubcontractRoute.hub),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _controller.loading
                ? null
                : () {
                    _reload();
                    _loadBadge();
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s16,
          ),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              // 2026-09-22 全站表格滚动口径：与采购/销售单据列表对齐——上滑先收
              // 分类条（表头随之顶到视口顶），继续滚动才滚表格内容；竖向滚动条
              // 由联动门控（外滚收头部阶段不显示）。
              return UtenCollapsingHeaderScrollView(
                collapsingHeader: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UtenFilterToolbar<_BizSeg>(
                      segmentsKey: Key(
                        'subcontract-biz-segments-${_p.type.name}',
                      ),
                      // 进行中同时含黄(待财审/执行中)与红(财务退回)，各与子类同源。
                      segments: [
                        UtenFilterSegment(
                          value: _draftSeg,
                          label: '草稿',
                          count: staged
                              ? bucket(DocumentStatusBucket.draft)
                              : (_actionableStatus == 0
                                    ? _actionableCount
                                    : null),
                          countForm: staged
                              ? UtenSegmentCountForm.actionable
                              : UtenSegmentCountForm.browsing,
                        ),
                        if (_isOrder)
                          UtenFilterSegment(
                            value: const _BizSeg.inProgress(),
                            label: '进行中',
                            count: bucket(DocumentStatusBucket.financeRejected),
                            countForm: UtenSegmentCountForm.actionable,
                            inProgressCount: ongoingCount,
                          ),
                        const UtenFilterSegment(
                          value: _BizSeg.history(),
                          label: '历史记录',
                        ),
                      ],
                      selected: primarySeg == null ? const {} : {primarySeg},
                      onSelectionChanged: _selectSeg,
                      searchHint: '搜索单据号',
                      initialSearchValue: _controller.keyword,
                      onSearchChanged: (value) {
                        _controller.keyword = value;
                        _reload(1);
                      },
                      trailing: actionReady
                          ? UtenButton(
                              key: Key(
                                'subcontract-biz-primary-action-${_p.type.name}',
                              ),
                              icon: action.icon,
                              onPressed: () => goFrom(context, action.route),
                              child: Text(action.label),
                            )
                          : null,
                    ),
                    if (primarySeg == const _BizSeg.inProgress()) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      UtenFilterToolbar<_BizSeg>(
                        segmentsKey: Key(
                          'subcontract-biz-substages-${_p.type.name}',
                        ),
                        segments: [
                          UtenFilterSegment(
                            value: const _BizSeg.stage(0, 'PENDING'),
                            label: '等待财务审核',
                            count: pendingCount,
                            countForm: UtenSegmentCountForm.inProgress,
                          ),
                          UtenFilterSegment(
                            value: const _BizSeg.stage(0, 'REJECTED'),
                            label: '财务已退回',
                            count: bucket(DocumentStatusBucket.financeRejected),
                            countForm: UtenSegmentCountForm.actionable,
                          ),
                          UtenFilterSegment(
                            value: const _BizSeg.stage(1, null, false),
                            label: '执行中',
                            count: executingCount,
                            countForm: UtenSegmentCountForm.inProgress,
                          ),
                        ],
                        selected: seg == primarySeg ? const {} : {seg!},
                        onSelectionChanged: _selectSeg,
                        trailing: _clearSubstageAction(),
                      ),
                    ],
                    if (seg?.history == true) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      UtenFilterToolbar<_BizSeg>(
                        segmentsKey: Key(
                          'subcontract-biz-history-stages-${_p.type.name}',
                        ),
                        segments: [
                          if (_isOrder)
                            const UtenFilterSegment(
                              value: _BizSeg.history(1, true),
                              label: '已结案',
                            )
                          else
                            UtenFilterSegment(
                              value: const _BizSeg.history(1),
                              label: '已审',
                              count: bucket(DocumentStatusBucket.approved),
                            ),
                          UtenFilterSegment(
                            value: const _BizSeg.history(-1),
                            label: '红冲',
                            count: bucket(DocumentStatusBucket.reversed),
                          ),
                        ],
                        selected: seg == primarySeg ? const {} : {seg!},
                        onSelectionChanged: _selectSeg,
                        trailing: _clearSubstageAction(),
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      UtenHistoryTimeFilter(
                        key: Key(
                          'subcontract-biz-history-time-${_p.type.name}',
                        ),
                        value: _historyTime,
                        onChanged: _onHistoryTime,
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                  ],
                ),
                body: seg == null
                    ? const UtenFilterPlaceholder()
                    : seg.history && _historyTime.isNone
                    ? const UtenHistoryTimePlaceholder()
                    : MasterDataTableView<SubcontractDocListItem>(
                        // primary:true → 表体参与「分类条折叠 → 表格内滚」联动。
                        primary: true,
                        columns: _p.columns(
                          names,
                          _canViewCommercial &&
                              !(_controller.result?.items.any(
                                    (row) => row.priceMasked,
                                  ) ??
                                  false),
                        ),
                        items:
                            _controller.result?.items ??
                            const <SubcontractDocListItem>[],
                        facets: {
                          'supplier': masterDictionaryFacets(
                            names.supplierEntries,
                          ),
                          'warehouse': masterDictionaryFacets(
                            names.warehouseEntries,
                          ),
                        },
                        nullCounts: const {},
                        filters: {
                          'supplier': _supplierIdFilter,
                          'warehouse': _warehouseIdFilter,
                        },
                        onFilterChanged: _onColumnFilterChanged,
                        onRowTap: (row) {
                          context.push(
                            SubcontractRoute.detail(
                              _p.type.pathSegment,
                              row.id,
                            ),
                          );
                        },
                        isLoading:
                            _controller.loading && _controller.result == null,
                        loadingMore:
                            _controller.loading && _controller.result != null,
                        error: _controller.error,
                        onRetry: _reload,
                        emptyMessage: seg.history
                            ? '该时间段内暂无记录'
                            : _p.emptyMessage,
                        currentPage: _controller.page,
                        totalPages: _controller.result?.totalPages ?? 1,
                        onPageChange: (p) => _reload(p),
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget? _clearSubstageAction() => _seg == _primarySeg
      ? null
      : TextButton.icon(
          onPressed: () => _selectSeg(_primarySeg!),
          icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
          label: const Text('清除状态筛选'),
        );
}

class _BusinessPagedController extends ChangeNotifier {
  PagedResult<SubcontractDocListItem>? result;
  bool loading = false;
  String? error;
  int page = 1;
  String keyword = '';
  int _requestId = 0;

  Future<void> load(
    int nextPage, {
    required Future<PagedResult<SubcontractDocListItem>> Function() fetch,
    bool silent = false,
  }) async {
    final requestId = ++_requestId;
    page = nextPage;
    loading = true;
    error = null;
    if (!silent) notifyListeners();
    try {
      final next = await fetch();
      if (requestId != _requestId) return;
      result = next;
      loading = false;
      notifyListeners();
    } catch (e) {
      if (requestId != _requestId) return;
      loading = false;
      error = e is ApiException ? e.message : '委外记录加载失败，请稍后重试';
      notifyListeners();
    }
  }
}

List<MasterColumnDef<SubcontractDocListItem>> _baseColumns({
  required mn.MasterNameService names,
  bool supplier = true,
  bool warehouse = false,
  bool commercial = false,
  bool weight = false,
  bool closed = false,
  String statusLabel = '状态',
}) => [
  MasterColumnDef(
    key: 'billNo',
    label: '单据号',
    width: 150,
    value: (row) => row.billNo,
  ),
  MasterColumnDef(
    key: 'billDate',
    label: '日期',
    width: 120,
    type: 'date',
    sortable: true,
    value: (row) => row.billDate,
  ),
  if (supplier)
    MasterColumnDef(
      key: 'supplier',
      label: '委外商',
      width: 200,
      value: (row) => names.supplier(row.supplierId),
    ),
  if (warehouse)
    MasterColumnDef(
      key: 'warehouse',
      label: '执行仓库',
      width: 170,
      value: (row) =>
          row.warehouseNameOverride ?? names.warehouse(row.warehouseId),
    ),
  if (commercial)
    MasterColumnDef(
      key: 'amount',
      label: '商业金额',
      width: 140,
      type: 'money',
      value: (row) =>
          row.priceMasked ? '***' : row.totalLocal?.toStringAsFixed(2),
    ),
  if (weight)
    MasterColumnDef(
      key: 'weight',
      label: '实物总重',
      width: 130,
      type: 'number',
      value: (row) => row.totalWeight?.toStringAsFixed(3),
    ),
  MasterColumnDef(
    key: 'status',
    label: statusLabel,
    width: 170,
    value: (row) => row.statusOverride ?? subcontractStatusLabel(row.status),
    // 状态徽章（草稿中性/已审绿/红冲红）；value 仍是纯文本供列宽/排序/筛选。
    cellBuilder: (_, row) => UtenStatusBadge(
      label: row.statusOverride ?? subcontractStatusLabel(row.status),
      type: docStatusBadgeType(row.status),
      size: UtenStatusBadgeSize.small,
    ),
  ),
  if (closed)
    MasterColumnDef(
      key: 'closed',
      label: '链路结案',
      width: 120,
      value: (row) => row.closed ? '已结案' : (row.status == 1 ? '执行中' : '—'),
    ),
];

List<MasterColumnDef<SubcontractDocListItem>> _orderColumns(
  mn.MasterNameService names,
  bool commercial,
) {
  final columns = _baseColumns(
    names: names,
    commercial: commercial,
    closed: true,
    statusLabel: '财务 / 执行状态',
  );
  final statusIndex = columns.indexWhere((column) => column.key == 'status');
  columns[statusIndex] = MasterColumnDef(
    key: 'status',
    label: '财务 / 执行状态',
    width: 190,
    value: _orderStatusText,
    // 财务态徽章：等待财务审核=警告黄 / 财务退回=危险红 / 财务已通过=成功绿 /
    // 待提交财务=中性 / 已红冲=危险红；value 仍是纯文本供列宽/排序/筛选。
    cellBuilder: (_, row) => UtenStatusBadge(
      label: _orderStatusText(row),
      type: _orderStatusBadgeType(row),
      size: UtenStatusBadgeSize.small,
    ),
  );
  return columns;
}

String _orderStatusText(SubcontractDocListItem row) {
  if (row.status == -1) return '已红冲';
  if (row.status == 1) {
    return row.closed ? '已结案' : '财务已通过 / 执行中';
  }
  final approval = row.financeApproval;
  if (approval?.isPending == true) return '等待财务审核';
  if (approval?.isRejected == true) return '财务退回待修改';
  if (approval?.isApproved == true) return '财务已通过';
  return '草稿 / 待提交财务';
}

UtenStatusBadgeType _orderStatusBadgeType(SubcontractDocListItem row) {
  if (row.status == -1) return UtenStatusBadgeType.danger;
  if (row.status == 1) return UtenStatusBadgeType.success;
  final approval = row.financeApproval;
  if (approval?.isPending == true) return UtenStatusBadgeType.warning;
  if (approval?.isRejected == true) return UtenStatusBadgeType.danger;
  if (approval?.isApproved == true) {
    return UtenStatusBadgeType.success;
  }
  return UtenStatusBadgeType.neutral;
}

List<MasterColumnDef<SubcontractDocListItem>> _legacyIssueColumns(
  mn.MasterNameService names,
  bool _,
) => _baseColumns(names: names, warehouse: true, statusLabel: '历史执行状态');

List<MasterColumnDef<SubcontractDocListItem>> _returnColumns(
  mn.MasterNameService names,
  bool commercial,
) => [
  ..._baseColumns(
    names: names,
    warehouse: true,
    commercial: commercial,
    statusLabel: '退回状态',
  ),
  MasterColumnDef(
    key: 'apReverse',
    label: '应付反向',
    width: 120,
    value: (row) => row.apPosted ? '已反立账' : '未反立账',
  ),
];

List<MasterColumnDef<SubcontractDocListItem>> _materialReturnColumns(
  mn.MasterNameService names,
  bool _,
) => _baseColumns(names: names, warehouse: true, statusLabel: '实收 / 台账状态');

List<MasterColumnDef<SubcontractDocListItem>> _wasteColumns(
  mn.MasterNameService names,
  bool _,
) => _baseColumns(
  names: names,
  warehouse: true,
  weight: true,
  statusLabel: '损耗确认状态',
);

List<MasterColumnDef<SubcontractDocListItem>> _inquiryColumns(
  mn.MasterNameService names,
  bool commercial,
) => _baseColumns(names: names, commercial: commercial, statusLabel: '历史状态');
