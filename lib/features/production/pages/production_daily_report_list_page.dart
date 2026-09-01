// 生产日报列表页（生产管理 / production_daily_report:view · 空结构保未来）。
//
// 老库 F_DateReport 从未启用（docs/数据迁移/23 §2.2），本期建空结构保未来启用零成本。
// UI 完整但预期 0 行。结构与生产计划单列表页同构（MasterDataTableView + 状态分段工具条）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_daily_report.dart';
import '../repositories/production_repository.dart';

class ProductionDailyReportListPage extends ConsumerStatefulWidget {
  const ProductionDailyReportListPage({super.key});

  @override
  ConsumerState<ProductionDailyReportListPage> createState() =>
      _ProductionDailyReportListPageState();
}

class _ProductionDailyReportListPageState
    extends ConsumerState<ProductionDailyReportListPage> {
  final _list = PagedListController<ProductionDailyReportListItem>();
  int? _statusFilter;
  bool _statusFilterSelected = false; // 进页面不预选（不选=不过滤）

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _reload(1);
    });
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  bool get _canCreate => DocumentPermissionCatalog.productionDailyReport.allows(
    ref.read(currentPermissionsProvider),
    DocumentPermissionAction.create,
  );

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<ProductionDailyReportListItem>> _fetch() => ref
      .read(productionDailyReportRepositoryProvider)
      .list(
        page: _list.pageNum,
        filter: ProductionDailyReportFilter(
          keyword: _list.normalizedKeyword,
          status: _statusFilter,
        ),
        sort: _list.sortKey,
        order: _list.sortOrder,
      );

  Future<void> _reload([int? page, bool silent = false]) =>
      _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);

  void _onStatus(int? s) {
    setState(() {
      _statusFilter = s;
      _statusFilterSelected = true;
    });
    _reload(1);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  List<MasterColumnDef<ProductionDailyReportListItem>> _columns(
    MasterNameService names,
  ) => <MasterColumnDef<ProductionDailyReportListItem>>[
    MasterColumnDef(
      key: 'billNo',
      label: '单据号',
      width: 140,
      value: (it) => it.billNo,
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '日期',
      width: 120,
      type: 'date',
      sortable: true,
      value: (it) => (it.billDate ?? '').substring(0, 10),
    ),
    MasterColumnDef(
      key: 'workshop',
      label: '车间',
      width: 140,
      value: (it) => names.department(it.departmentId),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (it) => productionStatusLabel(it.status),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    // 返回即刷新：从详情/编辑页（保存/审核/删除后）回到本列表时静默重拉当前页，
    // 不再停留在进入子页前的老数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () => _reload(null, true));
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产日报表',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _reload(),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: ListenableBuilder(
              listenable: _list,
              builder: (context, _) {
                final total = _list.total;
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: UtenSpacing.s8,
                        left: UtenSpacing.s4,
                        right: UtenSpacing.s4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.edit_calendar_outlined,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Text(
                            '日报 ($total)',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          Expanded(
                            child: UtenSearchBar(
                              hint: '搜索单据号',
                              initialValue: _list.keyword,
                              onChanged: (v) {
                                _list.keyword = v;
                                _reload(1);
                              },
                            ),
                          ),
                          if (_canCreate) ...[
                            const SizedBox(width: UtenSpacing.s8),
                            UtenButton(
                              type: UtenButtonType.tonal,
                              icon: Icons.add_rounded,
                              onPressed: () =>
                                  context.push('/production/daily-reports/new'),
                              child: const Text('新建'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: UtenSpacing.s8,
                        left: UtenSpacing.s4,
                      ),
                      // 全平台统一筛选工具条：状态分段（搜索框在上方标题行，不在此收口）。
                      child: UtenFilterToolbar<int?>(
                        segments: const [
                          UtenFilterSegment(value: null, label: '全部'),
                          UtenFilterSegment(
                            value: kProductionStatusDraft,
                            label: '草稿',
                          ),
                          UtenFilterSegment(
                            value: kProductionStatusApproved,
                            label: '已审',
                          ),
                          UtenFilterSegment(
                            value: kProductionStatusReversed,
                            label: '红冲',
                          ),
                        ],
                        selected: _statusFilterSelected
                            ? {_statusFilter}
                            : const {},
                        onSelectionChanged: _onStatus,
                      ),
                    ),
                    Expanded(
                      child: MasterDataTableView<ProductionDailyReportListItem>(
                        columns: _columns(names),
                        items: _list.page?.items ?? const [],
                        facets: const {},
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                        sortColumn: _list.sortKey,
                        sortAscending: _list.sortAsc,
                        onSortChange: _onSortChange,
                        onRowTap: (it) =>
                            context.push('/production/daily-reports/${it.id}'),
                        isLoading: _list.isLoadingFirst,
                        loadingMore: _list.isLoadingMore,
                        error: _list.error,
                        onRetry: () => _reload(),
                        emptyMessage: '暂无日报数据',
                        currentPage: _list.currentPage,
                        totalPages: _list.totalPages,
                        onPageChange: (p) => _reload(p),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

}
