// 应收应付核销引入面板（收款/付款编辑页"从应收应付引入"用）。
//
// 重做（2026-07-29）：从居中 Dialog + 卡片/CheckboxListTile 换成右滑入大面板
//（840，与销售/采购/委外引入统一），Excel 表形式：
//  搜索框（按单据号过滤）+ UtenEditableGrid 勾选表：单据号 / 日期 / 立帐金额 /
//  已核销 / 余额 / 本次核销额（默认 = 余额）。
// 确认返回所选 [AppliedArAp] 列表，编辑页据此外推明细行（appliedLedgerId +
// amountOriginal/Local）。
//
// 输入：direction（AR=客户应收 / AP=供应商应付）+ partyId（客户/供应商）。
// 拉该往来方未清台账（settled=false）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';

/// 核销回填项：台账行 id + 本次核销额（本币）+ 原币额（默认同本币）+ 单据号（展示/审计）。
class AppliedArAp {
  const AppliedArAp({
    required this.ledgerId,
    required this.appliedBillNo,
    required this.amountLocal,
    this.amountOriginal,
  });
  final String ledgerId;
  final String? appliedBillNo;
  final double amountLocal;
  final double? amountOriginal;
}

/// 弹出核销引入右滑入大面板。[direction] = 'AR'（收款）/ 'AP'（付款）。
Future<List<AppliedArAp>?> showArApPickerDialog(
  BuildContext context,
  WidgetRef ref, {
  required String direction,
  required String? partyId,
}) {
  final sheet = _ArApPickerSheet(direction: direction, partyId: partyId);
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<List<AppliedArAp>>(
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
  return showGeneralDialog<List<AppliedArAp>>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: SizedBox(width: 840, height: double.infinity, child: sheet),
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

/// 台账勾选行：只持选中态；金额控制器由面板按 ledgerId 持有（过滤重建行时不丢输入）。
class _LedgerRow extends EditableGridRow {
  _LedgerRow(this.item, bool selected)
    : selectedNotifier = ValueNotifier<bool>(selected);
  final ArApLedgerItem item;
  final ValueNotifier<bool> selectedNotifier;
  bool get selected => selectedNotifier.value;

  @override
  void dispose() {
    selectedNotifier.dispose();
    super.dispose();
  }
}

class _ArApPickerSheet extends ConsumerStatefulWidget {
  const _ArApPickerSheet({required this.direction, required this.partyId});
  final String direction;
  final String? partyId;

  @override
  ConsumerState<_ArApPickerSheet> createState() => _ArApPickerSheetState();
}

class _ArApPickerSheetState extends ConsumerState<_ArApPickerSheet> {
  List<ArApLedgerItem> _items = const [];
  bool _loading = false;
  String? _error;

  final _keywordCtl = TextEditingController();
  String _keyword = '';

  /// 选中态 / 金额输入按台账行 id 持有：搜索过滤重建表格行时状态不丢。
  final Set<String> _selectedIds = {};
  final Map<String, TextEditingController> _amtCtrls = {};

  late final UtenEditableGridController<_LedgerRow> _grid;

  bool get _isAr => widget.direction == 'AR';

  @override
  void initState() {
    super.initState();
    _grid = UtenEditableGridController<_LedgerRow>();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    for (final c in _amtCtrls.values) {
      c.dispose();
    }
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.partyId == null || widget.partyId!.isEmpty) {
      setState(() {
        _items = const [];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(arApLedgerRepositoryProvider)
          .openItemsForParty(
            direction: widget.direction,
            partyId: widget.partyId!,
          );
      if (!mounted) return;
      for (final it in r.items) {
        _amtCtrls[it.id] = TextEditingController(
          text: (it.amountBalance ?? 0).toStringAsFixed(2),
        );
      }
      setState(() {
        _items = r.items;
        _loading = false;
      });
      _rebuildGrid();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载应收应付台账失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  List<ArApLedgerItem> get _visibleItems {
    final kw = _keyword.trim();
    if (kw.isEmpty) return _items;
    return _items
        .where((e) => (e.billNo ?? '').toLowerCase().contains(kw.toLowerCase()))
        .toList();
  }

  void _rebuildGrid() {
    _grid.replaceAll(
      _visibleItems.map((it) => _LedgerRow(it, _selectedIds.contains(it.id))),
    );
  }

  void _onKeywordChanged(String v) {
    _keyword = v;
    _rebuildGrid();
    setState(() {});
  }

  void _toggleRow(_LedgerRow row, bool v) {
    row.selectedNotifier.value = v;
    if (v) {
      _selectedIds.add(row.item.id);
    } else {
      _selectedIds.remove(row.item.id);
    }
    setState(() {});
  }

  void _setSelectedAllVisible(bool v) {
    for (final r in _grid.rows) {
      r.selectedNotifier.value = v;
      if (v) {
        _selectedIds.add(r.item.id);
      } else {
        _selectedIds.remove(r.item.id);
      }
    }
    setState(() {});
  }

  void _invertSelection() {
    for (final r in _grid.rows) {
      final v = !r.selectedNotifier.value;
      r.selectedNotifier.value = v;
      if (v) {
        _selectedIds.add(r.item.id);
      } else {
        _selectedIds.remove(r.item.id);
      }
    }
    setState(() {});
  }

  void _confirm() {
    final out = <AppliedArAp>[];
    for (final it in _items) {
      if (!_selectedIds.contains(it.id)) continue;
      final amt = double.tryParse(_amtCtrls[it.id]?.text ?? '') ?? 0;
      if (amt <= 0) continue;
      out.add(
        AppliedArAp(
          ledgerId: it.id,
          appliedBillNo: it.billNo,
          amountLocal: amt,
          amountOriginal: amt,
        ),
      );
    }
    Navigator.of(context).pop(out);
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    final partyName = _isAr
        ? names.client(widget.partyId)
        : names.supplier(widget.partyId);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(theme, partyName),
            const Divider(height: 1),
            Expanded(child: _buildBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, String partyName) {
    final title = _isAr ? '核销应收 · 选择应收行' : '核销应付 · 选择应付行';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  partyName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (widget.partyId == null || widget.partyId!.isEmpty) {
      return Center(
        child: Text(
          '请先选择${_isAr ? '客户' : '供应商'}', // TODO(l10n): 补 arb
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          '暂无未清${_isAr ? '应收' : '应付'}', // TODO(l10n): 补 arb
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s12,
            UtenSpacing.s12,
            UtenSpacing.s12,
            UtenSpacing.s4,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keywordCtl,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    hintText: '搜索单据号', // TODO(l10n): 补 arb
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onChanged: _onKeywordChanged,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              TextButton(
                onPressed: () => _setSelectedAllVisible(true),
                child: const Text('全选'),
              ), // TODO(l10n): 补 arb
              TextButton(
                onPressed: _invertSelection,
                child: const Text('反选'),
              ), // TODO(l10n): 补 arb
              TextButton(
                onPressed: () => _setSelectedAllVisible(false),
                child: const Text('取消全选'),
              ), // TODO(l10n): 补 arb
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: UtenEditableGrid<_LedgerRow>(
              controller: _grid,
              columns: _columns(),
              showAddRow: false,
              showRowDelete: false,
              createBlankRow: () =>
                  _LedgerRow(const ArApLedgerItem(id: ''), false), // 不会被调用
              emptyMessage: '没有匹配的台账行', // TODO(l10n): 补 arb
            ),
          ),
        ),
        _buildFooter(theme),
      ],
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final n = _selectedIds.length;
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              '已选 $n 行', // TODO(l10n): 补 arb
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            FilledButton.icon(
              onPressed: n == 0 ? null : _confirm,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('核销'), // TODO(l10n): 补 arb
            ),
          ],
        ),
      ),
    );
  }

  List<EditableGridColumn<_LedgerRow>> _columns() => [
    EditableGridColumn<_LedgerRow>(
      key: 'sel',
      label: '',
      width: 50,
      cellBuilder: (context, row) => ValueListenableBuilder<bool>(
        valueListenable: row.selectedNotifier,
        builder: (_, sel, _) =>
            Checkbox(value: sel, onChanged: (v) => _toggleRow(row, v ?? false)),
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'billNo',
      label: '单据号',
      width: 160,
      cellBuilder: (context, row) => Text(
        row.item.billNo ?? '—',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'billDate',
      label: '日期',
      width: 100,
      cellBuilder: (context, row) =>
          Text((row.item.billDate ?? '').substring(0, 10)),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'amount',
      label: '立帐金额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(_fmt(row.item.amountOriginalLocal)),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'settled',
      label: '已核销',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(_fmt(row.item.amountSettled)),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'balance',
      label: '余额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(
        _fmt(row.item.amountBalance),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'thisAmt',
      label: '本次核销额',
      width: 130,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: _amtCtrls[row.item.id],
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
  ];

  String _fmt(double? v) => v == null ? '—' : v.toStringAsFixed(2);
}
