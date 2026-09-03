import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/procurement_iqc_rejection.dart';
import '../repositories/procurement_iqc_rejection_repository.dart';
import '../widgets/procurement_iqc_rejection_status_badge.dart';

class ProcurementIqcRejectionListPage extends ConsumerStatefulWidget {
  const ProcurementIqcRejectionListPage({
    super.key,
    this.source,
    this.repository,
  });

  final String? source;
  final ProcurementIqcRejectionGateway? repository;

  @override
  ConsumerState<ProcurementIqcRejectionListPage> createState() =>
      _ProcurementIqcRejectionListPageState();
}

class _ProcurementIqcRejectionListPageState
    extends ConsumerState<ProcurementIqcRejectionListPage> {
  PagedResult<ProcurementIqcRejectionCase>? _result;
  ProcurementIqcRejectionCounts? _counts;
  ProcurementIqcReceiptType? _receiptType;
  String? _status;
  bool _statusSelected = false; // 进页面不预选（不选=不过滤）
  String _keyword = '';
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  ProcurementIqcRejectionGateway get _repository =>
      widget.repository ?? ref.read(procurementIqcRejectionRepositoryProvider);

  String get _defaultBackPath => switch (widget.source) {
    'warehouse' => RouteName.warehouse,
    'finance' => RouteName.finance,
    _ => RouteName.dashboard,
  };

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() => _load(1));
  }

  Future<void> _load(int page) async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final filter = ProcurementIqcRejectionFilter(
        receiptType: _receiptType,
        status: _status,
        keyword: _keyword,
        page: page,
      );
      final countFilter = ProcurementIqcRejectionFilter(
        receiptType: _receiptType,
        keyword: _keyword,
      );
      final values = await Future.wait<Object>([
        _repository.list(filter),
        _repository.counts(countFilter),
      ]);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _result = values[0] as PagedResult<ProcurementIqcRejectionCase>;
        _counts = values[1] as ProcurementIqcRejectionCounts;
        _loading = false;
      });
      ref.invalidate(procurementIqcRejectionOpenCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = 'IQC 不合格退回与贷项任务加载失败，请检查网络后重试';
      });
    }
  }

  void _changeReceiptType(ProcurementIqcReceiptType? value) {
    if (_receiptType == value) return;
    setState(() => _receiptType = value);
    _load(1);
  }

  void _changeStatus(String? value) {
    if (_status == value && _statusSelected) return;
    setState(() {
      _status = value;
      _statusSelected = true;
    });
    _load(1);
  }

  void _search(String value) {
    setState(() => _keyword = value.trim());
    _load(1);
  }

  void _open(ProcurementIqcRejectionCase item) {
    context.push(
      RoutePath.procurementIqcRejectionDetail(item.id, source: widget.source),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: UtenAppBar(
        title: 'IQC 不合格退回与贷项',
        subtitle: '品质冻结事实 · 实物退回 · 供应商贷项 · 可审计反向',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: _defaultBackPath),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && result != null,
              onPressed: _loading ? null : () => _load(result?.page ?? 1),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && result == null
            ? Center(
                child: Semantics(
                  label: '正在加载 IQC 不合格任务',
                  child: const CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : _error != null && result == null
            ? UtenEmpty.error(
                message: '无法加载 IQC 不合格任务',
                description: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final result =
        _result ??
        const PagedResult<ProcurementIqcRejectionCase>(
          items: [],
          page: 1,
          size: 50,
          total: 0,
          totalPages: 1,
        );
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final expanded = constraints.maxWidth >= 840;
            final header = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildResponsibilityBanner(),
                const SizedBox(height: UtenSpacing.s12),
                if (_counts != null) _buildCounts(_counts!),
                if (_counts != null) const SizedBox(height: UtenSpacing.s12),
                _buildFilters(expanded: expanded),
                if (_error != null) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      children: [
                        Icon(
                          Icons.sync_problem_outlined,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        Expanded(child: Text('刷新失败：${_error!}')),
                        TextButton(
                          onPressed: _loading ? null : () => _load(result.page),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
              ],
            );
            if (expanded) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  Expanded(child: _buildTable(result)),
                ],
              );
            }
            return ListView(
              key: const Key('iqc-rejection-compact-list'),
              children: [
                header,
                if (result.items.isEmpty)
                  SizedBox(height: 320, child: _emptyState())
                else
                  for (final item in result.items) ...[
                    _IqcRejectionTaskCard(item: item, onTap: () => _open(item)),
                    const SizedBox(height: UtenSpacing.s8),
                  ],
                _IqcRejectionPager(
                  page: result.page,
                  totalPages: result.totalPages,
                  loading: _loading,
                  onPageChanged: _load,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildResponsibilityBanner() {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'IQC 不合格先完成真实退回，再由财务确认供应商贷项或零金额结案',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.38),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.report_problem_outlined, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '品质拒收、实物退回与财务贷项分步留痕',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '采购/委外订单负责人登记真实退回凭证；财务只读取服务器冻结金额并确认贷项，'
                    '或在权威金额为零时说明无需贷项结案。任何异常投影和反向都使用版本与命令号。',
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

  /// 状态分段工具条：徽章只挂在「待退回」（本页用户——采购/委外要登记退回
  /// 的动作）；「已退回待财务」「财务异常」下一步是财务在操作、「终态」无动作，
  /// 均不挂徽章（计数为零也不显）。原「点击已选 Chip 取消筛选」由显式「全部」
  /// 分段承担。
  Widget _buildCounts(ProcurementIqcRejectionCounts counts) {
    return UtenFilterToolbar<String?>(
      segmentsKey: const Key('iqc-rejection-status-segments'),
      segments: [
        const UtenFilterSegment(value: null, label: '全部'),
        UtenFilterSegment(
          value: 'PENDING_RETURN',
          label: '待退回',
          count: counts.pendingReturn,
        ),
        const UtenFilterSegment(value: 'RETURN_RECORDED', label: '已退回待财务'),
        const UtenFilterSegment(value: 'FINANCE_EXCEPTION', label: '财务异常'),
        const UtenFilterSegment(value: 'TERMINAL', label: '终态'),
      ],
      selected: _statusSelected ? {_status} : const {},
      onSelectionChanged: _changeStatus,
    );
  }

  Widget _buildFilters({required bool expanded}) {
    final type = DropdownButtonFormField<ProcurementIqcReceiptType?>(
      key: const Key('iqc-rejection-type-filter'),
      initialValue: _receiptType,
      decoration: const InputDecoration(labelText: '来源类型'),
      items: const [
        DropdownMenuItem(child: Text('采购 + 委外')),
        DropdownMenuItem(
          value: ProcurementIqcReceiptType.purchase,
          child: Text('采购'),
        ),
        DropdownMenuItem(
          value: ProcurementIqcReceiptType.subcontract,
          child: Text('委外'),
        ),
      ],
      onChanged: _loading ? null : _changeReceiptType,
    );
    final status = DropdownButtonFormField<String?>(
      key: const Key('iqc-rejection-status-filter'),
      initialValue: _status,
      decoration: const InputDecoration(labelText: '任务状态'),
      items: const [
        DropdownMenuItem(child: Text('全部状态')),
        DropdownMenuItem(value: 'PENDING_RETURN', child: Text('待登记实物退回')),
        DropdownMenuItem(value: 'RETURN_RECORDED', child: Text('已退回 / 待财务')),
        DropdownMenuItem(value: 'FINANCE_EXCEPTION', child: Text('财务投影异常')),
        DropdownMenuItem(value: 'TERMINAL', child: Text('终态')),
      ],
      onChanged: _loading ? null : _changeStatus,
    );
    final search = UtenSearchBar(
      key: const Key('iqc-rejection-search'),
      hint: '搜索收货单、订货单、供应商/委外商、货品',
      initialValue: _keyword,
      onInputChanged: (_) => _requestId++,
      onChanged: _search,
    );
    if (!expanded) {
      return Column(
        children: [
          search,
          const SizedBox(height: UtenSpacing.s8),
          type,
          const SizedBox(height: UtenSpacing.s8),
          status,
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 390, child: search),
        const SizedBox(width: UtenSpacing.s12),
        SizedBox(width: 190, child: type),
        const SizedBox(width: UtenSpacing.s12),
        SizedBox(width: 220, child: status),
        const Spacer(),
        Text(
          '共 ${_result?.total ?? 0} 条',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildTable(PagedResult<ProcurementIqcRejectionCase> result) {
    return MasterDataTableView<ProcurementIqcRejectionCase>(
      key: const Key('iqc-rejection-task-table'),
      columns: _columns,
      items: result.items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: _open,
      rowColor: (item) =>
          item.status == ProcurementIqcRejectionStatus.financeException
          ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.32)
          : item.status == ProcurementIqcRejectionStatus.returnRecorded
          ? Theme.of(
              context,
            ).colorScheme.secondaryContainer.withValues(alpha: 0.26)
          : null,
      isLoading: _loading,
      loadingMore: _loading && _result != null,
      error: result.items.isEmpty ? _error : null,
      onRetry: () => _load(result.page),
      emptyMessage: _emptyMessage,
      currentPage: result.page,
      totalPages: result.totalPages,
      onPageChange: _load,
    );
  }

  List<MasterColumnDef<ProcurementIqcRejectionCase>> get _columns => [
    MasterColumnDef(
      key: 'receiptType',
      label: '来源',
      width: 90,
      value: (item) => item.receiptType?.label ?? '—',
    ),
    MasterColumnDef(
      key: 'receiptBillNo',
      label: '收货 / 回厂单',
      width: 170,
      value: (item) => item.receiptBillNo,
    ),
    MasterColumnDef(
      key: 'orderBillNo',
      label: '订货单',
      width: 160,
      value: (item) => item.orderBillNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 200,
      value: (item) => item.supplierName,
    ),
    MasterColumnDef(
      key: 'goods',
      label: '不合格货品',
      width: 240,
      value: (item) => item.goodsLabel,
    ),
    MasterColumnDef(
      key: 'failedQty',
      label: '不合格数量',
      width: 130,
      type: 'number',
      value: (item) => '${item.failedQty ?? '—'} ${item.unitName ?? ''}'.trim(),
    ),
    MasterColumnDef(
      key: 'amount',
      label: '不合格金额(本币)',
      width: 150,
      type: 'money',
      value: (item) => item.amountLabel(item.failedAmountLocal),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 180,
      value: (item) => item.status.label,
    ),
    MasterColumnDef(
      key: 'holdReason',
      label: '异常原因 / 下一步',
      width: 280,
      value: (item) =>
          item.financeExceptionMessage ??
          item.holdReason ??
          _nextStep(item.status),
    ),
  ];

  Widget _emptyState() => UtenEmpty(
    icon: Icons.verified_outlined,
    message: _emptyMessage,
    description: _keyword.isNotEmpty
        ? '请调整单号、供应商或货品关键词后重试。'
        : '任务由 IQC 不合格冻结事件生成；通知不是任务事实。',
  );

  String get _emptyMessage {
    if (_keyword.isNotEmpty) return '没有匹配的 IQC 不合格任务';
    if (_status == 'PENDING_RETURN') return '当前没有待登记实物退回的任务';
    if (_status == 'RETURN_RECORDED') return '当前没有已退回待财务处理的任务';
    if (_status == 'FINANCE_EXCEPTION') return '当前没有财务投影异常';
    if (_status == 'TERMINAL') return '当前没有已结案或已反向的任务';
    return '当前没有 IQC 不合格退回与贷项任务';
  }
}

class _IqcRejectionTaskCard extends StatelessWidget {
  const _IqcRejectionTaskCard({required this.item, required this.onTap});

  final ProcurementIqcRejectionCase item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label:
          '${item.receiptType?.label ?? ''} ${item.receiptBillNo ?? ''}，${item.goodsLabel}，不合格 ${item.failedQty ?? '—'} ${item.unitName ?? ''}，${item.status.label}',
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 112),
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          item.goodsLabel.isEmpty ? '未命名货品' : item.goodsLabel,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      ProcurementIqcRejectionStatusBadge(status: item.status),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Wrap(
                    spacing: UtenSpacing.s12,
                    runSpacing: UtenSpacing.s4,
                    children: [
                      Text(
                        '${item.receiptType?.label ?? '未知'} · ${item.receiptBillNo ?? '—'}',
                      ),
                      Text('订货 ${item.orderBillNo ?? '—'}'),
                      Text('供应商 ${item.supplierName ?? '—'}'),
                      Text(
                        '不合格 ${item.failedQty ?? '—'} ${item.unitName ?? ''}'
                            .trim(),
                      ),
                      Text('金额 ${item.amountLabel(item.failedAmountLocal)}'),
                    ],
                  ),
                  if ((item.financeExceptionMessage ?? item.holdReason)
                      case final reason?) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      reason,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            item.status ==
                                ProcurementIqcRejectionStatus.financeException
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IqcRejectionPager extends StatelessWidget {
  const _IqcRejectionPager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPageChanged,
  });

  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    if (totalPages <= 1) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: loading || page <= 1
              ? null
              : () => onPageChanged(page - 1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Text('$page / $totalPages'),
        IconButton(
          tooltip: '下一页',
          onPressed: loading || page >= totalPages
              ? null
              : () => onPageChanged(page + 1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

String _nextStep(ProcurementIqcRejectionStatus status) => switch (status) {
  ProcurementIqcRejectionStatus.pendingReturn => '下一步：登记真实退回凭证',
  ProcurementIqcRejectionStatus.returnRecorded => '下一步：财务确认贷项或零金额结案',
  ProcurementIqcRejectionStatus.financeException => '下一步：修复后重试财务投影',
  ProcurementIqcRejectionStatus.creditConfirmed => '供应商贷项已闭环',
  ProcurementIqcRejectionStatus.closedNoCredit => '零金额无需贷项，已结案',
  ProcurementIqcRejectionStatus.reversed => '下游已反向',
  ProcurementIqcRejectionStatus.unknown => '状态未知，请刷新或联系管理员',
};
