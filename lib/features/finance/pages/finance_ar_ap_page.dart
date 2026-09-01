// 应收应付台账页（只读查询，ar_ap_ledger:view）。
//
// direction(AR/AP) + settled(全部/未清/已清) 双向过滤 + 关键词 + 日期范围。
// 列表展示：单据号/来源单号/方向/往来方/到期日/结账方式/金额/备注/状态。
// 名称解析：AR→客户 / AP→供应商（FinanceNameService）。往来方显示用 partyId + direction。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/finance_table_facets.dart';

const Map<int, String> financeArApSettlementStyleLabels = {
  1: '现金',
  2: '提货',
  3: '代付',
  4: '支票',
  6: '月结',
  7: '垫付',
  8: '汇款',
  10: '代收',
};

String financeArApSettlementStyleLabel(int? code) =>
    financeArApSettlementStyleLabels[code] ?? '未设置';

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
  final _loadRequests = LatestRequestGuard();
  String _keyword = '';
  String? _direction; // null=全部 / AR / AP
  String? _sourceDocType;
  String? _partyId;
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
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(arApLedgerRepositoryProvider)
          .list(
            page: page,
            filter: ArApFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              direction: _direction,
              sourceDocType: _sourceDocType,
              partyId: _partyId,
              settled: _settled,
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
        _error = '加载台账失败';
        _loading = false;
      });
    }
  }

  List<MasterColumnDef<ArApLedgerItem>> _columns(FinanceNameService names) {
    String directionLabel({
      required String ar,
      required String ap,
      required String mixed,
    }) => switch (_direction) {
      'AR' => ar,
      'AP' => ap,
      _ => mixed,
    };

    String dateLabel(String? value) {
      if (value == null || value.isEmpty) return '—';
      return value.length <= 10 ? value : value.substring(0, 10);
    }

    String partyLabel(ArApLedgerItem it) {
      if (it.direction == 'AR') {
        return it.clientName ?? names.client(it.clientId);
      }
      if (it.direction == 'AP') {
        return it.supplierName ?? names.supplier(it.supplierId);
      }
      return '—';
    }

    return <MasterColumnDef<ArApLedgerItem>>[
      MasterColumnDef(
        key: 'billNo',
        label: '单据号',
        width: 150,
        value: (it) => it.billNo,
      ),
      MasterColumnDef(
        key: 'direction',
        label: '方向',
        width: 80,
        value: (it) =>
            it.direction == 'AR' ? '应收' : (it.direction == 'AP' ? '应付' : '—'),
      ),
      MasterColumnDef(
        key: 'sourceDocType',
        label: '来源类型',
        width: 120,
        value: (it) => financeArApSourceTypeLabel(it.sourceDocType),
      ),
      MasterColumnDef(
        key: 'openItemKind',
        label: '往来项目',
        width: 110,
        value: (it) => financeArApOpenItemKindLabel(it.openItemKind),
      ),
      if (_direction != 'AP')
        MasterColumnDef(
          key: 'salesOrderNos',
          label: '销售订单号',
          width: 190,
          value: (it) =>
              it.salesOrderNos.isEmpty ? '—' : it.salesOrderNos.join('、'),
        ),
      MasterColumnDef(
        key: 'sourceDocNo',
        label: '来源单号',
        width: 160,
        value: (it) => it.sourceDocNo,
      ),
      MasterColumnDef(
        key: 'party',
        label: directionLabel(ar: '客户', ap: '供应商', mixed: '往来方'),
        width: 200,
        value: partyLabel,
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '立帐日',
        width: 120,
        type: 'date',
        sortable: true,
        value: (it) => dateLabel(it.billDate),
      ),
      MasterColumnDef(
        key: 'dueDate',
        label: '到期日',
        width: 120,
        type: 'date',
        value: (it) => dateLabel(it.dueDate),
      ),
      MasterColumnDef(
        key: 'settlementStyleLegacy',
        label: '结账方式',
        width: 100,
        value: (it) =>
            financeArApSettlementStyleLabel(it.settlementStyleLegacy),
      ),
      MasterColumnDef(
        key: 'currency',
        label: '币别',
        width: 90,
        value: (it) =>
            financeCurrencyDisplayLabel(
              name: it.currencyName,
              code: it.currencyCode,
            ) ??
            '—',
      ),
      MasterColumnDef(
        key: 'exchangeRate',
        label: '立账汇率',
        width: 100,
        type: 'number',
        value: (it) => it.exchangeRate?.toStringAsFixed(6),
      ),
      MasterColumnDef(
        key: 'amountOriginal',
        label: directionLabel(ar: '应收款金额', ap: '应付款金额', mixed: '立账金额'),
        width: 130,
        type: 'money',
        value: (it) => it.amountOriginal?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'amountReceivedOriginal',
        label: directionLabel(ar: '已收款金额', ap: '已付款金额', mixed: '已结算金额'),
        width: 130,
        type: 'money',
        value: (it) => it.amountReceivedOriginal?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'amountWriteOffOriginal',
        label: '冲销金额',
        width: 120,
        type: 'money',
        value: (it) => it.amountWriteOffOriginal?.toStringAsFixed(2),
      ),
      if (_direction != 'AP')
        MasterColumnDef(
          key: 'prepaymentAppliedOriginal',
          label: '预收已抵',
          width: 120,
          type: 'money',
          value: (it) => it.prepaymentAppliedOriginal,
        ),
      MasterColumnDef(
        key: 'amountBalanceOriginal',
        label: directionLabel(ar: '未收金额', ap: '未付金额', mixed: '未结金额'),
        width: 130,
        type: 'money',
        value: (it) => it.amountBalanceOriginal?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'amountBalance',
        label: directionLabel(ar: '未收人民币', ap: '未付人民币', mixed: '未结人民币'),
        width: 130,
        type: 'money',
        sortable: true,
        value: (it) => it.amountBalance?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'settled',
        label: '已结',
        width: 80,
        value: (it) => it.settled ? '是' : '否',
      ),
      MasterColumnDef(
        key: 'remark',
        label: '备注',
        width: 180,
        value: (it) => it.remark,
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

  void _onColumnFilterChanged(String key, String? value) {
    setState(() {
      switch (key) {
        case 'direction':
          _direction = value;
          _partyId = null;
          break;
        case 'sourceDocType':
          _sourceDocType = value;
          break;
        case 'party':
          _partyId = value;
          break;
        case 'settled':
          _settled = value == null ? null : value == 'true';
          break;
      }
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
                      Icons.account_balance_wallet_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      '台账 ($total)',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              // 桌面：左筛选侧栏（搜索 + 方向/状态 Chip）+ 右表格；手机：垂直堆叠
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
                      // 全平台统一筛选工具条：方向分段（纯分类无搜索）。
                      UtenFilterToolbar<String?>(
                        segments: const [
                          UtenFilterSegment<String?>(value: null, label: '全部'),
                          UtenFilterSegment<String?>(value: 'AR', label: '应收'),
                          UtenFilterSegment<String?>(value: 'AP', label: '应付'),
                        ],
                        selected: _direction,
                        onSelectionChanged: (v) {
                          setState(() {
                            _direction = v;
                            _partyId = null;
                          });
                          _load(1);
                        },
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      _filterLabel('状态'),
                      // 全平台统一筛选工具条：清结状态分段（纯分类无搜索）。
                      UtenFilterToolbar<bool?>(
                        segments: const [
                          UtenFilterSegment<bool?>(value: null, label: '全部'),
                          UtenFilterSegment<bool?>(value: false, label: '未清'),
                          UtenFilterSegment<bool?>(value: true, label: '已清'),
                        ],
                        selected: _settled,
                        onSelectionChanged: (v) {
                          setState(() => _settled = v);
                          _load(1);
                        },
                      ),
                    ],
                  ),
                ),
                tablePane: MasterDataTableView<ArApLedgerItem>(
                  // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
                  primary: true,
                  columns: _columns(names),
                  items: _page?.items ?? const [],
                  facets: {
                    'direction': financeArApDirectionFacets,
                    'sourceDocType': financeArApSourceTypeFacets,
                    'party': financeDictionaryFacets(
                      _direction == 'AP'
                          ? names.supplierEntries
                          : _direction == 'AR'
                          ? names.clientEntries
                          : {...names.clientEntries, ...names.supplierEntries},
                    ),
                    'settled': financeArApSettledFacets,
                  },
                  nullCounts: const {},
                  filters: {
                    'direction': _direction,
                    'sourceDocType': _sourceDocType,
                    'party': _partyId,
                    'settled': _settled?.toString(),
                  },
                  onFilterChanged: _onColumnFilterChanged,
                  sortColumn: _sortKey,
                  sortAscending: _sortAsc,
                  onSortChange: _onSortChange,
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
}
