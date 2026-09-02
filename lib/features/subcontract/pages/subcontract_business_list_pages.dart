import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';
import '../repositories/subcontract_repository.dart';

/// 计划下达的委外申请登记簿：只读，不暴露商业订货字段或新建动作。
class SubcontractApplicationRegisterPage extends StatelessWidget {
  const SubcontractApplicationRegisterPage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.application,
      title: '计划委外申请',
      subtitle: '物料分析下达 · 委外端只读 · 未分解数量去任务中心处理',
      icon: Icons.assignment_outlined,
      primaryAction: _PageAction(
        label: '进入申请分解',
        icon: Icons.call_split_rounded,
        route: RouteName.operationsSubcontractWorkbench,
        requiredPermissions: [
          Perm.subcontractApplicationView,
          Perm.subcontractOrderView,
          Perm.subcontractOrderCreate,
          Perm.subcontractOrderDecompose,
        ],
      ),
      emptyMessage: '暂无计划下达的委外申请',
      columns: _applicationColumns,
    ),
  );
}

/// 委外订货与全链路工作页：两种来源汇合后，从财务审批跟到 IQC 与结案。
class SubcontractOrderWorkspacePage extends StatelessWidget {
  const SubcontractOrderWorkspacePage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.order,
      title: '委外订货与全链路',
      subtitle: '直接委外 / 物料分析委外 · 财务批准 · 目标件出仓 · 回厂 IQC · 结算',
      icon: Icons.precision_manufacturing_outlined,
      primaryAction: _PageAction(
        label: '直接委外下单',
        icon: Icons.add_rounded,
        route: '/subcontract/orders/new',
        requiredPermissions: [
          Perm.subcontractOrderView,
          Perm.subcontractOrderCreate,
        ],
      ),
      secondaryAction: _PageAction(
        label: '从申请分解下单',
        icon: Icons.call_split_rounded,
        route: RouteName.operationsSubcontractWorkbench,
        requiredPermissions: [
          Perm.subcontractApplicationView,
          Perm.subcontractOrderView,
          Perm.subcontractOrderCreate,
          Perm.subcontractOrderDecompose,
        ],
      ),
      showClosedFilter: true,
      emptyMessage: '暂无委外订货单',
      columns: _orderColumns,
    ),
  );
}

/// 委外回厂与品质跟踪：回厂审核立加工费 AP；品质放行后仍须仓库确认入库。
class SubcontractReceiptQualityTrackingPage extends StatelessWidget {
  const SubcontractReceiptQualityTrackingPage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.receipt,
      title: '委外回厂与品质跟踪',
      subtitle: '仓库登记回厂 · 先出后进校验 · IQC 隔离 · 仓库确认入仓',
      icon: Icons.fact_check_outlined,
      primaryAction: _PageAction(
        label: '去仓库预计到货',
        icon: Icons.warehouse_outlined,
        route: RouteName.warehouseInboundExpectations,
        requiredPermissions: [Perm.warehouseInboundView],
      ),
      emptyMessage: '暂无委外回厂记录',
      columns: _receiptColumns,
    ),
  );
}

/// V304 及更早材料/BOM 子件发料历史，仅供审计和反向兼容。
class SubcontractLegacyMaterialIssueHistoryPage extends StatelessWidget {
  const SubcontractLegacyMaterialIssueHistoryPage({super.key});

  @override
  Widget build(BuildContext context) => const _SubcontractBusinessListPage(
    presentation: _ListPresentation(
      type: SubcontractDocType.materialIssue,
      title: '历史委外发料记录',
      subtitle: '历史 BOM 子件发料兼容 · 新单请去仓库“委外出仓”',
      icon: Icons.history_rounded,
      primaryAction: _PageAction(
        label: '去仓库委外出仓',
        icon: Icons.outbound_outlined,
        route: RouteName.warehouseSubcontractOutbound,
        requiredPermissions: [Perm.subcontractOutboundView],
      ),
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
    this.secondaryAction,
    this.showClosedFilter = false,
  });

