// 账户流水页（只读查询，要求 account:view + account:balance:view + account:flow:view）。
//
// 账户下拉过滤 + 关键词 + 来源单据类型。列表展示：单据号/账户/对手方/收入/支出/日期/摘要。
// 名称解析：账户用 FinanceNameService；账户下拉选项来自 FinanceNameService.accountEntries。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/master_server_column_filters.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/finance_table_facets.dart';

String _entryKindLabel(String? value) => switch (value) {
  'POSTING' => '入账',
  'REVERSAL' => '反向冲销',
  'ADJUSTMENT' => '余额调整',
  _ => value ?? '—',
};

/// 「流水类型」列筛选桶（固定枚举，前端硬编码；count=0 表示不强调计数）。
const _entryKindFacets = [
  MasterFacetBucket(value: 'POSTING', count: 0, label: '入账'),
  MasterFacetBucket(value: 'REVERSAL', count: 0, label: '反向冲销'),
  MasterFacetBucket(value: 'ADJUSTMENT', count: 0, label: '余额调整'),
];

String _sourceDocTypeLabel(String? value) => switch (value) {
  'RECEIPT' => '销售收款',
  'PAYMENT' => '采购付款',
  'EXPENSE' => '一般费用',
  'INCOME' => '其它收入',
  'BANK_TRANSFER' => '银行存取',
  'BALANCE_ADJUSTMENT' => '余额调整',
  _ => value ?? '—',
};

class FinanceReconciliationPage extends ConsumerStatefulWidget {
  const FinanceReconciliationPage({super.key});

  @override
  ConsumerState<FinanceReconciliationPage> createState() =>
      _FinanceReconciliationPageState();
}

