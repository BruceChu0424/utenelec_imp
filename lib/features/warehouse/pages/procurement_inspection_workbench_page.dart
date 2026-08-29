import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inspection_repository.dart';

/// 采购/委外收货 IQC 待检处置任务中心 + 单据处置页（与仓库「预计到货任务中心」
/// 同款两级结构）：
///
/// - 任务中心：搜索 + 指标筛选卡（全部/采购/委外）+ 待检收货单卡片列表，
///   点「检验本单」进入独立处置页；
/// - 处置页：本单待检明细多选表格——常规合格勾选多行一次放行，部分合格或
///   不合格保留单行质量依据；本单处理完成后显示完成态，返回任务中心继续下一单。
class ProcurementInspectionPage extends ConsumerStatefulWidget {
  const ProcurementInspectionPage({super.key});

  @override
  ConsumerState<ProcurementInspectionPage> createState() =>
      _ProcurementInspectionPageState();
}

class _ProcurementInspectionPageState
    extends ConsumerState<ProcurementInspectionPage> {
  static const int _pageSize = 10;

  List<PendingInspectionReceipt>? _receipts;
  bool _loading = false;
  String? _error;

  /// 搜索关键字（收货单号/供应商），UtenSearchBar 300ms 防抖后回写。
  String _keyword = '';

  /// 指标卡类型筛选：null = 全部；PURCHASE / SUBCONTRACT。
  String? _typeFilter;
  int _page = 1;

  bool get _canHandle {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.procurementInspectionHandle);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await ref
          .read(procurementInspectionRepositoryProvider)
          .pendingReceipts();
      if (!mounted) return;
      setState(() {
        _receipts = rows;
        _loading = false;
        if (_page > _totalPages) _page = _totalPages;
      });
      ref.invalidate(procurementInspectionPendingCountProvider);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '待检任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _applySearch(String value) {
    if (value == _keyword) return;
    setState(() {
      _keyword = value;
      _page = 1;
    });
  }

  /// 再点已选的类型卡取消筛选，回到全部。
  void _applyTypeFilter(String type) {
    setState(() {
      _typeFilter = _typeFilter == type ? null : type;
      _page = 1;
    });
  }

  bool _matchesKeyword(PendingInspectionReceipt receipt) {
    final keyword = _keyword.trim().toLowerCase();
    if (keyword.isEmpty) return true;
    return (receipt.billNo ?? '').toLowerCase().contains(keyword) ||
        (receipt.supplierName ?? '').toLowerCase().contains(keyword);
  }

  List<PendingInspectionReceipt> get _filtered => [
    for (final receipt in _receipts ?? const <PendingInspectionReceipt>[])
      if ((_typeFilter == null || receipt.receiptType == _typeFilter) &&
          _matchesKeyword(receipt))
        receipt,
  ];

  int get _totalPages {
    final pages = (_filtered.length + _pageSize - 1) ~/ _pageSize;
    return pages < 1 ? 1 : pages;
  }

  List<PendingInspectionReceipt> get _pageItems {
    final start = (_page - 1) * _pageSize;
    if (start >= _filtered.length) return const [];
    var end = start + _pageSize;
    if (end > _filtered.length) end = _filtered.length;
    return _filtered.sublist(start, end);
  }

  Future<void> _openDetail(PendingInspectionReceipt receipt) async {
    await context.push(
      RouteName.warehouseInspectionDetail(receipt.receiptType, receipt.receiptId),
      extra: receipt,
    );
    if (!mounted) return;
    // 处置页返回后重拉队列（本单可能已结案）并同步角标。
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '待检处置(IQC)',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.qualityTaskCenter),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && _receipts != null,
              onPressed: _loading ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && _receipts == null
            ? const UtenSkeletonList()
            : _error != null && _receipts == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : _buildList(),
      ),
    );
  }

  Widget _buildList() {
    final pageItems = _pageItems;
    return UtenContentContainer.narrow(
      child: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          children: [
            UtenSearchBar(
              key: const Key('iqc-search'),
              hint: '搜索收货单号 / 供应商',
              initialValue: _keyword,
              onChanged: _applySearch,
            ),
            const SizedBox(height: UtenSpacing.s12),
            // 指标卡 = 类型筛选器。待检队列无分页接口、整队一次拉全，
            // 计数直接取全量列表口径（不是当前页推算），与后端 pendingCount 同源。
            Semantics(
              header: true,
              label: '共有 ${_receipts?.length ?? 0} 张待检收货单',
              child: MetricFilterCards(
                key: const Key('iqc-metric-cards'),
                items: [
                  MetricFilterCardItem(
                    key: 'all',
                    label: '全部待检单',
                    value: _receipts?.length,
                    icon: Icons.fact_check_outlined,
                    selected: _typeFilter == null,
                    onTap: _typeFilter == null
                        ? null
                        : () => setState(() {
                            _typeFilter = null;
                            _page = 1;
                          }),
                  ),
                  MetricFilterCardItem(
                    key: 'purchase',
                    label: '采购收货待检',
                    value: _receipts
                        ?.where((receipt) => !receipt.isSubcontract)
                        .length,
                    icon: Icons.local_shipping_outlined,
                    selected: _typeFilter == 'PURCHASE',
                    onTap: () => _applyTypeFilter('PURCHASE'),
                  ),
                  MetricFilterCardItem(
                    key: 'subcontract',
                    label: '委外回厂待检',
                    value: _receipts
                        ?.where((receipt) => receipt.isSubcontract)
                        .length,
                    tone: 'accent',
                    icon: Icons.precision_manufacturing_outlined,
                    selected: _typeFilter == 'SUBCONTRACT',
                    onTap: () => _applyTypeFilter('SUBCONTRACT'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            _ScopeHintBanner(
              message: _canHandle
                  ? '采购/委外收货送检后出现在这里：点「检验本单」进入处置页，'
                        '常规合格可勾选多行一次放行；部分合格或不合格逐行登记。'
                  : '当前为只读查看；品质处置需要 procurement_inspection:handle 权限。',
            ),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '刷新失败：$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (pageItems.isEmpty)
              SizedBox(
                height: 380,
                child: UtenEmpty(
                  icon: Icons.verified_outlined,
                  message: _emptyMessage,
                  description: _emptyDescription,
                ),
              )
            else
              for (var i = 0; i < pageItems.length; i++) ...[
                _PendingReceiptCard(
                  key: Key('iqc-receipt-card-${pageItems[i].receiptId}'),
                  receipt: pageItems[i],
                  canHandle: _canHandle,
                  onOpen: () => _openDetail(pageItems[i]),
                ),
                if (i != pageItems.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            if (_totalPages > 1) ...[
              const SizedBox(height: UtenSpacing.s20),
              _Pager(
                page: _page,
                totalPages: _totalPages,
                loading: _loading,
                onPage: (next) => setState(() => _page = next),
              ),
            ],
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }

  String get _emptyMessage {
    if (_keyword.trim().isNotEmpty) return '没有匹配「$_keyword」的待检单';
    if (_typeFilter == 'PURCHASE') return '暂无采购收货待检单';
    if (_typeFilter == 'SUBCONTRACT') return '暂无委外回厂待检单';
    return '暂无待检单';
  }

  String get _emptyDescription {
    if (_keyword.trim().isNotEmpty) return '换个关键字试试，或清除搜索查看全部。';
    if (_typeFilter != null) return '切换上方指标卡可查看另一类型的待检单。';
    return '采购/委外收货送检后会出现在这里。';
  }
}

/// 待检收货单任务卡：类型徽章 + 单号 + 供应商/日期/待检量信息行 + 进入处置按钮。
class _PendingReceiptCard extends StatelessWidget {
  const _PendingReceiptCard({
    super.key,
    required this.receipt,
    required this.canHandle,
    required this.onOpen,
  });

  final PendingInspectionReceipt receipt;
  final bool canHandle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: receipt.isSubcontract ? '委外回厂' : '采购收货',
                  type: receipt.isSubcontract
                      ? UtenStatusBadgeType.accent
                      : UtenStatusBadgeType.info,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    receipt.billNo ?? receipt.receiptId,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            _InfoLine(
              icon: Icons.storefront_outlined,
              label: '供应商',
              value: receipt.supplierName ?? '—',
            ),
            _InfoLine(
              icon: Icons.event_outlined,
              label: '单据日期',
              value: receipt.billDate ?? '—',
            ),
            _InfoLine(
              icon: Icons.schedule_outlined,
              label: '最近到检',
              value: _fmtDateTime(receipt.lastReceivedAt) ?? '—',
            ),
            _InfoLine(
              icon: Icons.inventory_outlined,
              label: '待检',
              value:
                  '${receipt.itemCount} 行明细 · 待检量 ${_fmt(receipt.pendingBaseQty ?? 0)}',
            ),
            const SizedBox(height: UtenSpacing.s8),
            SizedBox(
              width: double.infinity,
              child: UtenButton(
                key: Key('iqc-open-detail-${receipt.receiptId}'),
                size: UtenButtonSize.large,
                icon: Icons.fact_check_outlined,
                onPressed: onOpen,
                child: Text('检验本单(${receipt.itemCount} 行待检)'),
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              canHandle ? '进入后勾选多行可一次合格放行。' : '当前为只读查看，不能提交检验决定。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单张收货单的 IQC 处置页：明细多选表格 + 批量合格放行 / 单行检验弹窗。
///
/// 处置只收敛本单明细；本单无剩余待检明细时切换为完成态，返回任务中心
/// 继续下一单（不再自动跳单，两级页面各司其职）。
class ProcurementInspectionDetailPage extends ConsumerStatefulWidget {
  const ProcurementInspectionDetailPage({
    super.key,
    required this.receiptType,
    required this.receiptId,
    this.extra,
  });

  final String receiptType;
  final String receiptId;

  /// 任务中心卡片携带的收货单快照（单号/供应商即时显示）；深链直达时为空，
  /// 页面会从待检队列反查补齐；收货单已不在队列时以完成/不存在态呈现。
  final Object? extra;

  @override
  ConsumerState<ProcurementInspectionDetailPage> createState() =>
      _ProcurementInspectionDetailPageState();
}

class _ProcurementInspectionDetailPageState
    extends ConsumerState<ProcurementInspectionDetailPage> {
  PendingInspectionReceipt? _receipt;
  List<ProcurementInspectionItem> _items = const [];
  bool _loading = true;
  bool _busyDecision = false;
  String? _error;
  Set<String> _selectedItemIds = const {};
  final Map<String, String> _decisionKeys = {};
  int _requestVersion = 0;

  bool get _canHandle {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.procurementInspectionHandle);
  }

  PendingInspectionReceipt? get _snapshot =>
      widget.extra is PendingInspectionReceipt
          ? widget.extra! as PendingInspectionReceipt
          : null;

  @override
  void initState() {
    super.initState();
    _receipt = _snapshot;
    _load();
  }

  bool _isOpenItem(ProcurementInspectionItem item) {
    final remaining = item.remainingBaseQty ?? 0;
    return remaining > 0 &&
        item.status != 'RESOLVED' &&
        item.status != 'REVERSED';
  }

  Future<void> _load() async {
    final request = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(procurementInspectionRepositoryProvider);
      var summary = _receipt;
      final snapshotStale =
          summary == null ||
          summary.receiptType != widget.receiptType ||
          summary.receiptId != widget.receiptId;
      if (snapshotStale) {
        final rows = await repo.pendingReceipts();
        summary = rows
            .where(
              (row) =>
                  row.receiptType == widget.receiptType &&
                  row.receiptId == widget.receiptId,
            )
            .firstOrNull;
      }
      final rows = await repo.items(widget.receiptType, widget.receiptId);
      if (!mounted || request != _requestVersion) return;
      final openRows = rows.where(_isOpenItem).toList(growable: false);
      setState(() {
        if (summary != null) _receipt = summary;
        _items = openRows;
        _selectedItemIds = const {};
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || request != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _requestVersion) return;
      setState(() {
        _error = '待检明细加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  List<ProcurementInspectionItem> get _selectedItems => [
    for (final item in _items)
      if (_selectedItemIds.contains(item.id)) item,
  ];

  double get _pendingBaseQty => _items.fold(
    0,
    (sum, item) => sum + (item.remainingBaseQty ?? 0),
  );

  String _idempotencyKeyFor(
    ProcurementInspectionItem item,
    String action,
    double? qty,
    String? reason,
  ) {
    final canonical = [
      '${widget.receiptType}:${widget.receiptId}',
      item.id,
      action,
      qty?.toString() ?? 'ALL',
      reason?.trim() ?? '',
    ].join('|');
    return _decisionKeys.putIfAbsent(canonical, () => const Uuid().v4());
  }

  Future<String?> _submitSingle(
    ProcurementInspectionItem item,
    String action,
    double? qty,
    String? reason,
  ) async {
    final key = _idempotencyKeyFor(item, action, qty, reason);
    setState(() => _busyDecision = true);
    try {
      await ref
          .read(procurementInspectionRepositoryProvider)
          .dispose(
            receiptType: widget.receiptType,
            receiptId: widget.receiptId,
            inspectionItemId: item.id,
            action: action,
            baseQty: qty,
            reason: reason,
            idempotencyKey: key,
          );
      if (!mounted) return null;
      setState(() {
        _items = [
          for (final row in _items)
            if (row.id != item.id) row,
        ];
        _selectedItemIds = const {};
      });
      await _load();
      ref.invalidate(procurementInspectionPendingCountProvider);
      if (mounted) {
        UtenNotify.success(
          context,
          action == 'PASS' ? '合格决定已保存' : '不合格决定已保存',
        );
      }
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      if (mounted) setState(() => _busyDecision = false);
    }
  }

  Future<String?> _submitBatchPass(String? reason) async {
    final selected = _selectedItems;
    if (selected.isEmpty) return '请先选择待检明细';
    if (selected.length > 100) return '一次最多合格放行 100 条明细';
    final commands = [
      for (final item in selected)
        ProcurementInspectionBatchPassItem(
          inspectionItemId: item.id,
          expectedRemainingBaseQty: item.remainingBaseQty ?? 0,
          idempotencyKey: _idempotencyKeyFor(
            item,
            'PASS',
            item.remainingBaseQty,
            reason,
          ),
        ),
    ];
    setState(() => _busyDecision = true);
    try {
      await ref
          .read(procurementInspectionRepositoryProvider)
          .passBatch(
            receiptType: widget.receiptType,
            receiptId: widget.receiptId,
            items: commands,
            reason: reason,
          );
      if (!mounted) return null;
      final completedIds = selected.map((item) => item.id).toSet();
      setState(() {
        _items = [
          for (final row in _items)
            if (!completedIds.contains(row.id)) row,
        ];
        _selectedItemIds = const {};
      });
      await _load();
      ref.invalidate(procurementInspectionPendingCountProvider);
      if (mounted) {
        UtenNotify.success(context, '已原子合格放行 ${selected.length} 条明细');
      }
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      if (mounted) setState(() => _busyDecision = false);
    }
  }

  Future<void> _openItemDecision(
    ProcurementInspectionItem item, {
    String initialAction = 'PASS',
    bool requireQuantity = false,
  }) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: !_busyDecision,
      builder: (dialogContext) => _InspectionDecisionDialog(
        item: item,
        initialAction: initialAction,
        requireQuantity: requireQuantity,
        onSubmit: (action, qty, reason) =>
            _submitSingle(item, action, qty, reason),
      ),
    );
  }

  Future<void> _openBatchPass() async {
    final selected = _selectedItems;
    if (selected.isEmpty) {
      UtenNotify.warning(context, '请先选择要合格放行的明细');
      return;
    }
    await showDialog<bool>(
      context: context,
      barrierDismissible: !_busyDecision,
      builder: (dialogContext) =>
          _BatchPassDialog(items: selected, onSubmit: _submitBatchPass),
    );
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final selected = _selectedItems;
    final single = selected.length == 1 ? selected.single : null;
    return [
      UtenButton(
        key: const Key('iqc-single-fail'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        onPressed: single == null || _busyDecision
            ? null
            : () => _openItemDecision(single, initialAction: 'FAIL'),
        child: const Text('登记不合格(单行)'),
      ),
      UtenButton(
        key: const Key('iqc-single-partial-pass'),
        type: UtenButtonType.tonal,
        size: UtenButtonSize.large,
        onPressed: single == null || _busyDecision
            ? null
            : () => _openItemDecision(single, requireQuantity: true),
        child: const Text('部分合格(单行)'),
      ),
      UtenButton(
        key: const Key('iqc-batch-pass'),
        size: UtenButtonSize.large,
        isLoading: _busyDecision,
        onPressed:
            selectedIds.isEmpty || selectedIds.length > 100 || _busyDecision
            ? null
            : _openBatchPass,
        child: Text('批量合格放行(${selectedIds.length})'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final receipt = _receipt;
    return Scaffold(
      appBar: UtenAppBar(
        title: '检验处置 · ${receipt?.billNo ?? widget.receiptId}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && _items.isNotEmpty,
              onPressed: _loading || _busyDecision ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    // 无快照且拿不到摘要：加载中 / 加载失败 / 不存在（或已处理完）三态。
    if (_receipt == null && _items.isEmpty) {
      if (_loading) {
        return const UtenSkeletonList();
      }
      if (_error != null) {
        return UtenEmpty.error(
          message: _error,
          actionLabel: '重新加载',
          onAction: _load,
        );
      }
      return UtenEmpty(
        icon: Icons.verified_outlined,
        message: '待检单不存在或已处理完成',
        description: '该收货单可能已被其他品质同事处理完毕，或链接已过期。',
        actionLabel: '返回任务中心',
        onAction: () =>
            popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
      );
    }
    // 本单明细全部处置完成：完成态替代工作区。
    if (_items.isEmpty && !_loading && _error == null) {
      return UtenEmpty(
        icon: Icons.verified_outlined,
        message: '本单待检已全部处理完成',
        description: '合格放行的货品已自动入库；返回任务中心可处理下一单。',
        actionLabel: '返回任务中心',
        onAction: () =>
            popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
      );
    }
    final theme = Theme.of(context);
    return UtenContentContainer.wide(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSummaryCard(theme),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            _InlineWorkbenchError(message: _error!, onRetry: _load),
          ],
          if (_busyDecision) ...[
            const SizedBox(height: UtenSpacing.s8),
            const LinearProgressIndicator(
              key: Key('iqc-decision-progress'),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          Expanded(child: _buildItemTable()),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(ThemeData theme) {
    final receipt = _receipt!;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: receipt.isSubcontract ? '委外回厂' : '采购收货',
                  type: receipt.isSubcontract
                      ? UtenStatusBadgeType.accent
                      : UtenStatusBadgeType.info,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    receipt.billNo ?? receipt.receiptId,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            _InfoLine(
              icon: Icons.storefront_outlined,
              label: '供应商',
              value: receipt.supplierName ?? '—',
            ),
            _InfoLine(
              icon: Icons.event_outlined,
              label: '单据日期',
              value: receipt.billDate ?? '—',
            ),
            _InfoLine(
              icon: Icons.schedule_outlined,
              label: '最近到检',
              value: _fmtDateTime(receipt.lastReceivedAt) ?? '—',
            ),
            _InfoLine(
              icon: Icons.inventory_outlined,
              label: '待检',
              value: '${_items.length} 行明细 · 待检量 ${_fmt(_pendingBaseQty)}',
            ),
            const Divider(height: UtenSpacing.s24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    _canHandle
                        ? '勾选多行可一次批量合格放行；双击行或右键菜单做单行检验、部分合格与不合格。'
                        : '当前为只读查看；品质处置需要 procurement_inspection:handle 权限。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemTable() {
    return AbsorbPointer(
      absorbing: _busyDecision,
      child: MasterDataTableView<ProcurementInspectionItem>(
        key: ValueKey('iqc-item-table-${widget.receiptId}'),
        columns: _itemColumns,
        items: _items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        selectable: _canHandle,
        idOf: (item) => _isOpenItem(item) ? item.id : null,
        selectedIds: _selectedItemIds,
        onSelectedIdsChanged: (next) =>
            setState(() => _selectedItemIds = next),
        batchActionsBuilder: _canHandle ? _batchActions : null,
        onRowTap: _canHandle ? _openItemDecision : null,
        canOpenRow: _isOpenItem,
        rowMenuBuilder: _canHandle
            ? (item) => [
                UtenMenuItem(
                  label: '检验本行',
                  icon: Icons.fact_check_outlined,
                  onTap: () => _openItemDecision(item),
                ),
                UtenMenuItem(
                  label: '部分合格',
                  icon: Icons.rule_rounded,
                  onTap: () =>
                      _openItemDecision(item, requireQuantity: true),
                ),
                UtenMenuItem(
                  label: '登记不合格',
                  icon: Icons.block_rounded,
                  onTap: () =>
                      _openItemDecision(item, initialAction: 'FAIL'),
                ),
              ]
            : null,
        canShowRowMenu: _isOpenItem,
        isLoading: _loading,
        error: _items.isEmpty ? _error : null,
        onRetry: _load,
        emptyMessage: _loading ? '正在加载待检明细' : '本单已无待检明细',
        showFullscreenToggle: false,
      ),
    );
  }

  List<MasterColumnDef<ProcurementInspectionItem>> get _itemColumns => [
    MasterColumnDef(
      key: 'goods',
      label: '货品',
      width: 220,
      value: (item) => [
        item.goodsName,
        if (item.goodsCode?.isNotEmpty == true) '(${item.goodsCode})',
      ].whereType<String>().join(),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 100,
      value: (item) => item.colorName ?? '—',
    ),
    MasterColumnDef(
      key: 'sourceOrderNo',
      label: '来源订货单',
      width: 160,
      value: (item) => item.sourceOrderNo ?? '—',
    ),
    MasterColumnDef(
      key: 'receivedBaseQty',
      label: '到检量',
      width: 100,
      type: 'number',
      value: (item) => _fmt(item.receivedBaseQty ?? 0),
    ),
    MasterColumnDef(
      key: 'passedBaseQty',
      label: '已合格',
      width: 100,
      type: 'number',
      value: (item) => _fmt(item.passedBaseQty ?? 0),
    ),
    MasterColumnDef(
      key: 'failedBaseQty',
      label: '不合格',
      width: 100,
      type: 'number',
      value: (item) => _fmt(item.failedBaseQty ?? 0),
    ),
    MasterColumnDef(
      key: 'remainingBaseQty',
      label: '剩余待检',
      width: 110,
      type: 'number',
      value: (item) => _fmt(item.remainingBaseQty ?? 0),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 90,
      value: (item) => switch (item.status) {
        'PARTIAL' => '部分处置',
        'RESOLVED' => '已结案',
        'REVERSED' => '已撤销',
        _ => '待检',
      },
    ),
  ];
}

class _InspectionDecisionDialog extends StatefulWidget {
  const _InspectionDecisionDialog({
    required this.item,
    required this.initialAction,
    required this.requireQuantity,
    required this.onSubmit,
  });

  final ProcurementInspectionItem item;
  final String initialAction;
  final bool requireQuantity;
  final Future<String?> Function(String action, double? qty, String? reason)
  onSubmit;

  @override
  State<_InspectionDecisionDialog> createState() =>
      _InspectionDecisionDialogState();
}

class _InspectionDecisionDialogState extends State<_InspectionDecisionDialog> {
  late String _action = widget.initialAction;
  final TextEditingController _qty = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  String? _qtyError;
  String? _reasonError;
  String? _submitError;
  bool _saving = false;

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pass = _action == 'PASS';
    final qtyText = _qty.text.trim();
    final reason = _reason.text.trim();
    double? qty;
    String? qtyError;
    if (qtyText.isNotEmpty) {
      qty = double.tryParse(qtyText);
      if (qty == null ||
          qty <= 0 ||
          qty > (widget.item.remainingBaseQty ?? 0)) {
        qtyError = '须为正数且不超过剩余 ${_fmt(widget.item.remainingBaseQty ?? 0)}';
      }
    } else if (widget.requireQuantity) {
      qtyError = '部分合格必须填写本次合格数量';
    }
    final reasonError = !pass && reason.isEmpty ? '不合格原因必填' : null;
    if (qtyError != null || reasonError != null) {
      setState(() {
        _qtyError = qtyError;
        _reasonError = reasonError;
      });
      return;
    }
    setState(() {
      _saving = true;
      _submitError = null;
      _qtyError = null;
      _reasonError = null;
    });
    final error = await widget.onSubmit(
      _action,
      qty,
      reason.isEmpty ? null : reason,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _submitError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pass = _action == 'PASS';
    final goodsLabel = [
      widget.item.goodsName,
      widget.item.goodsCode,
      widget.item.colorName,
    ].where((text) => text?.isNotEmpty == true).join(' · ');
    return AlertDialog(
      title: const Text('检验本行'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenReviewerResponsibilityNotice(
                actionLabel: pass ? '合格放行' : '不合格处置',
                description: '系统将记录审核员、结论、数量与时间，请依据本行实物检验结果确认。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                goodsLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '剩余待检 ${_fmt(widget.item.remainingBaseQty ?? 0)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'PASS',
                    label: Text('合格', key: Key('iqc-action-pass')),
                  ),
                  ButtonSegment(
                    value: 'FAIL',
                    label: Text('不合格', key: Key('iqc-action-fail')),
                  ),
                ],
                selected: {_action},
                onSelectionChanged: _saving
                    ? null
                    : (selection) => setState(() {
                        _action = selection.first;
                        _reasonError = null;
                        _submitError = null;
                      }),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _qty,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: pass ? '合格数量' : '不合格数量',
                  helperText: widget.requireQuantity
                      ? '必填；部分处置后本行继续保留'
                      : '留空 = 全部剩余待检量',
                  errorText: _qtyError,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _reason,
                enabled: !_saving,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: pass ? '放行说明(选填)' : '不合格原因(必填)',
                  errorText: _reasonError,
                ),
              ),
              if (_submitError != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _submitError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          isLoading: _saving,
          type: pass ? UtenButtonType.primary : UtenButtonType.danger,
          onPressed: _saving ? null : _submit,
          child: Text(pass ? '确认合格' : '确认不合格'),
        ),
      ],
    );
  }
}

class _BatchPassDialog extends StatefulWidget {
  const _BatchPassDialog({required this.items, required this.onSubmit});

  final List<ProcurementInspectionItem> items;
  final Future<String?> Function(String? reason) onSubmit;

  @override
  State<_BatchPassDialog> createState() => _BatchPassDialogState();
}

class _BatchPassDialogState extends State<_BatchPassDialog> {
  final TextEditingController _reason = TextEditingController();
  String? _submitError;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _submitError = null;
    });
    final reason = _reason.text.trim();
    final error = await widget.onSubmit(reason.isEmpty ? null : reason);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _submitError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('批量合格放行 ${widget.items.length} 条'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const UtenReviewerResponsibilityNotice(
                actionLabel: '批量合格放行',
                description: '本次仅处理当前收货单中已勾选的明细；任一行状态变化都会整批回滚。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '将按各行当前全部剩余待检量放行：',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              for (final item in widget.items.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                  child: Text(
                    '• ${item.goodsName ?? item.goodsCode ?? item.id} · '
                    '${_fmt(item.remainingBaseQty ?? 0)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (widget.items.length > 6)
                Text(
                  '另有 ${widget.items.length - 6} 条',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _reason,
                enabled: !_saving,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(labelText: '统一放行说明(选填)'),
              ),
              if (_submitError != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _submitError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          isLoading: _saving,
          onPressed: _saving ? null : _submit,
          child: const Text('确认整批合格'),
        ),
      ],
    );
  }
}

class _InlineWorkbenchError extends StatelessWidget {
  const _InlineWorkbenchError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(width: 80, child: Text('$label：')),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _Pager extends StatelessWidget {
  const _Pager({
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
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          icon: Icons.chevron_left_rounded,
          onPressed: !loading && page > 1 ? () => onPage(page - 1) : null,
          child: const Text('上一页'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: Text('第 $page / $totalPages 页'),
        ),
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          icon: Icons.chevron_right_rounded,
          onPressed: !loading && page < totalPages
              ? () => onPage(page + 1)
              : null,
          child: const Text('下一页'),
        ),
      ],
    );
  }
}

/// 口径提示条：指标卡下方整行说明（与预计到货任务中心同款布局），
/// 浅蓝 info 容器色（灰底 + hover 会被误读成「灰色面板」）。
class _ScopeHintBanner extends StatelessWidget {
  const _ScopeHintBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background = isDark
        ? UtenColors.infoContainerDark
        : UtenColors.infoContainer;
    final foreground = isDark
        ? UtenColors.onInfoContainerDark
        : UtenColors.onInfoContainer;
    return Semantics(
      container: true,
      label: '筛选口径：$message',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: foreground.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: foreground),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmt(double value) {
  final text = value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
}

/// OffsetDateTime 序列化值 → 'yyyy-MM-dd HH:mm'；解析不了原样返回。
String? _fmtDateTime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final text = iso.replaceFirst('T', ' ');
  return text.length > 16 ? text.substring(0, 16) : text;
}
