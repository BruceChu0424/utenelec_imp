// 仓库单据列表页（按 docType 参数化）：标题行 + 状态筛选 + 主档表格（tap→详情）。
//
// 2026-09-03 起统一「分类分段」范式（原 DocKpiBar 状态卡条退役）：
// UtenFilterToolbar 状态分段（草稿/已审/红冲，无「全部」段）+ 末尾「历史单据」段——
// - 默认不选：进页面不预选、不发请求，内容区显示引导占位（UtenFilterPlaceholder）；
// - 徽章只挂「草稿」段（待审待发），计数取后端 list(size:1) 全量口径；
// - DRAW 选中「已审」后出现小类行：出库进度（未出库/部分出库/已出完，无「全部」，
//   默认不选=不附加过滤）；
// - 历史单据段：内容区顶部渲染 UtenHistoryTimeFilter（时间段/全部），未选时间
//   不发请求显示引导占位；选中后按 dateFrom/dateTo 加载（不限状态）。
// 其余（折叠头+表格吸顶内滚、列表刷新 tick、返回即刷新、PagedListController
// 竞态状态机）保持原实现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

/// 状态分段值：真实单据状态（status 非空）或历史单据哨兵。
class _StockDocSeg {
  const _StockDocSeg.stage(int this.status) : history = false;
  const _StockDocSeg.history() : status = null, history = true;

  final int? status;
  final bool history;
  @override
  bool operator ==(Object other) =>
      other is _StockDocSeg &&
      other.status == status &&
      other.history == history;

