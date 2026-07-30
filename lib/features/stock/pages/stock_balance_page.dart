// 库存余额查询页（库存管理，stock:view）：仓库筛选 + 余额列表（货品/仓库名解析）。
//
// 改为统一主档表格（MasterDataTableView）+ 桌面左筛选/右表格两栏（UtenListTwoPane），
// 与基础资料/单据列表同款；手机垂直堆叠。原手搓 ListTile + 手动分页已移除（复用统一组件）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_query.dart';
import '../repositories/stock_query_repository.dart';

class StockBalancePage extends ConsumerStatefulWidget {
  const StockBalancePage({super.key});

  @override
  ConsumerState<StockBalancePage> createState() => _StockBalancePageState();
}

class _StockBalancePageState extends ConsumerState<StockBalancePage> {
  PagedResult<BalanceRow>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  String? _warehouseId;
  // 列排序态：_sortKey=当前排序列 key（null=不排序，走后端默认 lastMovementDate DESC）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded().then((_) => _load(1));
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
      final r = await ref.read(stockQueryRepositoryProvider).balances(
            page: page,
            warehouseId: _warehouseId,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      final goodsIds =
          r.items.map((e) => e.goodsId).whereType<String>().toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() => _page = r);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '加载失败'); // TODO(l10n): 补 arb
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<MasterColumnDef<BalanceRow>> get _columns {
    final names = ref.read(masterNameServiceProvider);
    return <MasterColumnDef<BalanceRow>>[
      MasterColumnDef(
          key: 'goods',
          label: '货品', // TODO(l10n): 补 arb
          width: 220,
          value: (b) => names.goods(b.goodsId)),
      MasterColumnDef(
          key: 'warehouse',
          label: '仓库', // TODO(l10n): 补 arb
          width: 160,
          value: (b) => names.warehouse(b.warehouseId)),
      MasterColumnDef(
          key: 'color',
          label: '颜色', // TODO(l10n): 补 arb
          width: 120,
          value: (b) => names.color(b.colorId)),
      MasterColumnDef(
          key: 'qty',
          label: '数量', // TODO(l10n): 补 arb
          width: 120,
          type: 'number',
          sortable: true,
          value: (b) => (b.qty ?? 0).toStringAsFixed(2)),
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
    final names = ref.watch(masterNameServiceProvider);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '库存余额', // TODO(l10n): 补 arb
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.purchase)),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 页面头：Icon + 标题 + 计数
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(Icons.inventory_2_outlined,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text('余额 ($total)',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                // 桌面：左筛选侧栏（仓库）+ 右表格；手机：垂直堆叠
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
                            child: DropdownButtonFormField<String?>(
                              initialValue: _warehouseId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  isDense: true, labelText: '仓库'),
                              items: [
                                const DropdownMenuItem<String?>(
                                    child: Text('全部仓库')),
                                for (final e in names.warehouseEntries.entries)
                                  DropdownMenuItem<String?>(
                                      value: e.key, child: Text(e.value)),
                              ],
                              onChanged: (v) {
                                setState(() => _warehouseId = v);
                                _load(1);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    tablePane: MasterDataTableView<BalanceRow>(
                      columns: _columns,
                      items: _page?.items ?? const [],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      sortColumn: _sortKey,
                      sortAscending: _sortAsc,
                      onSortChange: _onSortChange,
                      // 行点击 → 出入库流水页（本行货品+仓库双过滤，push 保活本页筛选）
                      onRowTap: (b) {
                        final gid = b.goodsId;
                        if (gid == null || gid.isEmpty) return;
                        final wid = b.warehouseId;
                        context.push(
                            '${RouteName.stockMovement}?goodsId=$gid${wid == null ? '' : '&warehouseId=$wid'}');
                      },
                      isLoading: _loading && _page == null,
                      loadingMore: _loading && _page != null,
                      error: _error,
                      onRetry: () => _load(_pageNum),
                      emptyMessage: '暂无余额', // TODO(l10n): 补 arb
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
}
