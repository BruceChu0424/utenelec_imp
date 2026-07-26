// 仓库单据列表页（按 docType 参数化）：标题行 + 状态筛选 + 主档表格（tap→详情）。
//
// 与 basic_data/pages/color_page.dart 同款布局：UtenAppBar + UtenContentContainer +
// 标题行(Icon+label+(N)+搜索+新建) + 状态 ChoiceChip Wrap + Expanded(MasterDataTableView)。
// 文档页无 facet → 表头渲染纯标签（MasterDataTableView 在 facets 为空时自动降级）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/widgets/doc_kpi_bar.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

class StockDocListPage extends ConsumerStatefulWidget {
  const StockDocListPage({super.key, required this.docType});
  final StockDocType docType;

  @override
  ConsumerState<StockDocListPage> createState() => _StockDocListPageState();
}

class _StockDocListPageState extends ConsumerState<StockDocListPage> {
  PagedResult<StockDocListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int? _status; // null=全部

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.stockDocEdit);

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref.read(stockDocRepositoryProvider(widget.docType)).list(
            page: page,
            filter: StockDocFilter(
                keyword: _keyword.trim().isEmpty ? null : _keyword,
                status: _status),
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
        _error = '加载列表失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  // ---- 列定义 -----------------------------------------------------------

  /// 各状态单据数（KPI 条用，并行 4 次 list size=1 取 total）。
  Future<int> _countStatus(int? s) async {
    try {
      final r = await ref.read(stockDocRepositoryProvider(widget.docType))
          .list(page: 1, size: 1, filter: StockDocFilter(status: s));
      return r.total;
    } catch (_) {
      return 0;
    }
  }

  List<MasterColumnDef<StockDocListItem>> get _columns {
    final isTransfer = widget.docType == StockDocType.transfer;
    return <MasterColumnDef<StockDocListItem>>[
      MasterColumnDef(
          key: 'billNo',
          label: '单据号',
          width: 160,
          value: (it) => it.billNo),
      MasterColumnDef(
          key: 'billDate',
          label: '日期',
          width: 120,
          value: (it) => it.billDate == null
              ? null
              : (it.billDate!.length >= 10
                  ? it.billDate!.substring(0, 10)
                  : it.billDate)),
      MasterColumnDef(
          key: 'warehouse',
          label: '仓库',
          width: 160,
          value: (it) =>
              ref.read(masterNameServiceProvider).warehouse(it.warehouseId)),
      if (isTransfer)
        MasterColumnDef(
            key: 'toWarehouse',
            label: '调入仓',
            width: 160,
            value: (it) => ref
                .read(masterNameServiceProvider)
                .warehouse(it.toWarehouseId)),
      MasterColumnDef(
          key: 'total',
          label: '合计',
          width: 140,
          value: (it) => it.totalLocal?.toStringAsFixed(2)),
      MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 100,
          value: (it) => stockStatusLabel(it.status)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _page?.total ?? 0;
    // watch 一下以在 ensureLoaded 完成（虽 Provider 实例不变，但语义上声明依赖）
    ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.docType.label,
        leading: UtenBackButton(
            onPressed: () => context.go(RouteName.warehouse)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
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
                      Icon(iconFor(widget.docType),
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text('${widget.docType.label} ($total)',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索单据号', // TODO(l10n): 补 arb
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
                              context.push(RoutePath.stockDocNew(widget.docType.code)),
                          child: const Text('新建'), // TODO(l10n): 补 arb
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8, left: UtenSpacing.s4),
                  child: DocKpiBar(
                    counter: _countStatus,
                    selected: _status,
                    onSelect: (s) {
                      setState(() => _status = s);
                      _load(1);
                    },
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<StockDocListItem>(
                    columns: _columns,
                    items: _page?.items ?? const [],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: (it) => context.push(
                        RoutePath.stockDocDetail(widget.docType.code, it.id)),
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _load(_pageNum),
                    emptyMessage: '暂无${widget.docType.label}', // TODO(l10n): 补 arb
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
}
