// 销售订单选择器（右滑入单选）：用于生产计划单「来源单号」选销售订单。
//
// 基于 sales_doc_link_picker.dart 的外壳 + Step1 精简——只选单不选明细，
// onRowTap 直接 pop(SalesDocListItem)。状态固定已审（草稿/红冲不可作来源）。
// 数据源 salesRepositoryProvider(SalesDocType.order)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';

/// 弹出右滑入销售订单选择器；返回所选订单（null=取消）。
Future<SalesDocListItem?> showSalesOrderPicker(
  BuildContext context,
  WidgetRef ref,
) {
  const sheet = _SalesOrderPickerSheet();
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
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: const SizedBox(
          width: 840,
          height: double.infinity,
          child: sheet,
        ),
      ),
    ),
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
  const _SalesOrderPickerSheet();

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
  String? _clientId;
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesMasterNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    super.dispose();
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
            // 业务约束：只选已审订单作来源（草稿/红冲不可）。
            filter: SalesDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              clientId: _clientId,
              status: kSalesStatusApproved,
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
    final names = ref.watch(salesMasterNameServiceProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s8,
                UtenSpacing.s12,
                UtenSpacing.s4,
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
                UtenSpacing.s12,
                UtenSpacing.s12,
                UtenSpacing.s12,
                UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _keywordCtl,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        hintText: '搜索单据号 / 客户名称',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: _onKeyword,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  SizedBox(
                    width: 240,
                    child: UtenDropdownField(
                      label: '客户',
                      value: _clientId ?? '',
                      items: [
                        const UtenDropdownItem(value: '', label: '全部客户'),
                        for (final e in names.clientEntries.entries)
                          UtenDropdownItem(value: e.key, label: e.value),
                      ],
                      onChanged: (v) {
                        setState(
                          () => _clientId = (v == null || v.isEmpty) ? null : v,
                        );
                        _load(1);
                      },
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: MasterDataTableView<SalesDocListItem>(
                columns: _columns(names),
                items: _page?.items ?? const [],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                sortColumn: _sortKey,
                sortAscending: _sortAsc,
                onSortChange: _onSort,
                onRowTap: (d) => Navigator.of(context).pop(d),
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
          ],
        ),
      ),
    );
  }

  List<MasterColumnDef<SalesDocListItem>> _columns(
    SalesMasterNameService names,
  ) => [
    MasterColumnDef(
      key: 'billNo',
      label: '单据号',
      width: 140,
      value: (d) => d.billNo,
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '日期',
      width: 110,
      type: 'date',
      sortable: true,
      value: (d) => (d.billDate != null && d.billDate!.length >= 10)
          ? d.billDate!.substring(0, 10)
          : (d.billDate ?? ''),
    ),
    MasterColumnDef(
      key: 'client',
      label: '客户',
      width: 200,
      value: (d) => names.client(d.clientId),
    ),
    MasterColumnDef(
      key: 'total',
      label: '合计',
      width: 120,
      type: 'money',
      sortable: true,
      value: (d) => d.totalLocal?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 90,
      value: (d) => salesStatusLabel(d.status),
    ),
  ];
}