  @override
  int get hashCode => Object.hash(status, history);
}

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

  /// 当前选中分段；null = 未选择引导态（不发请求）。
  _StockDocSeg? _seg;

  /// DRAW「已审」下的出库进度小类；null = 未选择（不附加过滤）。
  int? _issueStatus;

  /// 历史单据段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  /// 「草稿」段徽章计数；null = 加载中（不显示徽章）。
  int? _draftCount;

  bool get _isDraw => widget.docType == StockDocType.draw;

  /// DRAW 选中「已审」后才出现出库进度小类行（草稿/红冲/历史无出库进度语义）。
  bool get _showIssueRow =>
      _isDraw && _seg != null && _seg!.status == 1 && !_seg!.history;

  bool get _shouldLoad {
    final seg = _seg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _loadBadge();
    });
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  bool get _canCreate => DocumentPermissionCatalog.stockDocument.allows(
    ref.read(currentPermissionsProvider),
    DocumentPermissionAction.create,
  );

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<StockDocListItem>> _fetch() {
    final seg = _seg!;
    final range = seg.history ? _historyTime.range : null;
    final sort = _list.sortKey == 'total' ? null : _list.sortKey;
    return ref
        .read(stockDocRepositoryProvider(widget.docType))
        .list(
          page: _list.pageNum,
          filter: StockDocFilter(
            keyword: _list.normalizedKeyword,
            status: seg.history ? null : seg.status,
            issueStatus: _showIssueRow ? _issueStatus : null,
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
          ),
          sort: sort,
          order: sort == null ? null : _list.sortOrder,
        );
  }

  Future<void> _reload([int? page, bool silent = false]) {
    if (!_shouldLoad) return Future.value();
    return _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);
  }

  void _selectSeg(_StockDocSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      _issueStatus = null;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
    });
    if (!seg.history || !_historyTime.isNone) _reload(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _reload(1);
  }

  /// 「草稿」段计数（list size=1 取 total；失败保持 null 不显示徽章）。
  Future<void> _loadBadge() async {
    try {
      final r = await ref
          .read(stockDocRepositoryProvider(widget.docType))
          .list(size: 1, filter: const StockDocFilter(status: 0));
      if (!mounted) return;
      setState(() => _draftCount = r.total);
    } catch (_) {
      // 计数失败静默：徽章不显示，不影响列表。
    }
  }

  // ---- 列定义 -----------------------------------------------------------

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  List<MasterColumnDef<StockDocListItem>> _columns() {
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
      _loadBadge();
    });
    // 返回即刷新：从详情/编辑页（或任何页面）回到本列表时重拉当前页，
    // 即便对方未 bump tick（纯查看返回）也保证看到最新数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () => _reload(null, true));
    final seg = _seg;
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
            onPressed: () {
              _reload();
              _loadBadge();
            },
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
                // 「顶部折叠 + 表格吸顶内滚」：分类工具条随上滑收起腾出空间，
                // 标题行钉在表格上方常驻，表格占满剩余空间内部滚动。
                return UtenCollapsingHeaderScrollView(
                  collapsingHeader: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      UtenFilterToolbar<_StockDocSeg>(
                        segmentsKey: Key(
                          'stock-doc-segments-${widget.docType.code}',
                        ),
                        segments: [
                          UtenFilterSegment(
                            value: const _StockDocSeg.stage(0),
                            label: '草稿',
                            count: _draftCount,
                          ),
                          const UtenFilterSegment(
                            value: _StockDocSeg.stage(1),
                            label: '已审',
                          ),
                          const UtenFilterSegment(
                            value: _StockDocSeg.stage(-1),
                            label: '红冲',
                          ),
                          const UtenFilterSegment(
                            value: _StockDocSeg.history(),
                            label: '历史单据',
                          ),
                        ],
                        selected: seg == null ? const {} : {seg},
                        onSelectionChanged: _selectSeg,
                        searchHint: '搜索单据号', // TODO(l10n): 补 arb
                        initialSearchValue: _list.keyword,
                        onSearchChanged: (v) {
                          _list.keyword = v;
                          _reload(1);
                        },
                      ),
                      if (_showIssueRow) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        // DRAW 出库进度小类：已审领料单的细化筛选，
                        // 默认不选 = 不附加过滤（无「全部」段）。
                        UtenFilterToolbar<int>(
                          segmentsKey: Key(
                            'stock-doc-issue-${widget.docType.code}',
                          ),
                          segments: const [
                            UtenFilterSegment(value: 0, label: '未出库'),
                            UtenFilterSegment(value: 1, label: '部分出库'),
                            UtenFilterSegment(value: 2, label: '已出完'),
                          ],
                          selected: _issueStatus == null
                              ? const <int>{}
                              : {_issueStatus!},
                          onSelectionChanged: (value) {
                            setState(() => _issueStatus = value);
                            _reload(1);
                          },
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s8),
                    ],
                  ),
                  body: Column(
                    children: [
                      // 页面头：Icon + 标题 + 计数 + 新建。
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
                            if (_canCreate)
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
                      if (seg?.history == true) ...[
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s8,
                            left: UtenSpacing.s4,
                            right: UtenSpacing.s4,
                          ),
                          child: UtenHistoryTimeFilter(
                            key: Key(
                              'stock-doc-history-time-${widget.docType.code}',
                            ),
                            value: _historyTime,
                            onChanged: _onHistoryTime,
                          ),
                        ),
                      ],
                      Expanded(
                        child: seg == null
                            ? const UtenFilterPlaceholder()
                            : seg.history && _historyTime.isNone
                            ? const UtenHistoryTimePlaceholder()
                            : MasterDataTableView<StockDocListItem>(
                                // primary:true → 表体参与「分类条折叠 → 表格内滚」联动。
                                primary: true,
                                columns: _columns(),
                                items: _list.page?.items ?? const [],
                                facets: const {},
                                nullCounts: const {},
                                filters: const {},
                                onFilterChanged: (_, _) {},
                                sortColumn: _list.sortKey == 'total'
                                    ? null
                                    : _list.sortKey,
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
                                emptyMessage: seg.history
                                    ? '该时间段内暂无${widget.docType.label}'
                                    : '暂无${widget.docType.label}', // TODO(l10n): 补 arb
                                currentPage: _list.currentPage,
                                totalPages: _list.totalPages,
                                onPageChange: (p) => _reload(p),
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
