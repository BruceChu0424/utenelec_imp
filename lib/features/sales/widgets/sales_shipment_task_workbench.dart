import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';

enum SalesShipmentTaskWorkbenchMode { financeAudit, warehouseOutbound }

/// 销售出货跨部门任务的共享只读投影视图。
///
/// 财务和仓库各自拥有独立路由、标题、默认过滤和权限入口；这里只复用同一套
/// 响应式列表骨架与权威出货 DTO。业务动作仍在既有出货详情中按权限和服务端
/// capability 终审，工作台不会暴露销售新建/编辑入口。
class SalesShipmentTaskWorkbench extends ConsumerStatefulWidget {
  const SalesShipmentTaskWorkbench({super.key, required this.mode});

  final SalesShipmentTaskWorkbenchMode mode;

  @override
  ConsumerState<SalesShipmentTaskWorkbench> createState() =>
      _SalesShipmentTaskWorkbenchState();
}

class _SalesShipmentTaskWorkbenchState
    extends ConsumerState<SalesShipmentTaskWorkbench> {
  PagedResult<SalesDocListItem>? _result;
  bool _loading = false;
  String? _error;
  int _page = 1;
  String _keyword = '';
  Timer? _searchDebounce;
  int _requestGeneration = 0;

  int? _financeAudit;
  String? _warehouseWorkStatus;

  bool get _isFinance =>
      widget.mode == SalesShipmentTaskWorkbenchMode.financeAudit;

  String get _requiredPermission =>
      _isFinance ? Perm.financeShipmentAudit : Perm.salesShipmentWarehouseWork;

  String get _route => _isFinance
      ? RouteName.financeSalesShipmentAudit
      : RouteName.warehouseSalesOutbound;

  String get _backRoute => _isFinance ? RouteName.finance : RouteName.warehouse;

  String get _title => _isFinance ? '出货财务审核' : '仓库销售出库';

  String get _emptyMessage {
    if (_isFinance) {
      return _financeAudit == 1 ? '暂无已财务审核的出货单' : '暂无待财务审核的出货单';
    }
    return switch (_warehouseWorkStatus) {
      SalesWarehouseWorkStatus.pendingPick => '暂无待拣货销售出货',
      SalesWarehouseWorkStatus.picking => '暂无拣货中销售出货',
      SalesWarehouseWorkStatus.picked => '暂无已拣货待交接销售出货',
      SalesWarehouseWorkStatus.exception => '暂无仓库异常销售出货',
      _ => '暂无财务已放行的销售出货',
    };
  }

  bool get _hasRequiredPermission =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(_requiredPermission);

  @override
  void initState() {
    super.initState();
    _financeAudit = _isFinance ? 0 : 1;
    if (!_isFinance) {
      _warehouseWorkStatus = SalesWarehouseWorkStatus.pendingPick;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasRequiredPermission) return;
      unawaited(
        ref.read(salesMasterNameServiceProvider).ensureLoaded().whenComplete(
          () {
            if (mounted) setState(() {});
          },
        ),
      );
      _load(1);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load([int? page]) async {
    // 路由守卫之外再失败关闭；权限撤销或独立 widget 场景都不得旁路请求数据。
    if (!_hasRequiredPermission) return;
    final requestedPage = page ?? _page;
    final generation = ++_requestGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _page = requestedPage;
    });
    try {
      final value = await ref
          .read(salesRepositoryProvider(SalesDocType.shipment))
          .list(
            page: requestedPage,
            filter: SalesDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
              // 两个专页都是“当前人工任务”，历史已出库/红冲仍从销售历史页查。
              status: kSalesStatusDraft,
              financeAudit: _financeAudit,
              warehouseWorkStatus: _isFinance
                  ? SalesWarehouseWorkStatus.pendingPick
                  : _warehouseWorkStatus,
            ),
          );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _result = value;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = _isFinance ? '出货财务审核任务加载失败' : '销售出库任务加载失败';
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String value) {
    _keyword = value;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _load(1);
    });
  }

  void _open(SalesDocListItem item) {
    context.push(
      SalesRoutePath.docDetail(SalesDocType.shipment.pathSegment, item.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(_route, () => _load());
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(_requiredPermission);
    return Scaffold(
      appBar: UtenAppBar(
        title: _title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: _backRoute),
        ),
        actions: allowed
            ? [
                IconButton(
                  key: const Key('sales-shipment-task-refresh'),
                  tooltip: '刷新',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ]
            : null,
      ),
      // 局部 SelectionArea：销售发货审核工作台文字可框选复制（准则 §3.4；
      // 仅搜索防抖无周期轮询，可包）。
      body: SelectionArea(
        child: SafeArea(
          child: !allowed
              ? UtenEmpty.error(
                  message: '无权查看$_title',
                  description: '请在本页权限中授予 $_requiredPermission。',
                )
              : _loading && _result == null
              ? const UtenSkeletonList()
              : _error != null && _result == null
              ? UtenEmpty.error(
                  message: _error,
                  actionLabel: '重新加载',
                  onAction: () => _load(1),
                )
              : _body(),
        ),
      ),
    );
  }

  Widget _body() {
    final result =
        _result ??
        const PagedResult<SalesDocListItem>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    final names = ref.watch(salesMasterNameServiceProvider);
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final desktop = breakpointForWidth(constraints.maxWidth).isExpanded;
            return desktop ? _desktop(result, names) : _compact(result, names);
          },
        ),
      ),
    );
  }

  Widget _desktop(
    PagedResult<SalesDocListItem> result,
    SalesMasterNameService names,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _summary(result.total),
        const SizedBox(height: UtenSpacing.s12),
        _filters(),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          _InlineTaskError(message: _error!, onRetry: _load),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Expanded(
          child: MasterDataTableView<SalesDocListItem>(
            key: Key(
              _isFinance
                  ? 'finance-shipment-audit-table'
                  : 'warehouse-sales-outbound-table',
            ),
            columns: _columns(names),
            items: result.items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRowTap: _open,
            isLoading: _loading,
            emptyMessage: _emptyMessage,
            currentPage: result.page,
            totalPages: result.totalPages,
            onPageChange: _load,
          ),
        ),
      ],
    );
  }

  Widget _compact(
    PagedResult<SalesDocListItem> result,
    SalesMasterNameService names,
  ) {
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        key: Key(
          _isFinance
              ? 'finance-shipment-audit-compact-list'
              : 'warehouse-sales-outbound-compact-list',
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
        children: [
          _summary(result.total),
          const SizedBox(height: UtenSpacing.s12),
          _filters(),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            _InlineTaskError(message: _error!, onRetry: _load),
          ],
          if (_loading && _result != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: UtenSpacing.s12),
          if (result.items.isEmpty)
            SizedBox(
              height: 300,
              child: UtenEmpty(
                icon: _isFinance
                    ? Icons.fact_check_outlined
                    : Icons.inventory_2_outlined,
                message: _emptyMessage,
                description: _isFinance
                    ? '新的出货草稿会在这里等待财务逐张人工放行。'
                    : '财务放行后，销售出货会进入这里等待仓库作业。',
              ),
            )
          else
            for (final item in result.items) ...[
              _CompactShipmentTaskCard(
                item: item,
                clientName: names.client(item.clientId),
                warehouseName: names.warehouse(item.warehouseId),
                currencyName: names.currency(item.currencyId),
                onOpen: () => _open(item),
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
          if (result.totalPages > 1)
            _TaskPager(
              page: result.page,
              totalPages: result.totalPages,
              loading: _loading,
              onPage: _load,
            ),
        ],
      ),
    );
  }

  Widget _summary(int total) {
    final theme = Theme.of(context);
    final description = _isFinance
        ? '默认只看待审核。进入详情逐张核对客户货款类型、应收、铺底和可用预收(真实已审到账)后再人工放行；“定金”只是一种客户分类。'
        : '固定只看财务已放行的出货。仓库按待拣、拣货、已拣和异常推进；交接出库后才正式扣库存并形成应收。';
    return Semantics(
      container: true,
      label: '$_title，共 $total 笔。$description',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.34),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _isFinance
                  ? Icons.fact_check_outlined
                  : Icons.inventory_2_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '共 $total 笔',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filters() {
    final search = SizedBox(
      width: 320,
      child: UtenSearchBar(
        key: const Key('sales-shipment-task-search'),
        hint: '搜索出货单号 / 客户',
        initialValue: _keyword,
        onChanged: _onSearchChanged,
        onSubmitted: (_) {
          _searchDebounce?.cancel();
          _load(1);
        },
      ),
    );
    final chips = _isFinance ? _financeChips() : _warehouseChips();
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < UtenBreakpoints.expandedStart;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: double.infinity, child: search),
              const SizedBox(height: UtenSpacing.s8),
              chips,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            search,
            const SizedBox(width: UtenSpacing.s12),
            Expanded(child: chips),
          ],
        );
      },
    );
  }

  Widget _financeChips() => Wrap(
    spacing: UtenSpacing.s4,
    runSpacing: UtenSpacing.s4,
    children: [
      _financeChip('待审核', 0),
      _financeChip('已审核', 1),
      _financeChip('全部', null),
    ],
  );

  Widget _financeChip(String label, int? value) => ChoiceChip(
    label: Text(label),
    selected: _financeAudit == value,
    onSelected: (_) {
      setState(() => _financeAudit = value);
      _load(1);
    },
  );

  Widget _warehouseChips() => Wrap(
    spacing: UtenSpacing.s4,
    runSpacing: UtenSpacing.s4,
    children: [
      _warehouseChip('待拣货', SalesWarehouseWorkStatus.pendingPick),
      _warehouseChip('拣货中', SalesWarehouseWorkStatus.picking),
      _warehouseChip('已拣货', SalesWarehouseWorkStatus.picked),
      _warehouseChip('异常', SalesWarehouseWorkStatus.exception),
    ],
  );

  Widget _warehouseChip(String label, String? value) => ChoiceChip(
    label: Text(label),
    selected: _warehouseWorkStatus == value,
    onSelected: (_) {
      setState(() => _warehouseWorkStatus = value);
      _load(1);
    },
  );

  List<MasterColumnDef<SalesDocListItem>> _columns(
    SalesMasterNameService names,
  ) => [
    MasterColumnDef(
      key: 'billNo',
      label: '出货单号',
      width: 170,
      value: (item) => item.billNo ?? '—',
    ),
    MasterColumnDef(
      key: 'client',
      label: '客户',
      width: 190,
      value: (item) => names.client(item.clientId),
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '出货日期',
      width: 120,
      type: 'date',
      value: (item) => _shortDate(item.billDate),
    ),
    MasterColumnDef(
      key: 'warehouse',
      label: '仓库',
      width: 150,
      value: (item) => names.warehouse(item.warehouseId),
    ),
    const MasterColumnDef(
      key: 'totalOriginal',
      label: '出货金额',
      width: 140,
      type: 'money',
      value: _amount,
    ),
    MasterColumnDef(
      key: 'financeAudit',
      label: '财务审核',
      width: 120,
      value: (item) => salesShipmentFinanceAuditLabel(item.financeAudit),
    ),
    MasterColumnDef(
      key: 'warehouseWorkStatus',
      label: '仓库作业',
      width: 160,
      value: (item) => salesWarehouseWorkStatusLabel(item.warehouseWorkStatus),
    ),
  ];
}

