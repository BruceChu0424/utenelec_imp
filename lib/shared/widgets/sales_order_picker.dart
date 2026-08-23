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
import '../../components/layout/uten_picker_confirm_bar.dart';
import '../../core/network/api_exception.dart';
import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/basic_data/widgets/master_data_table_view.dart';
import '../../features/department/models/department_node.dart';
import '../../features/department/repositories/department_repository.dart';
import '../../features/employee/repositories/employee_repository.dart';
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
}) {
  final sheet = _SalesOrderPickerSheet(initialSeller: initialSeller);
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<SalesDocListItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.9,
          child: sheet,
        ),
      ),
    );
  }
  return showGeneralDialog<SalesDocListItem>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) {
      // 浮动留边：面板与屏幕上/右/下边各留 16px，圆角 + 阴影，不再贴边。
      final viewportWidth = MediaQuery.sizeOf(ctx).width;
      final panelWidth = viewportWidth < 920 ? viewportWidth * 0.92 : 840.0;
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
          child: Material(
            color: Theme.of(ctx).colorScheme.surface,
            elevation: 12,
            borderRadius: BorderRadius.circular(UtenRadius.lg),
            child: SizedBox(
              width: panelWidth,
              height: double.infinity,
              child: sheet,
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _SalesOrderPickerSheet extends ConsumerStatefulWidget {
  const _SalesOrderPickerSheet({this.initialSeller});

  final UtenEmployeePickerItem? initialSeller;

  @override
  ConsumerState<_SalesOrderPickerSheet> createState() =>
      _SalesOrderPickerSheetState();
}

class _SalesOrderPickerSheetState
    extends ConsumerState<_SalesOrderPickerSheet> {
  PagedResult<SalesDocListItem>? _page;
  bool _loading = false;
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

  /// 已点选（高亮）的订单；底部「确定」才 pop 返回（二次操作契约）。
  SalesDocListItem? _picked;

  @override
  void initState() {
    super.initState();
    _selectedSeller = widget.initialSeller;
    _selectedSellerId = widget.initialSeller?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveMarketingDept();
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
      final tree = await ref.read(departmentRepositoryProvider).tree();
      final node = findDepartmentByCode(tree, kDeptCodeMarketing);
      if (node != null && mounted) {
        setState(() => _marketingDeptId = node.id);
      }
    } catch (_) {
      // 解析失败时销售员抽屉回退全公司，不阻塞选单。
    }
  }

  Future<void> _load(int page) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .list(
            page: page,
            // 业务约束：只选已审订单作来源（草稿/红冲不可）。销售员为空则不筛。
            filter: SalesDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              status: kSalesStatusApproved,
              sellerId: _selectedSellerId,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                UtenSpacing.s12,
                UtenSpacing.s8,
                UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择销售订单（来源单号）',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
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
                  TextField(
                    controller: _keywordCtl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      hintText: '搜索单据号',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: _onKeyword,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  // 销售员筛选：默认 MKT_CENTER 营销体系、搜索全公司、可清空。
                  UtenEmployeePicker(
                    label: '销售员',
                    hint: '全部销售员',
                    sheetTitle: '选择销售员',
                    initial: _selectedSeller,
                    allowClear: true,
                    loader: (kw) async {
                      final res = await ref
                          .read(employeeRepositoryProvider)
                          .list(
                            size: 30,
                            search: kw,
                            departmentId: (kw == null || kw.isEmpty)
                                ? _marketingDeptId
                                : null,
                            includeSubtree: true,
                          );
                      return [
                        for (final e in res.items)
                          UtenEmployeePickerItem(
                            id: e.id,
                            name: e.fullName,
                            departmentName: e.departmentName,
                          ),
                      ];
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
                columns: _columns(),
                items: _page?.items ?? const [],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                sortColumn: _sortKey,
                sortAscending: _sortAsc,
                onSortChange: _onSort,
                onRowTap: (d) => setState(() => _picked = d),
                isSelected: (d) => _picked?.id == d.id,
                isLoading: _loading && _page == null,
                loadingMore: _loading && _page != null,
                error: _error,
                onRetry: () => _load(1),
                emptyMessage: '暂无已审销售订单',
                currentPage: _page?.page ?? 1,
                totalPages: _page?.totalPages ?? 1,
                onPageChange: (p) => _load(p),
              ),
            ),
            UtenPickerConfirmBar(
              selectedCount: _picked == null ? 0 : 1,
              selectedLabel: _picked?.billNo,
              onConfirm: () => Navigator.of(context).pop(_picked),
            ),
          ],
        ),
      ),
    );
  }

  /// 生产视角列：单据号 / 日期 / 交货日期 / 销售员 / 状态。
  /// 不含客户、不含金额。销售员姓名由后端按 seller_id 解析下发。
  List<MasterColumnDef<SalesDocListItem>> _columns() => [
    MasterColumnDef(
      key: 'billNo',
      label: '单据号',
      width: 150,
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
      value: (d) => (d.sellerName != null && d.sellerName!.isNotEmpty)
          ? d.sellerName!
          : '—',
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 90,
      value: (d) => salesStatusLabel(d.status),
    ),
  ];

  static String _dateOnly(String? iso) =>
      (iso != null && iso.length >= 10) ? iso.substring(0, 10) : (iso ?? '');
}
