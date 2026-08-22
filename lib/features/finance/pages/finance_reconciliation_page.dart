// 账户流水页（只读查询，finance_reconciliation:view）。
//
// 账户下拉过滤 + 关键词 + 来源单据类型。列表展示：单据号/账户/对手方/收入/支出/日期/摘要。
// 名称解析：账户用 FinanceNameService；账户下拉选项来自 FinanceNameService.accountEntries。
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
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';

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
  // 列排序态：_sortKey=当前排序列 key（null=不排序，走后端默认 billDate DESC）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  Future<void> _load(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(reconciliationRepositoryProvider)
          .list(
            page: page,
            filter: ReconciliationFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              accountId: _accountId,
            ),
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
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
        key: 'billNo',
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
        value: (it) => it.sourceDocType,
      ),
    ];
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
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
            onPressed: () => _load(_pageNum),
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
                  // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
                  primary: true,
                  columns: _columns(names),
                  items: _page?.items ?? const [],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  sortColumn: _sortKey,
                  sortAscending: _sortAsc,
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
