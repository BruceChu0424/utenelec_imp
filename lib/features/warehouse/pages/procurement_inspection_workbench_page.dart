import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../repositories/procurement_inspection_repository.dart';

/// 采购/委外收货 IQC 连续处置工作台。
///
/// 左侧（窄屏为上方）是待检收货单队列，右侧（窄屏为下方）固定显示当前收货单
/// 的待检明细表。处置后只收敛当前表格；本单结案时自动进入下一单，不再反复折叠重开。
class ProcurementInspectionPage extends ConsumerStatefulWidget {
  const ProcurementInspectionPage({super.key});

  @override
  ConsumerState<ProcurementInspectionPage> createState() =>
      _ProcurementInspectionPageState();
}

class _ProcurementInspectionPageState
    extends ConsumerState<ProcurementInspectionPage> {
  bool _queueLoading = true;
  bool _itemsLoading = false;
  bool _busyDecision = false;
  String? _queueError;
  String? _itemsError;
  String? _announcement;
  List<PendingInspectionReceipt> _receipts = const [];
  List<ProcurementInspectionItem> _items = const [];
  String? _activeReceiptKey;
  Set<String> _selectedItemIds = const {};
  final Map<String, String> _decisionKeys = {};
  int _queueRequest = 0;
  int _itemRequest = 0;

  bool get _canHandle {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.procurementInspectionHandle);
  }

  PendingInspectionReceipt? get _activeReceipt {
    final activeKey = _activeReceiptKey;
    if (activeKey == null) return null;
    for (final receipt in _receipts) {
      if (_receiptKey(receipt) == activeKey) return receipt;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  String _receiptKey(PendingInspectionReceipt receipt) =>
      '${receipt.receiptType}:${receipt.receiptId}';

  bool _isOpenItem(ProcurementInspectionItem item) {
    final remaining = item.remainingBaseQty ?? 0;
    return remaining > 0 &&
        item.status != 'RESOLVED' &&
        item.status != 'REVERSED';
  }

  Future<void> _reload({bool announceAdvance = false}) async {
    final request = ++_queueRequest;
    final previousKey = _activeReceiptKey;
    final previousIndex = previousKey == null
        ? 0
        : _receipts.indexWhere(
            (receipt) => _receiptKey(receipt) == previousKey,
          );
    setState(() {
      _queueLoading = _receipts.isEmpty;
      _queueError = null;
    });
    try {
      final rows = await ref
          .read(procurementInspectionRepositoryProvider)
          .pendingReceipts();
      if (!mounted || request != _queueRequest) return;
      String? nextKey;
      if (previousKey != null &&
          rows.any((receipt) => _receiptKey(receipt) == previousKey)) {
        nextKey = previousKey;
      } else if (rows.isNotEmpty) {
        final index = previousIndex < 0
            ? 0
            : previousIndex.clamp(0, rows.length - 1);
        nextKey = _receiptKey(rows[index]);
      }
      final advanced =
          previousKey != null && nextKey != null && previousKey != nextKey;
      setState(() {
        _receipts = rows;
        _activeReceiptKey = nextKey;
        _queueLoading = false;
        _selectedItemIds = const {};
        if (rows.isEmpty) {
          _items = const [];
          _itemsLoading = false;
          _announcement = '全部待检收货单已处理完成';
        } else if (announceAdvance && advanced) {
          final next = rows.firstWhere(
            (receipt) => _receiptKey(receipt) == nextKey,
          );
          _announcement =
              '本单已处理完成，已自动进入下一张待检单：${next.billNo ?? next.receiptId}';
        }
      });
      if (nextKey != null) await _loadItems(nextKey);
    } catch (error) {
      if (!mounted || request != _queueRequest) return;
      setState(() {
        _queueLoading = false;
        _queueError = error.toString();
      });
    }
  }

  Future<void> _loadItems(String receiptKey) async {
    final receipt = _receipts
        .where((row) => _receiptKey(row) == receiptKey)
        .firstOrNull;
    if (receipt == null) return;
    final request = ++_itemRequest;
    setState(() {
      _itemsLoading = true;
      _itemsError = null;
      _selectedItemIds = const {};
    });
    try {
      final rows = await ref
          .read(procurementInspectionRepositoryProvider)
          .items(receipt.receiptType, receipt.receiptId);
      if (!mounted ||
          request != _itemRequest ||
          _activeReceiptKey != receiptKey) {
        return;
      }
      final openRows = rows.where(_isOpenItem).toList(growable: false);
      setState(() {
        _items = openRows;
        _itemsLoading = false;
      });
      if (openRows.isEmpty) await _advancePastResolved(receiptKey);
    } catch (error) {
      if (!mounted ||
          request != _itemRequest ||
          _activeReceiptKey != receiptKey) {
        return;
      }
      setState(() {
        _itemsLoading = false;
        _itemsError = error.toString();
      });
    }
  }

  Future<void> _advancePastResolved(String receiptKey) async {
    final index = _receipts.indexWhere(
      (receipt) => _receiptKey(receipt) == receiptKey,
    );
    if (index < 0) return;
    final remaining = [
      for (final receipt in _receipts)
        if (_receiptKey(receipt) != receiptKey) receipt,
    ];
    final next = remaining.isEmpty
        ? null
        : remaining[index.clamp(0, remaining.length - 1)];
    setState(() {
      _receipts = remaining;
      _activeReceiptKey = next == null ? null : _receiptKey(next);
      _items = const [];
      _selectedItemIds = const {};
      _announcement = next == null
          ? '全部待检收货单已处理完成'
          : '本单已处理完成，已自动进入下一张待检单：${next.billNo ?? next.receiptId}';
    });
    if (next != null) await _loadItems(_receiptKey(next));
  }

  Future<void> _selectReceipt(PendingInspectionReceipt receipt) async {
    if (_busyDecision) return;
    final key = _receiptKey(receipt);
    if (key == _activeReceiptKey && _items.isNotEmpty) return;
    setState(() {
      _activeReceiptKey = key;
      _items = const [];
      _itemsError = null;
      _selectedItemIds = const {};
      _announcement = '已选择待检单：${receipt.billNo ?? receipt.receiptId}';
    });
    await _loadItems(key);
  }

  List<ProcurementInspectionItem> get _selectedItems => [
    for (final item in _items)
      if (_selectedItemIds.contains(item.id)) item,
  ];

  String _idempotencyKeyFor(
    ProcurementInspectionItem item,
    String action,
    double? qty,
    String? reason,
  ) {
    final canonical = [
      _activeReceiptKey ?? '',
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
    final receipt = _activeReceipt;
    if (receipt == null) return '当前待检单已变化，请刷新后重试';
    final key = _idempotencyKeyFor(item, action, qty, reason);
    setState(() => _busyDecision = true);
    try {
      await ref
          .read(procurementInspectionRepositoryProvider)
          .dispose(
            receiptType: receipt.receiptType,
            receiptId: receipt.receiptId,
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
        _announcement = '检验决定已保存，可继续处理本单剩余明细';
      });
      await _reload(announceAdvance: true);
      if (mounted) {
        UtenNotify.success(context, action == 'PASS' ? '合格决定已保存' : '不合格决定已保存');
      }
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      if (mounted) setState(() => _busyDecision = false);
    }
  }

  Future<String?> _submitBatchPass(String? reason) async {
    final receipt = _activeReceipt;
    final selected = _selectedItems;
    if (receipt == null) return '当前待检单已变化，请刷新后重试';
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
            receiptType: receipt.receiptType,
            receiptId: receipt.receiptId,
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
        _announcement = '已合格放行 ${selected.length} 条，可继续处理本单剩余明细';
      });
      await _reload(announceAdvance: true);
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '待检处置(IQC)',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.qualityTaskCenter),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busyDecision ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  top: UtenSpacing.s8,
                  bottom: UtenSpacing.s8,
                ),
                child: Row(
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
                            ? '先选择待检收货单，再在明细表勾选多行。常规合格可一次放行；部分合格或不合格保留单行质量依据。'
                            : '当前为只读查看；品质处置需要 procurement_inspection:handle 权限。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              if (_announcement != null)
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                    child: Text(
                      _announcement!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (_busyDecision)
                const LinearProgressIndicator(
                  key: Key('iqc-decision-progress'),
                ),
              if (_busyDecision) const SizedBox(height: UtenSpacing.s8),
              Expanded(child: _buildWorkspace(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspace(ThemeData theme) {
    if (_receipts.isEmpty) {
      if (_queueLoading) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
      }
      if (_queueError != null) {
        return UtenEmpty(
          icon: Icons.error_outline_rounded,
          message: '待检任务加载失败',
          description: _queueError,
          actionLabel: '重试',
          onAction: _reload,
          isError: true,
        );
      }
      return UtenEmpty(
        icon: Icons.verified_outlined,
        message: '暂无待检单',
        description: '采购/委外收货送检后会出现在这里',
        actionLabel: '刷新',
        onAction: _reload,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final queue = _buildQueuePanel(theme);
        final details = _buildDetailPanel(theme);
        if (constraints.maxWidth >= 1000) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 460, child: queue),
              const VerticalDivider(width: UtenSpacing.s16),
              Expanded(child: details),
            ],
          );
        }
        final queueHeight = (constraints.maxHeight * 0.36)
            .clamp(190.0, 300.0)
            .toDouble();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: queueHeight, child: queue),
            const Divider(height: UtenSpacing.s16),
            Expanded(child: details),
          ],
        );
      },
    );
  }

  Widget _buildQueuePanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '待检收货单',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                _queueLoading ? '同步中…' : '共 ${_receipts.length} 单',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (_queueError != null && _receipts.isNotEmpty) ...[
          _InlineWorkbenchError(message: _queueError!, onRetry: _reload),
          const SizedBox(height: UtenSpacing.s8),
        ],
        Expanded(
          child: AbsorbPointer(
            absorbing: _busyDecision,
            child: MasterDataTableView<PendingInspectionReceipt>(
              key: const Key('iqc-receipt-queue-table'),
              columns: _receiptColumns,
              items: _receipts,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              onSelectionChanged: (receipt) => _selectReceipt(receipt),
              onRowTap: (receipt) => _selectReceipt(receipt),
              isSelected: (receipt) =>
                  _receiptKey(receipt) == _activeReceiptKey,
              rowColor: (receipt) => _receiptKey(receipt) == _activeReceiptKey
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
                  : null,
              isLoading: _queueLoading,
              error: _receipts.isEmpty ? _queueError : null,
              onRetry: _reload,
              emptyMessage: '暂无待检收货单',
              showFullscreenToggle: false,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailPanel(ThemeData theme) {
    final receipt = _activeReceipt;
    if (receipt == null) {
      return UtenEmpty(
        icon: _receipts.isEmpty
            ? Icons.verified_outlined
            : Icons.fact_check_outlined,
        message: _receipts.isEmpty ? '暂无待检单' : '请选择待检收货单',
        description: _receipts.isEmpty
            ? '采购/委外收货送检后会出现在这里'
            : '单击上方或左侧队列表格，明细会固定显示在这里',
        actionLabel: '刷新',
        onAction: _reload,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                receipt.billNo ?? receipt.receiptId,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '${receipt.isSubcontract ? '委外回厂' : '采购收货'} · '
                '${receipt.supplierName ?? '—'} · '
                '待检 ${_fmt(receipt.pendingBaseQty ?? 0)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                _canHandle ? '单击勾选，双击检验本行' : '只读',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (_itemsError != null) ...[
          _InlineWorkbenchError(
            message: _itemsError!,
            onRetry: () => _loadItems(_receiptKey(receipt)),
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        Expanded(
          child: AbsorbPointer(
            absorbing: _busyDecision,
            child: MasterDataTableView<ProcurementInspectionItem>(
              key: ValueKey('iqc-item-table-${receipt.receiptId}'),
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
              isLoading: _itemsLoading,
              error: _items.isEmpty ? _itemsError : null,
              onRetry: () => _loadItems(_receiptKey(receipt)),
              emptyMessage: _itemsLoading ? '正在加载待检明细' : '本单已无待检明细',
              showFullscreenToggle: false,
            ),
          ),
        ),
      ],
    );
  }

  List<MasterColumnDef<PendingInspectionReceipt>> get _receiptColumns => [
    MasterColumnDef(
      key: 'receiptType',
      label: '类型',
      width: 92,
      value: (receipt) => receipt.isSubcontract ? '委外回厂' : '采购收货',
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '收货单号',
      width: 160,
      value: (receipt) => receipt.billNo ?? receipt.receiptId,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 180,
      value: (receipt) => receipt.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '待检行',
      width: 88,
      type: 'number',
      value: (receipt) => receipt.itemCount.toString(),
    ),
    MasterColumnDef(
      key: 'pendingBaseQty',
      label: '待检量',
      width: 100,
      type: 'number',
      value: (receipt) => _fmt(receipt.pendingBaseQty ?? 0),
    ),
  ];

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

String _fmt(double value) {
  final text = value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
}
