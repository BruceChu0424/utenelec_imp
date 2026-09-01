import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../providers/warehouse_iqc_stock_in_count_provider.dart';
import '../repositories/warehouse_iqc_stock_in_repository.dart';

class WarehouseIqcStockInPage extends ConsumerStatefulWidget {
  const WarehouseIqcStockInPage({super.key});

  @override
  ConsumerState<WarehouseIqcStockInPage> createState() =>
      _WarehouseIqcStockInPageState();
}

class _WarehouseIqcStockInPageState
    extends ConsumerState<WarehouseIqcStockInPage> {
  PagedResult<WarehouseIqcStockInTaskSummary>? _result;
  WarehouseIqcStockInReceiptType? _receiptType;
  String _keyword = '';
  String? _error;
  bool _loading = false;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(warehouseIqcStockInRepositoryProvider)
          .list(page: page, receiptType: _receiptType, keyword: _keyword);
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseIqcStockInPendingCountProvider);
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = 'IQC 合格待入库任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _applySearch(String value) {
    final normalized = value.trim();
    if (normalized == _keyword) return;
    setState(() => _keyword = normalized);
    _load(1);
  }

  Future<void> _open(WarehouseIqcStockInTaskSummary task) async {
    await context.push(
      RouteName.warehouseIqcStockInDetail(
        task.receiptTypeValue,
        task.receiptId,
      ),
    );
    if (!mounted) return;
    await _load(_result?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final result =
        _result ??
        const PagedResult<WarehouseIqcStockInTaskSummary>(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 0,
        );
    return Scaffold(
      appBar: UtenAppBar(
        title: 'IQC 合格待入库',
        subtitle: '仓库实物确认与库位登记',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-iqc-stock-in-refresh'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && _result != null,
              onPressed: _loading ? null : () => _load(result.page),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _BoundaryBanner(),
                const SizedBox(height: UtenSpacing.s12),
                _toolbar(result),
                if (_error != null && result.items.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      '刷新失败：$_error',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: MasterDataTableView<WarehouseIqcStockInTaskSummary>(
                    key: const Key('warehouse-iqc-stock-in-table'),
                    columns: _columns,
                    items: result.items,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: _open,
                    rowMenuBuilder: (task) => [
                      UtenMenuItem(
                        label: '查看入库详情',
                        icon: Icons.visibility_outlined,
                        onTap: () => _open(task),
                      ),
                    ],
                    isLoading: _loading && _result == null,
                    loadingMore: _loading && _result != null,
                    error: result.items.isEmpty ? _error : null,
                    onRetry: () => _load(result.page),
                    emptyMessage: _keyword.isEmpty
                        ? '目前没有品质已放行、等待仓库确认的入库任务'
                        : '没有匹配“$_keyword”的 IQC 待入库任务',
                    currentPage: result.page,
                    totalPages: result.totalPages,
                    onPageChange: _load,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(PagedResult<WarehouseIqcStockInTaskSummary> result) {
    final search = UtenSearchBar(
      key: const Key('warehouse-iqc-stock-in-search'),
      hint: '搜索收货单 / 供应商 / 仓库 / 货品',
      initialValue: _keyword,
      onInputChanged: (_) => _requestVersion++,
      onChanged: _applySearch,
    );
    final filters = Semantics(
      container: true,
      label: 'IQC 待入库来源类型筛选',
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        children: [
          ChoiceChip(
            key: const Key('warehouse-iqc-stock-in-type-all'),
            label: const Text('全部来源'),
            selected: _receiptType == null,
            showCheckmark: false,
            onSelected: (_) {
              setState(() => _receiptType = null);
              _load(1);
            },
          ),
          for (final type in WarehouseIqcStockInReceiptType.values)
            ChoiceChip(
              key: Key('warehouse-iqc-stock-in-type-${type.apiValue}'),
              label: Text(type.label),
              selected: _receiptType == type,
              showCheckmark: false,
              onSelected: (_) {
                setState(() => _receiptType = type);
                _load(1);
              },
            ),
        ],
      ),
    );
    final summary = Semantics(
      liveRegion: true,
      label: '共 ${result.total} 张 IQC 合格待入库任务',
      child: Text(
        '共 ${result.total} 张 · 点击核对实物',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: UtenSpacing.s8),
              filters,
              const SizedBox(height: UtenSpacing.s8),
              Align(alignment: Alignment.centerRight, child: summary),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(width: 420, child: search),
                const Spacer(),
                summary,
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            filters,
          ],
        );
      },
    );
  }

  List<MasterColumnDef<WarehouseIqcStockInTaskSummary>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '作业状态',
      width: 190,
      value: (task) => task.statusLabel,
    ),
    MasterColumnDef(
      key: 'receiptType',
      label: '来源类型',
      width: 110,
      value: (task) => task.receiptType.label,
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '收货单号',
      width: 170,
      value: (task) => task.billNo ?? '—',
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '收货日期',
      width: 116,
      type: 'date',
      value: (task) => task.billDate ?? '—',
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 190,
      value: (task) => task.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '目标仓库',
      width: 150,
      value: (task) => task.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'goodsLineCount',
      label: '待入库货品',
      width: 110,
      type: 'number',
      value: (task) => '${task.goodsLineCount} 行',
    ),
    MasterColumnDef(
      key: 'pendingSliceCount',
      label: '品质放行批次',
      width: 120,
      type: 'number',
      value: (task) => '${task.pendingSliceCount} 个',
    ),
    MasterColumnDef(
      key: 'lastReleasedAt',
      label: '最近放行',
      width: 170,
      value: (task) => _dateTime(task.lastReleasedAt),
    ),
  ];
}

class _BoundaryBanner extends StatelessWidget {
  const _BoundaryBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '品质合格仅表示允许仓库点收，确认前不会增加可用库存。',
      child: Container(
        key: const Key('warehouse-iqc-stock-in-boundary'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(
          '仓库实物视图 · 品质合格只形成待入库任务。请核对本次实收数量和实际库位；'
          '仓库确认后才增加可用库存。本页不显示单价、金额、币种或结算信息。',
          style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
        ),
      ),
    );
  }
}

String _dateTime(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '—';
  final normalized = text.replaceFirst('T', ' ');
  return normalized.length > 16 ? normalized.substring(0, 16) : normalized;
}
