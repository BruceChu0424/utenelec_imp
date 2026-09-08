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
// 2026-09-03 起统一「分类分段」范式（原 ChoiceChip 状态行退役）：
// UtenFilterToolbar 阶段分段（草稿/已审/红冲，无「全部」段）+ 末尾「历史记录」
// 段——默认不选不发请求；徽章只挂待处理段（其余=草稿；历史兼容页不挂）；
// 订货页结案状态转小类行（执行中/已结案，无「全部结案状态」，选中阶段后出现）；
// 历史记录段时间门控（UtenHistoryTimeFilter，未选时间不发请求）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
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
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';
import '../repositories/subcontract_repository.dart';

/// 委外订货与全链路工作页：两种来源汇合后，从财务审批跟到 IQC 与结案。
class SubcontractOrderWorkspacePage extends StatelessWidget {
  const SubcontractOrderWorkspacePage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.order,
      title: '委外订货与全链路',
      subtitle: '直接委外 / 任务中心下单 · 财务批准 · 目标件出仓 · 回厂 IQC · 结算',
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
      showClosedFilter: true,
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
      subtitle: '历史 BOM 子件发料兼容 · 新单在仓库「委外出仓」工作台办理',
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
      subtitle: '绑定回厂 / IQC 处置 · 反向加工费应付 · 不允许空白新建',
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
      subtitle: '绑定委外商处台账 · 仓库实收入库 · 对称减少供应商结存',
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
      subtitle: '实物损耗确认 · 超耗责任另审 · 索赔/抵销/赔偿不得混写',
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
      subtitle: '当前业务未启用 · 仅保留兼容查询',
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
    required this.subtitle,
    required this.icon,
    required this.emptyMessage,
    required this.columns,
    this.primaryAction,
    this.showClosedFilter = false,
  });

  final SubcontractDocType type;
  final String title;
  final String subtitle;
  final IconData icon;
  final String emptyMessage;
  final _ColumnsBuilder columns;
  final _PageAction? primaryAction;
  final bool showClosedFilter;
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
  const _SubcontractBusinessListPage({required this.presentation});

  final _ListPresentation presentation;

  @override
  ConsumerState<_SubcontractBusinessListPage> createState() =>
      _SubcontractBusinessListPageState();
}

/// 状态分段值：真实单据状态（status 非空）或历史记录哨兵。
class _BizSeg {
  const _BizSeg.stage(int this.status) : history = false;
  const _BizSeg.history() : status = null, history = true;

  final int? status;
  final bool history;
  @override
  bool operator ==(Object other) =>
      other is _BizSeg && other.status == status && other.history == history;

  @override
  int get hashCode => Object.hash(status, history);
}

class _SubcontractBusinessListPageState
    extends ConsumerState<_SubcontractBusinessListPage> {
  final _controller = _BusinessPagedController();

  /// 当前选中分段；null = 未选择引导态（不发请求）。
  _BizSeg? _seg;

  /// 订货页结案状态小类（执行中/已结案）；null = 未选择（不附加过滤）。
  bool? _closed;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  /// 待处理段徽章计数；null = 加载中（不显示徽章）。
  int? _actionableCount;

  String? _location;

  _ListPresentation get _p => widget.presentation;
  SubcontractDocConfig get _cfg => SubcontractDocConfig.by(_p.type);

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
            status: seg.history ? null : seg.status,
            closed: seg.history ? null : _closed,
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
      _closed = null;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
    });
    if (!seg.history || !_historyTime.isNone) _reload(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _reload(1);
  }

  /// 待处理段计数（list size=1 取 total；失败保持 null 不显示徽章）。
  Future<void> _loadBadge() async {
    final status = _actionableStatus;
    if (status == null) return;
    try {
      final docs = await ref
          .read(subcontractRepositoryProvider(_p.type))
          .list(size: 1, filter: SubcontractDocFilter(status: status));
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
    _location ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_location!, () {
      _reload(null, true);
      _loadBadge();
    });
    ref.listen(listRefreshTickProvider(_cfg.refreshKey), (_, _) {
      _reload();
      _loadBadge();
    });
    final names = ref.watch(mn.masterNameServiceProvider);
    final seg = _seg;
    // 2026-09-06 页头动作进工具条 trailing：与分类分段/搜索同一行
    // （紧凑断点自动换行到搜索下方），不再单独占一行。
    final action = _p.primaryAction;
    final actionReady = action != null && _canUse(action);
    return Scaffold(
      appBar: UtenAppBar(
        title: _p.title,
        subtitle: _p.subtitle,
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
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 主分类行：阶段分段（无「全部」）+ 末尾「历史记录」+ 动作按钮同行。
                UtenFilterToolbar<_BizSeg>(
                  segmentsKey: Key('subcontract-biz-segments-${_p.type.name}'),
                  segments: [
                    UtenFilterSegment(
                      value: const _BizSeg.stage(0),
                      label: '草稿',
                      count: _actionableStatus == 0 ? _actionableCount : null,
                    ),
                    const UtenFilterSegment(
                      value: _BizSeg.stage(1),
                      label: '已审',
                    ),
                    const UtenFilterSegment(
                      value: _BizSeg.stage(-1),
                      label: '红冲',
                    ),
                    const UtenFilterSegment(
                      value: _BizSeg.history(),
                      label: '历史记录',
                    ),
                  ],
                  selected: seg == null ? const {} : {seg},
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
                // 订货页结案状态小类行：选中阶段后出现（无「全部结案状态」，默认不选）。
                if (_p.showClosedFilter && seg != null && !seg.history) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  UtenFilterToolbar<bool>(
                    segmentsKey: Key('subcontract-biz-closed-${_p.type.name}'),
                    segments: const [
                      UtenFilterSegment(value: false, label: '执行中'),
                      UtenFilterSegment(value: true, label: '已结案'),
                    ],
                    selected: _closed == null ? const <bool>{} : {_closed!},
                    onSelectionChanged: (value) {
                      setState(() => _closed = value);
                      _reload(1);
                    },
                  ),
                ],
                if (seg?.history == true) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  UtenHistoryTimeFilter(
                    key: Key('subcontract-biz-history-time-${_p.type.name}'),
                    value: _historyTime,
                    onChanged: _onHistoryTime,
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: seg == null
                      ? const UtenFilterPlaceholder()
                      : seg.history && _historyTime.isNone
                      ? const UtenHistoryTimePlaceholder()
                      : MasterDataTableView<SubcontractDocListItem>(
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
                          facets: const {},
                          nullCounts: const {},
                          filters: const {},
                          onFilterChanged: (_, _) {},
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
  ),
  if (closed)
    MasterColumnDef(
      key: 'closed',
      label: '链路结案',
      width: 120,
      value: (row) => row.closed ? '已结案' : '执行中',
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
    value: (row) {
      final approval = row.financeApproval;
      if (approval?.isPending == true) return '等待财务审核';
      if (approval?.isRejected == true) return '财务退回待修改';
      if (row.status == 1 || approval?.isApproved == true) return '财务已通过 / 执行中';
      if (row.status == -1) return '已红冲';
      return '草稿 / 待提交财务';
    },
  );
  return columns;
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
