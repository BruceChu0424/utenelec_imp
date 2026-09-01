import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_iqc_return.dart';
import '../repositories/warehouse_iqc_return_repository.dart';

class WarehouseIqcReturnPage extends ConsumerStatefulWidget {
  const WarehouseIqcReturnPage({super.key});

  @override
  ConsumerState<WarehouseIqcReturnPage> createState() =>
      _WarehouseIqcReturnPageState();
}

class _WarehouseIqcReturnPageState
    extends ConsumerState<WarehouseIqcReturnPage> {
  PagedResult<WarehouseIqcReturnTask>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  WarehouseIqcReceiptType? _receiptType;
  String? _physicalStatus = WarehouseIqcPhysicalStatus.pendingReturn;
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
          .read(warehouseIqcReturnRepositoryProvider)
          .list(
            page: page,
            receiptType: _receiptType,
            physicalStatus: _physicalStatus,
            keyword: _keyword,
          );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = 'IQC 实物退回任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _applySearch(String value) {
    final keyword = value.trim();
    if (keyword == _keyword) return;
    setState(() => _keyword = keyword);
    _load(1);
  }

  @override
  Widget build(BuildContext context) {
    final result =
        _result ??
        const PagedResult<WarehouseIqcReturnTask>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return Scaffold(
      appBar: UtenAppBar(
        title: 'IQC 不合格实物退回',
        subtitle: '仓库退回凭证工作台',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/warehouse'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-iqc-return-refresh'),
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
                const _IqcReturnBoundaryBanner(),
                const SizedBox(height: UtenSpacing.s12),
                _toolbar(result),
                if (_error != null && result.items.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: MasterDataTableView<WarehouseIqcReturnTask>(
                    key: const Key('warehouse-iqc-return-table'),
                    columns: _columns,
                    items: result.items,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: (item) => context.push(
                      '/warehouse/iqc-returns/${Uri.encodeComponent(item.id)}',
                    ),
                    isLoading: _loading && _result == null,
                    loadingMore: _loading && _result != null,
                    error: result.items.isEmpty ? _error : null,
                    onRetry: () => _load(result.page),
                    emptyMessage: _emptyMessage,
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

  String get _emptyMessage {
    if (_keyword.isNotEmpty) return '没有匹配“$_keyword”的实物退回任务';
    return switch (_physicalStatus) {
      WarehouseIqcPhysicalStatus.pendingReturn => '暂无待登记实物退回任务',
      WarehouseIqcPhysicalStatus.returnRecorded => '暂无已登记实物退回记录',
      WarehouseIqcPhysicalStatus.voided => '暂无已撤销实物退回记录',
      _ => '暂无 IQC 不合格实物退回任务',
    };
  }

  Widget _toolbar(PagedResult<WarehouseIqcReturnTask> result) {
    // 全平台统一筛选工具条：来源类型分段（+搜索）与实物退回状态分段各一条。
    // 分段键沿用原 Chip 键前缀（原为每个 Chip 一个键，现为整组）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<WarehouseIqcReceiptType?>(
          segmentsKey: const Key('warehouse-iqc-return-type'),
          searchKey: const Key('warehouse-iqc-return-search'),
          segments: [
            const UtenFilterSegment(value: null, label: '全部来源'),
            for (final type in WarehouseIqcReceiptType.values)
              UtenFilterSegment(value: type, label: type.label),
          ],
          selected: _receiptType,
          onSelectionChanged: (value) {
            setState(() => _receiptType = value);
            _load(1);
          },
          searchHint: '搜索收货单 / 订货单 / 供应商 / 货品 / 仓库',
          initialSearchValue: _keyword,
          onSearchInputChanged: (_) => _requestVersion++,
          onSearchChanged: _applySearch,
          trailing: Semantics(
            liveRegion: true,
            label: '共 ${result.total} 项实物退回任务',
            child: Text(
              '共 ${result.total} 项 · 双击查看退回凭证',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenFilterToolbar<String?>(
          segmentsKey: const Key('warehouse-iqc-return-status'),
          segments: [
            for (final option in const <(String, String?)>[
              ('全部状态', null),
              ('待登记退回', WarehouseIqcPhysicalStatus.pendingReturn),
              ('退回已登记', WarehouseIqcPhysicalStatus.returnRecorded),
              ('来源已撤销', WarehouseIqcPhysicalStatus.voided),
            ])
              UtenFilterSegment(value: option.$2, label: option.$1),
          ],
          selected: _physicalStatus,
          onSelectionChanged: (value) {
            setState(() => _physicalStatus = value);
            _load(1);
          },
        ),
      ],
    );
  }

  List<MasterColumnDef<WarehouseIqcReturnTask>> get _columns => [
    MasterColumnDef(
      key: 'physicalReturnStatus',
      label: '实物状态',
      width: 140,
      value: (item) => item.statusLabel,
    ),
    MasterColumnDef(
      key: 'receiptType',
      label: '来源类型',
      width: 110,
      value: (item) => item.receiptType?.label ?? '—',
    ),
    MasterColumnDef(
      key: 'receiptBillNo',
      label: '收货单号',
      width: 160,
      value: (item) => item.receiptBillNo ?? '—',
    ),
    MasterColumnDef(
      key: 'orderBillNo',
      label: '订货单号',
      width: 160,
      value: (item) => item.orderBillNo ?? '—',
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 180,
      value: (item) => item.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '仓库',
      width: 130,
      value: (item) => item.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'goods',
      label: '拒收货品',
      width: 220,
      value: (item) => item.goodsLabel.isEmpty ? '—' : item.goodsLabel,
    ),
    MasterColumnDef(
      key: 'failedQuantity',
      label: '拒收数量',
      width: 108,
      type: 'number',
      value: (item) => [
        item.failedQuantity,
        item.unitName,
      ].where((value) => value?.trim().isNotEmpty == true).join(' '),
    ),
    MasterColumnDef(
      key: 'returnReference',
      label: '退回凭证',
      width: 160,
      value: (item) => item.returnReference ?? '—',
    ),
    MasterColumnDef(
      key: 'returnDate',
      label: '退回日期',
      width: 116,
      type: 'date',
      value: (item) => item.returnDate ?? '—',
    ),
  ];
}

class _IqcReturnBoundaryBanner extends StatelessWidget {
  const _IqcReturnBoundaryBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'IQC 不合格实物退回视图，只登记真实退回凭证。',
      child: Container(
        key: const Key('warehouse-iqc-return-boundary'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(
          '仓库实物视图 · 仅核对拒收货品、数量、来源和真实退回凭证。'
          '本页不包含商业或财务处理信息，也不提供跨部门结案操作。',
          style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
        ),
      ),
    );
  }
}
