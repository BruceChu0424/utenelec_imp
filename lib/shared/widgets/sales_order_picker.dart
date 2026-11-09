import '../repositories/employee_reference_repository.dart';
import '../models/employee_reference.dart';
import '../paging/scoped_paged_read_view_mixin.dart';
// 销售订单选择器（右滑入单选）：跨模块共享（生产计划「来源单号」、财务客户预收选订单）。
//
// 生产视角：不展示客户/金额；列 = 单据号 / 日期 / 交货日期 / 销售员 / 状态。
// 销售员姓名/Id 由后端列表按 seller_id 解析下发（OrderListItem.seller*，经 EmployeeNameResolver）。
//
// 销售员筛选：sheet 内置「销售员」抽屉选择器（默认收敛到 MKT_CENTER 营销体系、搜索全公司、可清空），
// 默认值=调用方传入的 initialSeller（生产计划页传当前跟单员）。按所选销售员筛订单；为空则显示全部。
//
// 面板浮动留边（上/右/下 16px）+ 圆角阴影。状态固定已审（草稿/红冲不可作来源）。
// 数据源 salesRepositoryProvider(SalesDocType.order)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/inputs/uten_employee_picker.dart';
import '../../components/inputs/uten_search_bar.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../../components/layout/uten_adaptive_panel.dart';
import '../../components/layout/uten_panel_header.dart';
import '../../components/layout/uten_picker_confirm_bar.dart';
import '../../components/layout/uten_picker_footer_layout.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/basic_data/widgets/master_data_table_view.dart';
import '../models/department_node.dart';
import '../../features/sales/models/sales_doc.dart';
import '../../features/sales/repositories/sales_repository.dart';
import '../models/paged_result.dart';

// 调用方（财务预收等）只依赖列表项类型与已审状态常量，不再直接 import 销售 feature 模型。
export '../../features/sales/models/sales_doc.dart'
    show SalesDocListItem, kSalesStatusApproved;

/// 弹出右滑入销售订单选择器；返回所选订单（null=取消）。
/// [initialSeller]：默认销售员筛选（生产计划页传当前跟单员的 picker item）。
Future<SalesDocListItem?> showSalesOrderPicker(
  BuildContext context,
  WidgetRef ref, {
  UtenEmployeePickerItem? initialSeller,
  bool receiptSources = false,
}) {
  return showUtenAdaptivePanel<SalesDocListItem>(
    context: context,
    compactHeightFactor: 0.9,
    drawerWidth: 840,
    panelMargin: const EdgeInsetsDirectional.fromSTEB(0, 16, 16, 16),
    panelBorderRadius: BorderRadius.circular(UtenRadius.lg),
    panelElevation: 12,
    builder: (_) => _SalesOrderPickerSheet(
      initialSeller: initialSeller,
      receiptSources: receiptSources,
    ),
  );
}

class _SalesOrderPickerSheet extends ConsumerStatefulWidget {
  const _SalesOrderPickerSheet({
    this.initialSeller,
    this.receiptSources = false,
  });

  final UtenEmployeePickerItem? initialSeller;
  final bool receiptSources;

  @override
  ConsumerState<_SalesOrderPickerSheet> createState() =>
      _SalesOrderPickerSheetState();
}

