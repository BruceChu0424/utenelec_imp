// 生产日报列表页（生产管理 / production_daily_report:view · 空结构保未来）。
//
// 老库 F_DateReport 从未启用（docs/数据迁移/23 §2.2），本期建空结构保未来启用零成本。
// UI 完整但预期 0 行。结构与生产计划单列表页同构（MasterDataTableView + 状态 ChoiceChip）。
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
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../models/production_daily_report.dart';
import '../repositories/production_repository.dart';
import 'production_plan_list_page.dart' show ProductionPerm;

class ProductionDailyReportListPage extends ConsumerStatefulWidget {
  const ProductionDailyReportListPage({super.key});

  @override
  ConsumerState<ProductionDailyReportListPage> createState() =>
      _ProductionDailyReportListPageState();
}

class _ProductionDailyReportListPageState
    extends ConsumerState<ProductionDailyReportListPage> {
  PagedResult<ProductionDailyReportListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int? _statusFilter;
  // 列排序态：_sortKey=当前排序列 key（null=不排序，走后端默认 billDate DESC）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(ProductionPerm.dailyReportEdit);

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref.read(productionDailyReportRepositoryProvider).list(
            page: page,
            filter: ProductionDailyReportFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              status: _statusFilter,
            ),
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted) return;
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载列表失败';
        _loading = false;
      });
    }
  }

  void _onStatus(int? s) {
    setState(() => _statusFilter = s);
    _load(1);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _load(1);
  }

  List<MasterColumnDef<ProductionDailyReportListItem>> _columns(
          MasterNameService names) =>
      <MasterColumnDef<ProductionDailyReportListItem>>[
        MasterColumnDef(
            key: 'billNo', label: '单据号', width: 140, value: (it) => it.billNo),
        MasterColumnDef(
            key: 'billDate',
            label: '日期',
            width: 120,
            type: 'date',
            sortable: true,
            value: (it) => (it.billDate ?? '').substring(0, 10)),
        MasterColumnDef(
            key: 'warehouse',
            label: '仓库',
            width: 160,
            value: (it) => names.warehouse(it.warehouseId)),
        MasterColumnDef(
            key: 'workshop',
            label: '车间',
            width: 140,
            value: (it) => it.workshopName),
        MasterColumnDef(
            key: 'status',
            label: '状态',
            width: 100,
            value: (it) => productionStatusLabel(it.status)),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产日报表',
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.production)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _load(_pageNum),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(Icons.edit_calendar_outlined,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text('日报 ($total)',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索单据号',
                          initialValue: _keyword,
                          onChanged: (v) {
                            setState(() => _keyword = v);
                            _load(1);
                          },
                        ),
                      ),
                      if (_canEdit) ...[
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
                      bottom: UtenSpacing.s8, left: UtenSpacing.s4),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      _statusChip('全部', null),
                      _statusChip('草稿', kProductionStatusDraft),
                      _statusChip('已审', kProductionStatusApproved),
                      _statusChip('红冲', kProductionStatusReversed),
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<ProductionDailyReportListItem>(
                    columns: _columns(names),
                    items: _page?.items ?? const [],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    sortColumn: _sortKey,
                    sortAscending: _sortAsc,
                    onSortChange: _onSortChange,
                    onRowTap: (it) =>
                        context.push('/production/daily-reports/${it.id}'),
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _load(_pageNum),
                    emptyMessage: '暂无日报数据',
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    onPageChange: (p) => _load(p),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusChip(String label, int? value) {
    final selected = _statusFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _onStatus(value),
    );
  }
}