  final SubcontractDocType type;
  final String title;
  final String subtitle;
  final IconData icon;
  final String emptyMessage;
  final _ColumnsBuilder columns;
  final _PageAction? primaryAction;
  final _PageAction? secondaryAction;
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

class _SubcontractBusinessListPageState
    extends ConsumerState<_SubcontractBusinessListPage> {
  final _controller = _BusinessPagedController();
  int? _status;
  bool? _closed;
  String? _location;

  _ListPresentation get _p => widget.presentation;
  SubcontractDocConfig get _cfg => SubcontractDocConfig.by(_p.type);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(mn.masterNameServiceProvider).ensureLoaded();
      _reload(1);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<PagedResult<SubcontractDocListItem>> _fetch() => ref
      .read(subcontractRepositoryProvider(_p.type))
      .list(
        page: _controller.page,
        filter: SubcontractDocFilter(
          keyword: _controller.keyword.trim(),
          status: _status,
          closed: _closed,
        ),
      );

  Future<void> _reload([int? page, bool silent = false]) =>
      _controller.load(page ?? _controller.page, silent: silent, fetch: _fetch);

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
    ref.onPageResume(_location!, () => _reload(null, true));
    ref.listen(listRefreshTickProvider(_cfg.refreshKey), (_, _) => _reload());
    final names = ref.watch(mn.masterNameServiceProvider);
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
            onPressed: _controller.loading ? null : _reload,
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
                if ((_p.primaryAction != null && _canUse(_p.primaryAction!)) ||
                    (_p.secondaryAction != null &&
                        _canUse(_p.secondaryAction!))) ...[
                  _HeaderActions(
                    primary: _p.primaryAction,
                    secondary: _p.secondaryAction,
                    showPrimary:
                        _p.primaryAction != null && _canUse(_p.primaryAction!),
                    showSecondary:
                        _p.secondaryAction != null &&
                        _canUse(_p.secondaryAction!),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                ],
                _buildFilters(),
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: MasterDataTableView<SubcontractDocListItem>(
                    columns: _p.columns(
                      names,
                      _canViewCommercial &&
                          !(_controller.result?.items.any(
                                (row) => row.priceMasked,
                              ) ??
                              false),
                    ),
                    items: _controller.result?.items ?? const [],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: (row) => context.push(
                      SubcontractRoute.detail(_p.type.pathSegment, row.id),
                    ),
                    isLoading:
                        _controller.loading && _controller.result == null,
                    loadingMore:
                        _controller.loading && _controller.result != null,
                    error: _controller.error,
                    onRetry: _reload,
                    emptyMessage: _p.emptyMessage,
                    currentPage: _controller.page,
                    totalPages: _controller.result?.totalPages ?? 1,
                    onPageChange: _reload,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final search = SizedBox(
          width: compact ? double.infinity : 320,
          child: UtenSearchBar(
            hint: '搜索单据号',
            initialValue: _controller.keyword,
            onChanged: (value) {
              _controller.keyword = value;
              _reload(1);
            },
          ),
        );
        final status = Wrap(
          spacing: UtenSpacing.s4,
          runSpacing: UtenSpacing.s4,
          children: [
            for (final option in <(String, int?)>[
              ('全部', null),
              (_p.type == SubcontractDocType.application ? '尚未下达' : '草稿', 0),
              (_p.type == SubcontractDocType.application ? '计划已下达' : '已审', 1),
              ('红冲', -1),
            ])
              ChoiceChip(
                label: Text(option.$1, style: theme.textTheme.labelMedium),
                selected: _status == option.$2,
                onSelected: (_) {
                  setState(() => _status = option.$2);
                  _reload(1);
                },
              ),
          ],
        );
        final closed = _p.showClosedFilter
            ? Wrap(
                spacing: UtenSpacing.s4,
                children: [
                  for (final option in <(String, bool?)>[
                    ('全部结案状态', null),
                    ('执行中', false),
                    ('已结案', true),
                  ])
                    ChoiceChip(
                      label: Text(
                        option.$1,
                        style: theme.textTheme.labelMedium,
                      ),
                      selected: _closed == option.$2,
                      onSelected: (_) {
                        setState(() => _closed = option.$2);
                        _reload(1);
                      },
                    ),
                ],
              )
            : null;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: UtenSpacing.s8),
              status,
              if (closed != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                closed,
              ],
            ],
          );
        }
        return Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [search, status, ?closed],
        );
      },
    );
  }
}

class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.primary,
    required this.secondary,
    required this.showPrimary,
    required this.showSecondary,
  });

  final _PageAction? primary;
  final _PageAction? secondary;
  final bool showPrimary;
  final bool showSecondary;

  bool get hasActions =>
      (primary != null && showPrimary) || (secondary != null && showSecondary);

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: UtenSpacing.s8,
    runSpacing: UtenSpacing.s8,
    alignment: WrapAlignment.end,
    children: [
      if (secondary != null && showSecondary)
        UtenButton(
          type: UtenButtonType.secondary,
          icon: secondary!.icon,
          onPressed: () => goFrom(context, secondary!.route),
          child: Text(secondary!.label),
        ),
      if (primary != null && showPrimary)
        UtenButton(
          icon: primary!.icon,
          onPressed: () => goFrom(context, primary!.route),
          child: Text(primary!.label),
        ),
    ],
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
      value: (row) => names.warehouse(row.warehouseId),
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
    value: (row) => subcontractStatusLabel(row.status),
  ),
  if (closed)
    MasterColumnDef(
      key: 'closed',
      label: '链路结案',
      width: 120,
      value: (row) => row.closed ? '已结案' : '执行中',
    ),
];

List<MasterColumnDef<SubcontractDocListItem>> _applicationColumns(
  mn.MasterNameService names,
  bool _,
) => _baseColumns(
  names: names,
  supplier: false,
  warehouse: true,
  statusLabel: '计划状态',
);

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

List<MasterColumnDef<SubcontractDocListItem>> _receiptColumns(
  mn.MasterNameService names,
  bool commercial,
) => [
  ..._baseColumns(
    names: names,
    warehouse: true,
    commercial: commercial,
    statusLabel: '回厂单状态',
  ),
  MasterColumnDef(
    key: 'ap',
    label: '加工费应付',
    width: 130,
    value: (row) => row.apPosted ? '已立账' : '未审核 / 未立账',
  ),
];

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