class _SalesOrderPickerSheetState extends ConsumerState<_SalesOrderPickerSheet>
    with ScopedPagedReadViewMixin<_SalesOrderPickerSheet> {
  @override
  Future<void> onReadViewResumed() => _load(1, reconcileSelection: true);

  @override
  void scopedPagedReadOwnerChanged() {
    _loadGeneration++;
    if (mounted) {
      setState(() {
        _page = null;
        _picked = null;
        _loading = false;
        _error = null;
      });
    }
    if (mounted) {
      setState(() {
        _error = scopedPagedReadRejection?.message;
      });
    }
  }

  PagedResult<SalesDocListItem>? _page;
  final _pickerRows = MasterDataTableRowsController<SalesDocListItem>();
  bool _loading = false;
  int _loadGeneration = 0;
  String? _error;
  final _keywordCtl = TextEditingController();
  String _keyword = '';

  /// 当前销售员筛选（null=不筛，显示全部已审订单）。
  String? _selectedSellerId;
  UtenEmployeePickerItem? _selectedSeller;

  /// MKT_CENTER 营销体系部门 id（销售员抽屉默认范围）；树加载前为 null→抽屉暂按全公司。
  String? _marketingDeptId;

  String? _sortKey;
  bool _sortAsc = true;
  final Map<String, String?> _columnSearches = {};

  /// 已点选（高亮）的订单；底部「确定」才 pop 返回（二次操作契约）。
  SalesDocListItem? _picked;

  @override
  void initState() {
    super.initState();
    _selectedSeller = widget.initialSeller;
    _selectedSellerId = widget.initialSeller?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.receiptSources) {
        _resolveMarketingDept();
      }
      _load(1);
    });
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    super.dispose();
  }

  Future<void> _resolveMarketingDept() async {
    try {
      final tree = await ref
          .read(employeeReferenceRepositoryProvider)
          .departments(EmployeeReferencePurpose.salesOrderSellerFilter);
      final node = findDepartmentByCode(tree, kDeptCodeMarketing);
      if (node != null && mounted) {
        setState(() => _marketingDeptId = node.id);
      }
    } catch (_) {
      // 解析失败时销售员抽屉回退全公司，不阻塞选单。
    }
  }

  Future<void> _load(
    int page, {
    bool useCache = false,
    bool reconcileSelection = false,
  }) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    final repository = ref.read(salesRepositoryProvider(SalesDocType.order));
    final filter = SalesDocFilter(
      keyword: _keyword.trim().isEmpty ? null : _keyword,
      status: kSalesStatusApproved,
      sellerId: _selectedSellerId,
      columnSearch: Map.of(_columnSearches),
    );
    final sort = _sortKey;
    final order = sort == null ? null : (_sortAsc ? 'asc' : 'desc');
    Object pagingQuery() => [
      widget.receiptSources,
      if (widget.receiptSources) ref.read(apiClientProvider),
      ref.read(salesRepositoryProvider(SalesDocType.order)),
      _keyword,
      _selectedSellerId,
      _sortKey,
      _sortAsc,
      Map.of(_columnSearches),
      kSalesStatusApproved,
    ];
    try {
      final r = await readScopedPage<SalesDocListItem>(
        page,
        query: pagingQuery(),
        currentQuery: pagingQuery,
        useCache: useCache,
        fetchPage: (target) async {
          if (widget.receiptSources) {
            final json = await ref
                .read(apiClientProvider)
                .get(
                  '/finance/receipts/order-sources',
                  query: {
                    'page': target,
                    'size': 100,
                    if (filter.keyword?.trim().isNotEmpty == true)
                      'keyword': filter.keyword,
                    'sellerId': ?filter.sellerId,
                    ...filter.columnSearch,
                    'sort': ?sort,
                    'order': ?order,
                  },
                );
            return PagedResult.fromJsonResponsive(
              json,
              SalesDocListItem.fromJson,
            );
          }
          return repository.list(
            page: target,
            size: 100,
            filter: filter,
            sort: sort,
            order: order,
          );
        },
        fetchPageSized: (target, size) async {
          if (widget.receiptSources) {
            final json = await ref
                .read(apiClientProvider)
                .get(
                  '/finance/receipts/order-sources',
                  query: {
                    'page': target,
                    'size': size,
                    if (filter.keyword?.trim().isNotEmpty == true)
                      'keyword': filter.keyword,
                    'sellerId': ?filter.sellerId,
                    ...filter.columnSearch,
                    'sort': ?sort,
                    'order': ?order,
                  },
                );
            return PagedResult.fromJsonResponsive(
              json,
              SalesDocListItem.fromJson,
            );
          }
          return repository.list(
            page: target,
            size: size,
            filter: filter,
            sort: sort,
            order: order,
          );
        },
        onProgressiveBatch: (partial) {
          // 已选行的对账等完整结果。
          if (!mounted || generation != _loadGeneration) return;
          setState(() => _page = partial);
        },
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _page = r;
        if (reconcileSelection && _picked != null) {
          _picked = r.items.where((row) => row.id == _picked!.id).firstOrNull;
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (isRetiredViewRead(e)) return;
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (retiredReadError) {
      if (isRetiredViewRead(retiredReadError)) return;
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '加载销售订单失败';
        _loading = false;
      });
    }
  }

  void _onKeyword(String v) {
    _keyword = v;
    _load(1);
  }

  void _onSort(String? col, bool asc) {
    setState(() {
      _sortKey = col;
      _sortAsc = asc;
    });
    _load(1);
  }

  void _onColumnSearch(String key, String? value) {
    if (key != 'search.billNo') return;
    setState(() {
      if (value == null || value.trim().isEmpty) {
        _columnSearches.remove(key);
      } else {
        _columnSearches[key] = value.trim();
      }
      _picked = null;
    });
    _load(1);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                UtenPanelHeader(
                  title: '选择销售订单(来源单号)',
                  onClose: () => Navigator.of(context).pop(),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UtenSpacing.s16,
                    UtenSpacing.s12,
                    UtenSpacing.s16,
                    UtenSpacing.s8,
                  ),
                  child: Column(
                    children: [
                      // 生产视角：仅按单据号搜索；不暴露客户。
                      UtenSearchBar(
                        controller: _keywordCtl,
                        hint: widget.receiptSources ? '查订货单号/客户' : '搜索单据号',
                        onChanged: _onKeyword,
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      // 销售员筛选：默认 MKT_CENTER 营销体系、搜索全公司、可清空。
                      if (!widget.receiptSources)
                        UtenEmployeePicker(
                          presentation:
                              UtenEmployeePickerPresentation.businessReference,
                          cancelDepartmentTreeReadOnClose: true,
                          departmentTreeLoader: () => ref
                              .read(employeeReferenceRepositoryProvider)
                              .departments(
                                EmployeeReferencePurpose.salesOrderSellerFilter,
                              ),
                          label: '销售员',
                          hint: '全部销售员',
                          sheetTitle: '选择销售员',
                          initial: _selectedSeller,
                          allowClear: true,
                          pagedLoader: (query) async {
                            final kw = query.keyword;
                            return await ref
                                .read(employeeReferenceRepositoryProvider)
                                .listPickerPage(
                                  query,
                                  purpose: EmployeeReferencePurpose
                                      .salesOrderSellerFilter,
                                  size: 30,
                                  departmentId: (kw == null || kw.isEmpty)
                                      ? _marketingDeptId
                                      : null,
                                  includeSubtree: true,
                                );
                          },
                          onChanged: (item) {
                            setState(() {
                              _selectedSeller = item;
                              _selectedSellerId = item?.id;
                            });
                            _load(1);
                          },
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<SalesDocListItem>(
                    expensiveRowMounts: false,
                    singleTapRows: true,
                    rowsController: _pickerRows,
                    showPaginationControls: false,
                    tableKey:
                        'shared.widgets.sales_order_picker.SalesOrderPickerSheetState.build.1',
                    columns: _columns(),
                    items: _page?.items ?? const [],
                    facets: const {},
                    nullCounts: const {},
                    serverColumnSearch: true,
                    filters: _columnSearches,
                    onFilterChanged: _onColumnSearch,
                    sortColumn: _sortKey,
                    sortAscending: _sortAsc,
                    onSortChange: _onSort,
                    onRowTap: (d) => setState(() => _picked = d),
                    isSelected: (d) => _picked?.id == d.id,
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () =>
                        _load(_pickerRows.visiblePage ?? _page?.page ?? 1),
                    emptyMessage: '暂无已审销售订单',
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    paginationScope: (
                      _keyword,
                      _selectedSellerId,
                      _columnSearches['search.billNo'],
                    ),
                    onPageChange: (p) => _load(p, useCache: true),
                  ),
                ),
                UtenPickerConfirmBar(
                  pagination: UtenPickerPageControls(controller: _pickerRows),
                  selectedCount: _picked == null ? 0 : 1,
                  selectedLabel: _picked?.billNo,
                  onConfirm: _loading || _error != null
                      ? null
                      : () => Navigator.of(context).pop(_picked),
                ),
              ],
            ),
          ),
        ),
        if (_loading)
          UtenBusyOverlay(
            title: '加载订货单',
            cancelLabel: '取消加载',
            showDoNotLeaveHint: false,
            onCancel: () => setState(() {
              invalidateScopedPageReads();
              ++_loadGeneration;
              _loading = false;
              _error = '已取消加载，原搜索条件已保留';
            }),
          ),
      ],
    );
  }

  /// 生产视角列：单据号 / 日期 / 交货日期 / 销售员 / 状态。
  /// 不含客户、不含金额。销售员姓名由后端按 seller_id 解析下发。
  /// 单号列复用服务端 search.billNo；销售员保留上方可清除的人员范围选择。
  List<MasterColumnDef<SalesDocListItem>> _columns() => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 72,
      value: (d) => salesStatusLabel(d.status),
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '单据号',
      width: 150,
      columnSearchEnabled: true,
      sortable: true,
      value: (d) => d.billNo,
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '日期',
      width: 110,
      type: 'date',
      sortable: true,
      value: (d) => _dateOnly(d.billDate),
    ),
    MasterColumnDef(
      key: 'deliverDate',
      label: '交货日期',
      width: 110,
      type: 'date',
      sortable: true,
      value: (d) => _dateOnly(d.deliverDate),
    ),
    MasterColumnDef(
      key: 'seller',
      label: '销售员',
      width: 130,
      columnSearchEnabled: false,
      value: (d) => (d.sellerName != null && d.sellerName!.isNotEmpty)
          ? d.sellerName!
          : '—',
    ),
  ];

  static String _dateOnly(String? iso) =>
      (iso != null && iso.length >= 10) ? iso.substring(0, 10) : (iso ?? '');
}