class _CompactShipmentTaskCard extends StatelessWidget {
  const _CompactShipmentTaskCard({
    required this.item,
    required this.clientName,
    required this.warehouseName,
    required this.currencyName,
    required this.onOpen,
  });

  final SalesDocListItem item;
  final String clientName;
  final String warehouseName;
  final String currencyName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = salesShipmentFinanceAuditLabel(item.financeAudit);
    final warehouse = salesWarehouseWorkStatusLabel(item.warehouseWorkStatus);
    final amount = _amount(item);
    return Semantics(
      container: true,
      button: true,
      label:
          '${item.billNo ?? '未编号出货'}，客户 $clientName，财务 $finance，仓库 $warehouse',
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.mdAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              borderRadius: UtenRadius.mdAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.billNo ?? '未编号出货',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      item.priceMasked ? '***' : '$currencyName $amount',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '$clientName · $warehouseName · ${_shortDate(item.billDate)}',
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '财务：$finance · 仓库：$warehouse',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Align(
                  alignment: Alignment.centerRight,
                  child: UtenButton(
                    size: UtenButtonSize.small,
                    type: UtenButtonType.secondary,
                    icon: Icons.open_in_new_rounded,
                    onPressed: onOpen,
                    child: const Text('查看详情'),
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

class _InlineTaskError extends StatelessWidget {
  const _InlineTaskError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _TaskPager extends StatelessWidget {
  const _TaskPager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPage,
  });

  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: '上一页',
        onPressed: loading || page <= 1 ? null : () => onPage(page - 1),
        icon: const Icon(Icons.chevron_left_rounded),
      ),
      Text('$page / $totalPages'),
      IconButton(
        tooltip: '下一页',
        onPressed: loading || page >= totalPages
            ? null
            : () => onPage(page + 1),
        icon: const Icon(Icons.chevron_right_rounded),
      ),
    ],
  );
}

String _shortDate(String? value) {
  if (value == null || value.isEmpty) return '—';
  return value.length > 10 ? value.substring(0, 10) : value;
}

String _amount(SalesDocListItem item) {
  if (item.priceMasked) return '***';
  return (item.totalOriginal ?? item.totalLocal)?.toStringAsFixed(2) ?? '—';
}
