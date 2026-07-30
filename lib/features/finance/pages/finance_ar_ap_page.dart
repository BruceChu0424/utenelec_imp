// 应收应付台账页（只读查询，ar_ap_ledger:view）。
//
// direction(AR/AP) + settled(全部/未清/已清) 双向过滤 + 关键词 + 日期范围。
// 列表展示：单据号/来源单号/方向/往来方/立帐额/已核销/余额/状态/已结。
// 名称解析：AR→客户 / AP→供应商（FinanceNameService）。往来方显示用 partyId + direction。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';

class FinanceArApPage extends ConsumerStatefulWidget {
  const FinanceArApPage({super.key});

  @override
  ConsumerState<FinanceArApPage> createState() => _FinanceArApPageState();
}

class _FinanceArApPageState extends ConsumerState<FinanceArApPage> {
  PagedResult<ArApLedgerItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  String? _direction; // null=全部 / AR / AP
  bool? _settled; // null=全部 / false=未清 / true=已清
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
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref.read(arApLedgerRepositoryProvider).list(
            page: page,
            filter: ArApFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              direction: _direction,
              settled: _settled,
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
        _error = '加载台账失败';
        _loading = false;
      });
    }
  }

  List<MasterColumnDef<ArApLedgerItem>> _columns(FinanceNameService names) {
    String partyLabel(ArApLedgerItem it) {
      if (it.direction == 'AR') return names.client(it.clientId);
      if (it.direction == 'AP') return names.supplier(it.supplierId);
      return '—';
    }

    return <MasterColumnDef<ArApLedgerItem>>[
      MasterColumnDef(
          key: 'billNo', label: '单据号', width: 150, value: (it) => it.billNo),
      MasterColumnDef(
          key: 'direction',
          label: '方向',
          width: 80,
          value: (it) => it.direction == 'AR' ? '应收' : (it.direction == 'AP' ? '应付' : '—')),
      MasterColumnDef(
          key: 'party', label: '往来方', width: 200, value: partyLabel),
      MasterColumnDef(
          key: 'billDate',
          label: '立帐日',
          width: 120,
          type: 'date',
          sortable: true,
          value: (it) => (it.billDate ?? '').substring(0, 10)),
      MasterColumnDef(
          key: 'amountOriginalLocal',
          label: '立帐额',
          width: 130,
          type: 'money',
          sortable: true,
          value: (it) => it.amountOriginalLocal?.toStringAsFixed(2)),
      MasterColumnDef(
          key: 'amountSettled',
          label: '已核销',
          width: 130,
          type: 'money',
          sortable: true,
          value: (it) => it.amountSettled?.toStringAsFixed(2)),
      MasterColumnDef(
          key: 'amountBalance',
          label: '余额',
          width: 130,
          type: 'money',
          sortable: true,
          value: (it) => it.amountBalance?.toStringAsFixed(2)),
      MasterColumnDef(
          key: 'settled',
          label: '已结',
          width: 80,
          value: (it) => it.settled ? '是' : '否'),
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
        title: '应收应付台账',
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.finance)),
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
            child: Column(
              children: [
                // 页面头：Icon + 标题 + 计数（搜索挪到下方筛选区/侧栏）
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(Icons.account_balance_wallet_outlined,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text('台账 ($total)',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                // 桌面：左筛选侧栏（搜索 + 方向/状态 Chip）+ 右表格；手机：垂直堆叠
                Expanded(
                  child: UtenListTwoPane(
                    filterPane: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: UtenSearchBar(
                              hint: '搜索单据号/来源单号',
                              initialValue: _keyword,
                              onChanged: (v) {
                                setState(() => _keyword = v);
                                _load(1);
                              },
                            ),
                          ),
                          const SizedBox(height: UtenSpacing.s16),
                          _filterLabel('方向'),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _dirChip('全部', null),
                              _dirChip('应收', 'AR'),
                              _dirChip('应付', 'AP'),
                            ],
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          _filterLabel('状态'),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _settledChip('全部', null),
                              _settledChip('未清', false),
                              _settledChip('已清', true),
                            ],
                          ),
                        ],
                      ),
                    ),
                    tablePane: MasterDataTableView<ArApLedgerItem>(
                      columns: _columns(names),
                      items: _page?.items ?? const [],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      sortColumn: _sortKey,
                      sortAscending: _sortAsc,
                      onSortChange: _onSortChange,
                      onRowTap: (_) {},
                      isLoading: _loading && _page == null,
                      loadingMore: _loading && _page != null,
                      error: _error,
                      onRetry: () => _load(_pageNum),
                      emptyMessage: '暂无台账记录',
                      currentPage: _page?.page ?? 1,
                      totalPages: _page?.totalPages ?? 1,
                      onPageChange: (p) => _load(p),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _filterLabel(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _dirChip(String label, String? value) {
    final selected = _direction == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        setState(() => _direction = value);
        _load(1);
      },
    );
  }

  Widget _settledChip(String label, bool? value) {
    final selected = _settled == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        setState(() => _settled = value);
        _load(1);
      },
    );
  }
}
