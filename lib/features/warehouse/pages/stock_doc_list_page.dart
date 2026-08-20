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
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/widgets/doc_kpi_bar.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

class StockDocListPage extends ConsumerStatefulWidget {
  const StockDocListPage({super.key, required this.docType});
  final StockDocType docType;

  @override
  ConsumerState<StockDocListPage> createState() => _StockDocListPageState();
}

class _StockDocListPageState extends ConsumerState<StockDocListPage> {
  final _list = PagedListController<StockDocListItem>();

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;
  int? _status; // null=全部
  int? _issueStatus; // DRAW 出库进度筛选（null=全部）

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

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.stockDocEdit);

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<StockDocListItem>> _fetch() => ref
      .read(stockDocRepositoryProvider(widget.docType))
      .list(
        page: _list.pageNum,
        filter: StockDocFilter(
          keyword: _list.normalizedKeyword,
          status: _status,
          issueStatus: _issueStatus,
        ),
        sort: _list.sortKey,
        order: _list.sortOrder,
      );

  Future<void> _reload([int? page, bool silent = false]) =>
      _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);

  // ---- 列定义 -----------------------------------------------------------

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  /// 各状态单据数（KPI 条用，并行 4 次 list size=1 取 total）。
  Future<int> _countStatus(int? s) async {
    try {
      final r = await ref
          .read(stockDocRepositoryProvider(widget.docType))
          .list(size: 1, filter: StockDocFilter(status: s));
      return r.total;
    } catch (_) {
      return 0;
    }
  }

  List<MasterColumnDef<StockDocListItem>> get _columns {
    final isTransfer = widget.docType == StockDocType.transfer;
    final isDraw = widget.docType == StockDocType.draw;
    return <MasterColumnDef<StockDocListItem>>[
      MasterColumnDef(
        key: 'billNo',
        label: '单据号',
        width: 160,
        value: (it) => it.billNo,
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '日期',
        width: 120,
        type: 'date',
        sortable: true,
        value: (it) => it.billDate == null
            ? null
            : (it.billDate!.length >= 10
                  ? it.billDate!.substring(0, 10)
                  : it.billDate),
      ),
      if (isDraw)
        MasterColumnDef(
          key: 'department',
          label: '领料车间',
          width: 140,
          value: (it) =>
              ref.read(masterNameServiceProvider).department(it.departmentId),
        ),
      MasterColumnDef(
        key: 'warehouse',
        label: '仓库',
        width: 160,
        value: (it) =>
            ref.read(masterNameServiceProvider).warehouse(it.warehouseId),
      ),
      if (isTransfer)
        MasterColumnDef(
          key: 'toWarehouse',
          label: '调入仓',
          width: 160,
          value: (it) =>
              ref.read(masterNameServiceProvider).warehouse(it.toWarehouseId),
        ),
      MasterColumnDef(
        key: 'total',
        label: '合计',
        width: 140,
        type: 'money',
        sortable: true,
        value: (it) => it.totalLocal?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 100,
        value: (it) => stockStatusLabel(it.status),
      ),
      if (isDraw)
        MasterColumnDef(
          key: 'issueStatus',
          label: '出库进度',
          width: 110,
          value: (it) => drawIssueStatusLabel(it.issueStatus),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // watch 一下以在 ensureLoaded 完成（虽 Provider 实例不变，但语义上声明依赖）
    ref.watch(masterNameServiceProvider);
    // 操作后刷新：详情/编辑页保存/审核等成功会 bump 本 docType 的 tick，
    // 本页（即便被详情页遮在栈下）收到即重拉，返回不再看到老数据。
    ref.listen(listRefreshTickProvider(widget.docType.refreshKey), (_, _) {
      _reload();
    });
    // 返回即刷新：从详情/编辑页（或任何页面）回到本列表时重拉当前页，
    // 即便对方未 bump tick（纯查看返回）也保证看到最新数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () => _reload(null, true));
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.docType.label,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: () => _reload(),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: ListenableBuilder(
              listenable: _list,
              builder: (context, _) {
                final total = _list.total;
                // 与货品资料一致的「顶部折叠 + 表格吸顶内滚」：KPI 状态卡条随上滑
                // 收起腾出空间，标题行钉在表格上方常驻，表格占满剩余空间内部滚动。
                return UtenCollapsingHeaderScrollView(
                  collapsingHeader: Padding(
                    padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                    ),
                    // KPI 状态条：状态过滤 + 概览（上滑收起、下滑拉回）。
                    child: DocKpiBar(
                      counter: _countStatus,
                      selected: _status,
                      onSelect: (s) {
                        setState(() => _status = s);
                        _reload(1);
                      },
                    ),
                  ),
                  body: Column(
                    children: [
                      // 页面头：Icon + 标题 + 计数 + 新建（搜索挪到下方筛选区/侧栏）
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: UtenSpacing.s8,
                          left: UtenSpacing.s4,
                          right: UtenSpacing.s4,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              iconFor(widget.docType),
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            Text(
                              '${widget.docType.label} ($total)',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            if (_canEdit)
                              UtenButton(
                                type: UtenButtonType.tonal,
                                icon: Icons.add_rounded,
                                onPressed: () => context.push(
                                  RoutePath.stockDocNew(widget.docType.code),
                                ),
                                child: const Text('新建'), // TODO(l10n): 补 arb
                              ),
                          ],
                        ),
                      ),
                      // 桌面：左筛选侧栏（搜索）+ 右表格；手机：垂直堆叠
                      Expanded(
                        child: UtenListTwoPane(
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
                                    hint: '搜索单据号', // TODO(l10n): 补 arb
                                    initialValue: _list.keyword,
                                    onChanged: (v) {
                                      _list.keyword = v;
                                      _reload(1);
                                    },
                                  ),
                                ),
                                // DRAW：出库进度筛选（未出库/部分出库=「未完成领料单」）
                                if (widget.docType == StockDocType.draw) ...[
                                  const SizedBox(height: UtenSpacing.s8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final (label, value) in [
                                        ('全部', null),
                                        ('未出库', 0),
                                        ('部分出库', 1),
                                        ('已出完', 2),
                                      ])
                                        ChoiceChip(
                                          label: Text(
                                            label,
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w400,
                                                ),
                                          ),
                                          selected: _issueStatus == value,
                                          onSelected: (_) {
                                            setState(
                                              () => _issueStatus = value,
                                            );
                                            _reload(1);
                                          },
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          tablePane: MasterDataTableView<StockDocListItem>(
                            // primary:true → 表体参与「KPI 卡折叠 → 表格内滚」联动。
                            primary: true,
                            columns: _columns,
                            items: _list.page?.items ?? const [],
                            facets: const {},
                            nullCounts: const {},
                            filters: const {},
                            onFilterChanged: (_, _) {},
                            sortColumn: _list.sortKey,
                            sortAscending: _list.sortAsc,
                            onSortChange: _onSortChange,
                            onRowTap: (it) => context.push(
                              RoutePath.stockDocDetail(
                                widget.docType.code,
                                it.id,
                              ),
                            ),
                            isLoading: _list.isLoadingFirst,
                            loadingMore: _list.isLoadingMore,
                            error: _list.error,
                            onRetry: () => _reload(),
                            emptyMessage:
                                '暂无${widget.docType.label}', // TODO(l10n): 补 arb
                            currentPage: _list.currentPage,
                            totalPages: _list.totalPages,
                            onPageChange: (p) => _reload(p),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