class _FinanceReconciliationPageState
    extends ConsumerState<FinanceReconciliationPage> {
  PagedResult<ReconciliationItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  String _keyword = '';
  String? _accountId;
  String? _sourceDocType;
  String? _entryKind;
  // 2026-09-25 单号列统一：单据号表头值筛选 + 服务端桶 + 列排序态
  // （共享状态，见 MasterServerColumnFilters；_sortColumn=null=不排序，走后端
  // 默认 billDate DESC）。
  final _columnFilters = MasterServerColumnFilters();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  /// 当前筛选组装（_load 与单号桶共用；[withBillNo] = false 供桶拉取）。
  ReconciliationFilter _reconFilter({bool withBillNo = true}) =>
      ReconciliationFilter(
        keyword: _keyword.trim().isEmpty ? null : _keyword,
        accountId: _accountId,
        sourceDocType: _sourceDocType,
        entryKind: _entryKind,
        billNo: withBillNo ? _columnFilters['billNo'] : null,
      );

  Future<void> _load(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    // 单号桶随列表口径重取（2026-09-25 单号列统一）。
    unawaited(_loadBillNoFacets());
    try {
      final r = await ref
          .read(reconciliationRepositoryProvider)
          .list(
            page: page,
            filter: _reconFilter(),
            sort: _columnFilters.sortColumn,
            order: _columnFilters.sortColumn == null
                ? null
                : (_columnFilters.sortAscending ? 'asc' : 'desc'),
          );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载流水失败';
        _loading = false;
      });
    }
  }

  /// 单据号值筛选桶随过滤上下文重取（失败静默保持旧桶，不阻断列表）。
  Future<void> _loadBillNoFacets() => _columnFilters.loadFacets(
    () async => {
      'billNo': await ref
          .read(reconciliationRepositoryProvider)
          .billNoFacets(filter: _reconFilter(withBillNo: false)),
    },
    onLoaded: () {
      if (mounted) setState(() {});
    },
  );

  List<MasterColumnDef<ReconciliationItem>> _columns(FinanceNameService names) {
    return <MasterColumnDef<ReconciliationItem>>[
      MasterColumnDef(
        key: 'billDate',
        label: '日期',
        width: 160,
        type: 'date',
        sortable: true,
        value: (it) => (it.billDate ?? '').substring(0, 16),
      ),
      MasterColumnDef(
        // 2026-09-25 单号列统一：可排序 + 表头值筛选（服务端 billNo 白名单/桶）。
        key: 'billNo',
        sortable: true,
        label: '单据号',
        width: 140,
        value: (it) => it.billNo,
      ),
      MasterColumnDef(
        key: 'accountId',
        label: '账户',
        width: 180,
        value: (it) => names.account(it.accountId),
      ),
      MasterColumnDef(
        key: 'counterpartName',
        label: '对手方',
        width: 160,
        value: (it) => it.counterpartName,
      ),
      MasterColumnDef(
        key: 'inAmount',
        label: '收入',
        width: 120,
        type: 'money',
        sortable: true,
        value: (it) =>
            it.inAmount == 0 ? null : it.inAmount?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'outAmount',
        label: '支出',
        width: 120,
        type: 'money',
        sortable: true,
        value: (it) =>
            it.outAmount == 0 ? null : it.outAmount?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'sourceDocType',
        label: '来源',
        width: 120,
        value: (it) => _sourceDocTypeLabel(it.sourceDocType),
      ),
      MasterColumnDef(
        key: 'entryKind',
        label: '流水类型',
        width: 120,
        value: (it) => _entryKindLabel(it.entryKind),
      ),
      MasterColumnDef(
        key: 'reversalOfId',
        label: '原流水 UUID',
        width: 280,
        value: (it) => it.reversalOfId,
      ),
    ];
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _columnFilters.handleSortChanged(column, ascending, onChanged: _refilter);
  }

  void _onColumnFilterChanged(String key, String? value) {
    if (key == 'billNo') {
      _columnFilters.handleFilterChanged(key, value, onChanged: _refilter);
      return;
    }
    setState(() {
      if (key == 'accountId') {
        _accountId = value;
      } else if (key == 'sourceDocType') {
        _sourceDocType = value;
      } else if (key == 'entryKind') {
        _entryKind = value;
      }
    });
    _load(1);
  }

  /// 服务端列筛选/排序落地后：setState 刷新表头 + 重拉回第 1 页。
  void _refilter() {
    setState(() {});
    _load(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '账户流水',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () {
              ref.read(financeNameServiceProvider).ensureLoaded();
              _load(1);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            // 「顶部折叠 + 表格吸顶内滚」：标题行随上滑收起腾出空间，
            // 筛选/表格区占满剩余空间、表体内部滚动（与单据列表页统一）。
            child: UtenCollapsingHeaderScrollView(
              // 页面头：Icon + 标题 + 计数（搜索挪到下方筛选区/侧栏）
              collapsingHeader: Padding(
                padding: const EdgeInsets.only(
                  bottom: UtenSpacing.s8,
                  left: UtenSpacing.s4,
                  right: UtenSpacing.s4,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.list_alt_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      '流水 ($total)',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              // 桌面：左筛选侧栏（搜索 + 账户）+ 右表格；手机：垂直堆叠
              body: UtenListTwoPane(
                filterPane: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: UtenSearchBar(
                          hint: '搜索单据号/对手方/支票号',
                          initialValue: _keyword,
                          onChanged: (v) {
                            setState(() => _keyword = v);
                            _load(1);
                          },
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      SizedBox(
                        width: double.infinity,
                        child: DropdownButtonFormField<String?>(
                          initialValue: _accountId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: '账户',
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              child: Text('全部账户'),
                            ),
                            for (final e in names.accountEntries.entries)
                              DropdownMenuItem<String?>(
                                value: e.key,
                                child: Text(
                                  e.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            setState(() => _accountId = v);
                            _load(1);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                tablePane: MasterDataTableView<ReconciliationItem>(
                  tableKey:
                      'features.finance.pages.finance_reconciliation_page.FinanceReconciliationPageState.build.1',
                  // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
                  primary: true,
                  columns: _columns(names),
                  items: _page?.items ?? const [],
                  facets: {
                    // 单据号桶与列表同一过滤口径（2026-09-25 单号列统一）。
                    'billNo': _columnFilters.bucketOf('billNo'),
                    'accountId': financeDictionaryFacets(names.accountEntries),
                    'sourceDocType': financeReconciliationSourceFacets,
                    'entryKind': _entryKindFacets,
                  },
                  nullCounts: const {},
                  filters: {
                    'billNo': _columnFilters['billNo'],
                    'accountId': _accountId,
                    'sourceDocType': _sourceDocType,
                    'entryKind': _entryKind,
                  },
                  onFilterChanged: _onColumnFilterChanged,
                  sortColumn: _columnFilters.sortColumn,
                  sortAscending: _columnFilters.sortAscending,
                  onSortChange: _onSortChange,
                  isLoading: _loading && _page == null,
                  loadingMore: _loading && _page != null,
                  error: _error,
                  onRetry: () => _load(_pageNum),
                  emptyMessage: '暂无流水',
                  currentPage: _page?.page ?? 1,
                  totalPages: _page?.totalPages ?? 1,
                  onPageChange: (p) => _load(p),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
