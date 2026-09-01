// 仓库任务中心 · 通用单据分段（新建 XXX + 历史 XXX 一体化工作台）。
//
// 出库/入库/领料任务中心里，仓库原生单据（其它出库/产成品出库/其它入库/产成品进仓/
// 生产领料/生产退料）共用本组件：状态分段（全部/草稿/已审/红冲，已审+红冲即历史；
// 徽章口径：草稿不计入待办数——单据草稿尚未进入待办流，各分段一律不挂徽章）
// +（DRAW/WDRAW 领退料另带出库进度分段）+ 全部分类栏下方的总结行
// （左「共 N 条」右「新建」按钮，按 stock_doc:create 门控）+ MasterDataTableView
// （双击进详情；新建/编辑/详情保存与审核都会 bump listRefreshTick，本组件据此重拉）。
// 对齐品质部检查结果页范式：小类行进页面不预选（数据等价于不过滤），
// 不再渲染 icon + 标题分段头——分类语境已由上方大类分段表达。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

class WarehouseStockDocSegment extends ConsumerStatefulWidget {
  const WarehouseStockDocSegment({
    super.key,
    required this.docType,
    this.keyword = '',
    this.createLabel,
    this.refreshTick = 0,
  });

  final StockDocType docType;

  /// 任务中心页级搜索框的关键字（300ms 防抖后的值）。
  final String keyword;

  /// 新建按钮文案；null = 不显示按钮（权限不足时也隐藏）。
  final String? createLabel;

  /// 父页面「返回即刷新」信号：变化时静默重拉当前页。
  final int refreshTick;

  @override
  ConsumerState<WarehouseStockDocSegment> createState() =>
      _WarehouseStockDocSegmentState();
}

class _WarehouseStockDocSegmentState
    extends ConsumerState<WarehouseStockDocSegment> {
  final _list = PagedListController<StockDocListItem>();
  int? _status; // null=全部
  bool _statusSelected = false; // 进页面不预选（空集 = 不过滤）
  int? _issueStatus; // DRAW/WDRAW 出库进度（null=全部）
  bool _issueStatusSelected = false;

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

  @override
  void didUpdateWidget(WarehouseStockDocSegment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick ||
        oldWidget.docType != widget.docType) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reload(1));
    }
  }

  bool get _canCreate =>
      widget.createLabel != null &&
      DocumentPermissionCatalog.stockDocument.allows(
        ref.read(currentPermissionsProvider),
        DocumentPermissionAction.create,
      );

  Future<PagedResult<StockDocListItem>> _fetch() {
    final sort = _list.sortKey == 'total' ? null : _list.sortKey;
    return ref
        .read(stockDocRepositoryProvider(widget.docType))
        .list(
          page: _list.pageNum,
          filter: StockDocFilter(
            keyword: _list.normalizedKeyword,
            status: _status,
            issueStatus: _issueStatus,
          ),
          sort: sort,
          order: sort == null ? null : _list.sortOrder,
        );
  }

  Future<void> _reload([int? page, bool silent = false]) =>
      _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);

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
    ref.watch(masterNameServiceProvider);
    // 详情/编辑页保存、审核、红冲成功都会 bump 本 docType 的 tick，据此重拉。
    ref.listen(listRefreshTickProvider(widget.docType.refreshKey), (_, _) {
      _reload();
    });
    final showIssueStatus =
        widget.docType == StockDocType.draw ||
        widget.docType == StockDocType.wdraw;
    return ListenableBuilder(
      listenable: _list,
      builder: (context, _) {
        final total = _list.total;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 小类行 1：单据状态（徽章口径：草稿不计入待办数，各段不挂）。
            // 进页面不预选——空集数据等价于「全部」不过滤。
            Padding(
              padding: const EdgeInsets.only(
                bottom: UtenSpacing.s8,
                left: UtenSpacing.s4,
                right: UtenSpacing.s4,
              ),
              child: UtenFilterToolbar<int?>(
                segmentsKey: Key(
                  'stock-doc-segment-status-${widget.docType.code}',
                ),
                segments: const [
                  UtenFilterSegment(value: null, label: '全部'),
                  UtenFilterSegment(value: 0, label: '草稿'),
                  UtenFilterSegment(value: 1, label: '已审'),
                  UtenFilterSegment(value: -1, label: '红冲'),
                ],
                selected: _statusSelected ? {_status} : const {},
                onSelectionChanged: (value) {
                  setState(() {
                    _status = value;
                    _statusSelected = true;
                  });
                  _reload(1);
                },
              ),
            ),
            // 小类行 2（领退料）：出库进度。进页面同样不预选。
            if (showIssueStatus)
              Padding(
                padding: const EdgeInsets.only(
                  bottom: UtenSpacing.s8,
                  left: UtenSpacing.s4,
                  right: UtenSpacing.s4,
                ),
                child: UtenFilterToolbar<int?>(
                  segmentsKey: Key(
                    'stock-doc-segment-issue-${widget.docType.code}',
                  ),
                  segments: const [
                    UtenFilterSegment(value: null, label: '全部进度'),
                    UtenFilterSegment(value: 0, label: '未出库'),
                    UtenFilterSegment(value: 1, label: '部分出库'),
                    UtenFilterSegment(value: 2, label: '已出完'),
                  ],
                  selected: _issueStatusSelected ? {_issueStatus} : const {},
                  onSelectionChanged: (value) {
                    setState(() {
                      _issueStatus = value;
                      _issueStatusSelected = true;
                    });
                    _reload(1);
                  },
                ),
              ),
            // 全部分类栏下方的总结行：左「共 N 条」右「新建」。
            Padding(
              padding: const EdgeInsets.only(
                bottom: UtenSpacing.s8,
                left: UtenSpacing.s4,
                right: UtenSpacing.s4,
              ),
              child: Row(
                children: [
                  Semantics(
                    liveRegion: true,
                    label: '共 $total 张${widget.docType.label}',
                    child: Text(
                      '共 $total 条 · 双击办理',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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
                      child: Text(widget.createLabel!),
                    ),
                ],
              ),
            ),
            Expanded(
              child: MasterDataTableView<StockDocListItem>(
                columns: _columns(),
                items: _list.page?.items ?? const [],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                sortColumn: _list.sortKey == 'total' ? null : _list.sortKey,
                sortAscending: _list.sortAsc,
                onSortChange: _onSortChange,
                onRowTap: (it) => context.push(
                  RoutePath.stockDocDetail(widget.docType.code, it.id),
                ),
                isLoading: _list.isLoadingFirst,
                loadingMore: _list.isLoadingMore,
                error: _list.error,
                onRetry: () => _reload(),
                emptyMessage: '暂无${widget.docType.label}',
                currentPage: _list.currentPage,
                totalPages: _list.totalPages,
                onPageChange: (p) => _reload(p),
              ),
            ),
          ],
        );
      },
    );
  }
}
