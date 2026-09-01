// 采购单据列表页（按 docType 参数化）。
//
// 复用基础资料布局：UtenAppBar(标题/返回/刷新) + UtenContentContainer > 标题行
// (Icon+label+(N)+搜索+新建) + 状态筛选(ChoiceChip Wrap) + MasterDataTableView。
// 过滤由本页自带的状态 ChoiceChip + 关键词搜索承担（facets 传空，表头降级为纯标签）。
// 名称解析（供应商/仓库）通过 MasterNameService。编辑按 edit 权限显隐「新建」。
// 分页/竞态/静默刷新状态机在共享 PagedListController（本页只留状态筛选与列定义）。
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
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';

class PurchaseDocListPage extends ConsumerStatefulWidget {
  const PurchaseDocListPage({super.key, required this.docType});
  final PurchaseDocType docType;

  @override
  ConsumerState<PurchaseDocListPage> createState() =>
      _PurchaseDocListPageState();
}

class _PurchaseDocListPageState extends ConsumerState<PurchaseDocListPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  final _list = PagedListController<PurchaseDocListItem>();

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;
  int? _statusFilter; // null=全部

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

  bool get _canCreate {
    final permission = _cfg.createPerm;
    return _cfg.allowDirectCreate &&
        permission != null &&
        ref.read(currentPermissionsProvider).contains(permission);
  }

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<PurchaseDocListItem>> _fetch() => ref
      .read(purchaseRepositoryProvider(widget.docType))
      .list(
        page: _list.pageNum,
        filter: PurchaseDocFilter(
          keyword: _list.normalizedKeyword,
          status: _statusFilter,
        ),
        sort: _list.sortKey,
        order: _list.sortOrder,
      );

  Future<void> _reload([int? page, bool silent = false]) =>
      _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);

  void _onStatus(int? s) {
    setState(() => _statusFilter = s);
    _reload(1);
  }

  String _statusLabel(PurchaseDocListItem item) {
    if (widget.docType == PurchaseDocType.request && item.status == 1) {
      return '计划已下达';
    }
    if (widget.docType == PurchaseDocType.order) {
      return switch (item.financeApproval?.status) {
        'PENDING' => '等待财务审核',
        'REJECTED' => '财务退回',
        'APPROVED' => '财务已通过',
        'DRAFT' => '待提交财务',
        _ => purchaseStatusLabel(item.status),
      };
    }
    return purchaseStatusLabel(item.status);
  }

  List<MasterColumnDef<PurchaseDocListItem>> _columns(
    MasterNameService names, {
    required bool canViewCommercialAmounts,
  }) {
    return <MasterColumnDef<PurchaseDocListItem>>[
      MasterColumnDef(
        key: 'billNo',
        label: '单据号',
        width: 140,
        value: (it) => it.billNo,
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '日期',
        width: 120,
        type: 'date',
        sortable: true,
        value: (it) => (it.billDate ?? '').substring(0, 10),
      ),
      if (_cfg.hasSupplier)
        MasterColumnDef(
          key: 'supplier',
          label: '供应商',
          width: 200,
          value: (it) => names.supplier(it.supplierId),
        ),
      if (_cfg.hasWarehouse)
        MasterColumnDef(
          key: 'warehouse',
          label: '仓库',
          width: 160,
          value: (it) => names.warehouse(it.warehouseId),
        ),
      if (widget.docType != PurchaseDocType.request && canViewCommercialAmounts)
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
        width: widget.docType == PurchaseDocType.order ? 140 : 100,
        value: _statusLabel,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    // 操作后刷新：详情/编辑页保存/审核等成功会 bump 本 docType 的 tick，
    // 本页（即便被详情页遮在栈下）收到即重拉，返回不再看到老数据。
    ref.listen(listRefreshTickProvider(_cfg.refreshKey), (_, _) {
      _reload();
    });
    // 返回即刷新：从详情/编辑页（或任何页面）回到本列表时重拉当前页，
    // 即便对方未 bump tick（纯查看返回）也保证看到最新数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () => _reload(null, true));
    return Scaffold(
      appBar: UtenAppBar(
        title: _cfg.label,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.purchase),
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
                final canViewCommercialAmounts =
                    _cfg.canViewCommercial(
                      ref.watch(currentPermissionsProvider),
                    ) &&
                    !(_list.page?.items.any((item) => item.priceMasked) ??
                        false);
                // 与货品资料一致的「顶部折叠 + 表格吸顶内滚」：KPI 卡条随上滑
                // 收起腾出空间，标题行钉在表格上方常驻，表格占满剩余空间内部滚动。
                return UtenCollapsingHeaderScrollView(
                  collapsingHeader: Padding(
                    padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                    ),
                    // KPI 条：状态过滤 + 概览（横向 4 卡，上滑收起、下滑拉回）。
                    child: DocKpiBar(
                      counter: _countStatus,
                      selected: _statusFilter,
                      onSelect: _onStatus,
                    ),
                  ),
                  body: Column(
                    children: [
                      // 页面头：Icon + 标题 + 计数 + 新建按钮（搜索条挪到下方筛选区/侧栏）
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: UtenSpacing.s8,
                          left: UtenSpacing.s4,
                          right: UtenSpacing.s4,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _cfg.icon,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            Text(
                              '${_cfg.shortLabel} ($total)',
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
                                  RoutePath.purchaseDocNew(
                                    _cfg.type.pathSegment,
                                  ),
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
                            child: SizedBox(
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
                          ),
                          tablePane: MasterDataTableView<PurchaseDocListItem>(
                            // primary:true → 表体参与「KPI 卡折叠 → 表格内滚」联动。
                            primary: true,
                            columns: _columns(
                              names,
                              canViewCommercialAmounts:
                                  canViewCommercialAmounts,
                            ),
                            items: _list.page?.items ?? const [],
                            facets: const {},
                            nullCounts: const {},
                            filters: const {},
                            onFilterChanged: (_, _) {},
                            sortColumn: _list.sortKey,
                            sortAscending: _list.sortAsc,
                            onSortChange: (column, ascending) {
                              _list.onSortChange(column, ascending);
                              _reload(1);
                            },
                            onRowTap: (it) => context.push(
                              RoutePath.purchaseDocDetail(
                                _cfg.type.pathSegment,
                                it.id,
                              ),
                            ),
                            isLoading: _list.isLoadingFirst,
                            loadingMore: _list.isLoadingMore,
                            error: _list.error,
                            onRetry: () => _reload(),
                            emptyMessage:
                                '暂无${_cfg.shortLabel}单', // TODO(l10n): 补 arb
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

  /// 各状态单据数（KPI 条用，并行 4 次 list size=1 取 total）。
  Future<int> _countStatus(int? s) async {
    try {
      final r = await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .list(size: 1, filter: PurchaseDocFilter(status: s));
      return r.total;
    } catch (_) {
      return 0;
    }
  }
}
