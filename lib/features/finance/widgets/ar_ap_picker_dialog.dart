// 应收应付核销引入面板（收款/付款编辑页"从应收应付引入"用）。
//
// 右滑入大面板（840，与销售/采购/委外引入统一，外壳 showUtenAdaptivePanel），
// Excel 表形式：
//  搜索框（按单据号过滤）+ UtenEditableGrid 勾选表：单据号 / 日期 / 立帐金额 /
//  已核销 / 余额 / 本次核销额（默认 = 余额）。
// 确认返回所选 [AppliedArAp] 列表，编辑页据此外推明细行（appliedLedgerId +
// amountOriginal/Local）。
//
// 输入：direction（AR=客户应收 / AP=供应商应付）+ partyId（客户/供应商）。
// 拉该往来方未清台账（settled=false）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/currency_display.dart';
import '../models/finance_decimal.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';

/// 核销回填项：台账行 id + 本次核销额（本币）+ 原币额（默认同本币）+ 单据号（展示/审计）。
class AppliedArAp {
  const AppliedArAp({
    required this.ledgerId,
    required this.appliedBillNo,
    required this.receiptAmountText,
    this.sourceDocType,
    this.sourceDocNo,
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.receivableOriginal,
    this.receivableOriginalText,
    this.receivedOriginal,
    this.receivedOriginalText,
    this.writtenOffOriginal,
    this.writtenOffOriginalText,
    this.balanceOriginal,
    this.balanceOriginalText,
    this.prepaymentAppliedOriginal,
    this.salesOrderIds = const [],
    this.authoritativeSalesOrderId,
    this.salesOrderNos = const [],
  });
  final String ledgerId;
  final String? appliedBillNo;
  final String receiptAmountText;
  final String? sourceDocType;
  final String? sourceDocNo;
  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final double? receivableOriginal;
  final String? receivableOriginalText;
  final double? receivedOriginal;
  final String? receivedOriginalText;
  final double? writtenOffOriginal;
  final String? writtenOffOriginalText;
  final double? balanceOriginal;
  final String? balanceOriginalText;
  final String? prepaymentAppliedOriginal;
  final List<String> salesOrderIds;
  final String? authoritativeSalesOrderId;
  final List<String> salesOrderNos;
}

/// 弹出核销引入右滑入大面板。[direction] = 'AR'（收款）/ 'AP'（付款）。
Future<List<AppliedArAp>?> showArApPickerDialog(
  BuildContext context,
  WidgetRef ref, {
  required String direction,
  required String? partyId,
  String? lockedCurrencyId,
}) {
  return showUtenAdaptivePanel<List<AppliedArAp>>(
    context: context,
    compactHeightFactor: 0.9,
    drawerWidth: 840,
    builder: (_) => _ArApPickerSheet(
      direction: direction,
      partyId: partyId,
      lockedCurrencyId: lockedCurrencyId,
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
  const _ArApPickerSheet({
    required this.direction,
    required this.partyId,
    required this.lockedCurrencyId,
  });
  final String direction;
  final String? partyId;
  final String? lockedCurrencyId;

  @override
  ConsumerState<_ArApPickerSheet> createState() => _ArApPickerSheetState();
}

class _ArApPickerSheetState extends ConsumerState<_ArApPickerSheet> {
  List<ArApLedgerItem> _items = const [];
  final Map<String, ArApLedgerItem> _knownItems = {};
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  int _page = 1;
  int _totalPages = 1;

  final _keywordCtl = TextEditingController();
  String _keyword = '';

  /// 选中态 / 金额输入按台账行 id 持有：搜索过滤重建表格行时状态不丢。
  final Set<String> _selectedIds = {};
  final Map<String, TextEditingController> _amtCtrls = {};

  late final UtenEditableGridController<_LedgerRow> _grid;

  bool get _isAr => widget.direction == 'AR';
  String get _ledgerNoun => _isAr ? '应收' : '应付';
  String get _actionNoun => _isAr ? '收款' : '付款';

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

  Future<void> _load({bool reset = true}) async {
    if (widget.partyId == null || widget.partyId!.isEmpty) {
      setState(() {
        _items = const [];
        _error = null;
      });
      return;
    }
    setState(() {
      if (reset) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });
    try {
      final requestedPage = reset ? 1 : _page + 1;
      final r = await ref
          .read(arApLedgerRepositoryProvider)
          .openItemsForParty(
            direction: widget.direction,
            partyId: widget.partyId!,
            page: requestedPage,
            keyword: _keyword,
          );
      if (!mounted) return;
      for (final it in r.items) {
        _knownItems[it.id] = it;
        _amtCtrls.putIfAbsent(
          it.id,
          () => TextEditingController(
            text:
                it.amountBalanceOriginalText ??
                (it.amountBalanceOriginal == null
                    ? ''
                    : it.amountBalanceOriginal!.toString()),
          ),
        );
      }
      setState(() {
        _items = reset ? r.items : [..._items, ...r.items];
        _page = r.page;
        _totalPages = r.totalPages;
        _loading = false;
        _loadingMore = false;
      });
      _rebuildGrid();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载$_ledgerNoun台账失败'; // TODO(l10n): 补 arb
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  List<ArApLedgerItem> get _visibleItems => _items;

  void _rebuildGrid() {
    _grid.replaceAll(
      _visibleItems.map((it) => _LedgerRow(it, _selectedIds.contains(it.id))),
    );
  }

  /// 每次键入先同步更新关键词（供空态判断），检索交给 UtenSearchBar
  /// 内置 300ms 防抖回调发起。
  void _onKeywordInput(String v) {
    _keyword = v;
  }

  void _toggleRow(_LedgerRow row, bool v) {
    final reason = v ? _selectionBlockReason(row.item) : null;
    if (reason != null) {
      row.selectedNotifier.value = false;
      _showSelectionMessage(reason);
      return;
    }
    row.selectedNotifier.value = v;
    if (v) {
      _selectedIds.add(row.item.id);
    } else {
      _selectedIds.remove(row.item.id);
    }
    setState(() {});
  }

  void _setSelectedAllVisible(bool v) {
    var currencyId = _selectedCurrencyId;
    var skipped = false;
    for (final r in _grid.rows) {
      final baseReason = _baseBlockReason(r.item);
      final rowCurrencyId = r.item.currencyId;
      if (v && baseReason == null && currencyId == null) {
        currencyId = rowCurrencyId;
      }
      final next =
          v &&
          baseReason == null &&
          rowCurrencyId != null &&
          rowCurrencyId == currencyId;
      if (v && !next) skipped = true;
      r.selectedNotifier.value = next;
      if (next) {
        _selectedIds.add(r.item.id);
      } else {
        _selectedIds.remove(r.item.id);
      }
    }
    setState(() {});
    if (v && skipped) {
      _showSelectionMessage('已仅选择币种一致且原币余额完整的$_ledgerNoun明细');
    }
  }

  void _invertSelection() {
    var currencyId = _selectedCurrencyId;
    var skipped = false;
    for (final r in _grid.rows) {
      final baseReason = _baseBlockReason(r.item);
      final rowCurrencyId = r.item.currencyId;
      if (!r.selectedNotifier.value &&
          baseReason == null &&
          currencyId == null) {
        currencyId = rowCurrencyId;
      }
      final v =
          !r.selectedNotifier.value &&
          baseReason == null &&
          rowCurrencyId != null &&
          rowCurrencyId == currencyId;
      if (!r.selectedNotifier.value && !v) skipped = true;
      r.selectedNotifier.value = v;
      if (v) {
        _selectedIds.add(r.item.id);
      } else {
        _selectedIds.remove(r.item.id);
      }
    }
    setState(() {});
    if (skipped) {
      _showSelectionMessage('反选已跳过币种不一致或历史金额不完整的明细');
    }
  }

  void _confirm() {
    final out = <AppliedArAp>[];
    var currencyId = widget.lockedCurrencyId;
    for (final id in _selectedIds) {
      final it = _knownItems[id];
      if (it == null) continue;
      final reason = _baseBlockReason(it);
      if (reason != null) {
        _showSelectionMessage(reason);
        return;
      }
      if (currencyId != null && it.currencyId != currencyId) {
        _showSelectionMessage('${it.billNo ?? '该$_ledgerNoun'}：币种与本次已选明细不一致');
        return;
      }
      currencyId ??= it.currencyId;
      final amountText = _amtCtrls[it.id]?.text.trim() ?? '';
      final amountUnits = financeAmountUnits(amountText);
      if (amountUnits == null || amountUnits <= BigInt.zero) {
        _showSelectionMessage(
          '${it.billNo ?? '该$_ledgerNoun'}：请填写大于 0 的本次$_actionNoun金额',
        );
        return;
      }
      final openUnits = financeAmountUnits(it.amountBalanceOriginalText);
      if (openUnits != null && amountUnits > openUnits) {
        _showSelectionMessage(
          '${it.billNo ?? '该$_ledgerNoun'}：本次$_actionNoun不能超过${_isAr ? '未收' : '未付'}金额',
        );
        return;
      }
      out.add(
        AppliedArAp(
          ledgerId: it.id,
          appliedBillNo: it.billNo,
          receiptAmountText: financeAmountFromUnits(amountUnits),
          sourceDocType: it.sourceDocType,
          sourceDocNo: it.sourceDocNo,
          currencyId: it.currencyId,
          currencyCode: it.currencyCode,
          currencyName: it.currencyName,
          receivableOriginal: it.amountOriginal,
          receivableOriginalText: it.amountOriginalText,
          receivedOriginal: it.amountReceivedOriginal,
          receivedOriginalText: it.amountReceivedOriginalText,
          writtenOffOriginal: it.amountWriteOffOriginal,
          writtenOffOriginalText: it.amountWriteOffOriginalText,
          balanceOriginal: it.amountBalanceOriginal,
          balanceOriginalText: it.amountBalanceOriginalText,
          prepaymentAppliedOriginal: it.prepaymentAppliedOriginal,
          salesOrderIds: it.salesOrderIds,
          authoritativeSalesOrderId: it.authoritativeSalesOrderId,
          salesOrderNos: it.salesOrderNos,
        ),
      );
    }
    Navigator.of(context).pop(out);
  }

  String? get _selectedCurrencyId {
    final locked = widget.lockedCurrencyId;
    if (locked != null && locked.isNotEmpty) return locked;
    for (final id in _selectedIds) {
      final currencyId = _knownItems[id]?.currencyId;
      if (currencyId != null && currencyId.isNotEmpty) return currencyId;
    }
    return null;
  }

  String? _baseBlockReason(ArApLedgerItem item) {
    final bill = item.billNo ?? '该$_ledgerNoun';
    if (item.openItemKind == 'CUSTOMER_PREPAYMENT' ||
        item.sourceDocType == 'DIRECT_RECEIPT') {
      return '$bill：客户预收必须使用“应用预收”，不能作为普通收款明细';
    }
    if (item.amountBalanceOriginal == null) {
      return '$bill：历史原币余额待财务核验，暂不能引用';
    }
    if (item.currencyId == null || item.currencyId!.isEmpty) {
      return '$bill：币别待财务核验，暂不能引用';
    }
    return null;
  }

  String? _selectionBlockReason(ArApLedgerItem item) {
    final baseReason = _baseBlockReason(item);
    if (baseReason != null) return baseReason;
    final selectedCurrencyId = _selectedCurrencyId;
    if (selectedCurrencyId != null && item.currencyId != selectedCurrencyId) {
      return '${item.billNo ?? '该$_ledgerNoun'}：币种与本次已选明细不一致';
    }
    return null;
  }

  bool _canSelect(ArApLedgerItem item) =>
      _selectedIds.contains(item.id) || _selectionBlockReason(item) == null;

  void _showSelectionMessage(String message) {
    context.appWarning(message);
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
    final title = _isAr ? '引用应收' : '引用应付';
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
            key: const ValueKey('ar-ap-close'),
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
    if (_items.isEmpty && _keyword.trim().isEmpty) {
      return Center(
        child: Text(
          '暂无未清$_ledgerNoun', // TODO(l10n): 补 arb
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final search = UtenSearchBar(
                controller: _keywordCtl,
                hint: _isAr ? '搜索应收单号、发运单号、销售订单号或客户' : '搜索应付单号、关联单号或供应商',
                onInputChanged: _onKeywordInput,
                onChanged: (_) => _load(),
              );
              final actions = Wrap(
                spacing: UtenSpacing.s4,
                children: [
                  TextButton(
                    onPressed: () => _setSelectedAllVisible(true),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: _invertSelection,
                    child: const Text('反选'),
                  ),
                  TextButton(
                    onPressed: () => _setSelectedAllVisible(false),
                    child: const Text('取消全选'),
                  ),
                ],
              );
              if (constraints.maxWidth < 600) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    search,
                    const SizedBox(height: UtenSpacing.s4),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: UtenSpacing.s12),
                  actions,
                ],
              );
            },
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
        if (_page < _totalPages)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: TextButton.icon(
              onPressed: _loadingMore ? null : () => _load(reset: false),
              icon: _loadingMore
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more_rounded),
              label: Text(_loadingMore ? '加载中' : '加载更多'),
            ),
          ),
        _buildFooter(theme),
      ],
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final n = _selectedIds.length;
    final currencyId = _selectedCurrencyId;
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          children: [
            Text(
              '已选 $n 行', // TODO(l10n): 补 arb
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (currencyId != null)
              Text(
                '本次币种：${_currencyLabel(currencyId)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            FilledButton.icon(
              key: const ValueKey('ar-ap-confirm'),
              onPressed: n == 0 ? null : _confirm,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(_isAr ? '引用应收' : '引用应付'), // TODO(l10n): 补 arb
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
        builder: (_, sel, _) {
          final reason = sel ? null : _selectionBlockReason(row.item);
          return Tooltip(
            message: reason ?? '选择${row.item.billNo ?? _ledgerNoun}',
            child: Semantics(
              label: reason ?? '选择${row.item.billNo ?? _ledgerNoun}',
              enabled: reason == null,
              child: Checkbox(
                key: ValueKey('ar-ap-select-${row.item.id}'),
                value: sel,
                onChanged: _canSelect(row.item)
                    ? (v) => _toggleRow(row, v ?? false)
                    : null,
              ),
            ),
          );
        },
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'billNo',
      label: '$_ledgerNoun单号',
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
      cellBuilder: (context, row) => Text(_safeDate(row.item.billDate)),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'salesOrders',
      label: _isAr ? '销售订单号' : '关联单号',
      width: 230,
      cellBuilder: (context, row) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row.item.salesOrderNos.isEmpty
                ? '—'
                : row.item.salesOrderNos.join('、'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (_isAr && row.item.salesOrderIds.length > 1)
            Text(
              '多订单应收：审核后按不可变来源顺序分配并留痕',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'source',
      label: '来源类型 / 单号',
      width: 200,
      cellBuilder: (context, row) => Text(
        '${financeArApSourceTypeLabel(row.item.sourceDocType)}'
        '${row.item.sourceDocNo?.trim().isNotEmpty == true ? ' · ${row.item.sourceDocNo}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'currency',
      label: '币别',
      width: 80,
      cellBuilder: (context, row) => Text(
        financeCurrencyDisplayLabel(
              name: row.item.currencyName,
              code: row.item.currencyCode,
            ) ??
            '—',
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'amount',
      label: _isAr ? '应收总额' : '应付金额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) =>
          Text(_fmt(row.item.amountOriginal ?? row.item.amountOriginalLocal)),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'settled',
      label: _isAr ? '累计已收' : '已付金额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(
        _fmt(
          _isAr
              ? row.item.amountReceivedOriginal
              : row.item.amountReceivedOriginal ?? row.item.amountSettled,
        ),
      ),
    ),
    if (_isAr)
      EditableGridColumn<_LedgerRow>(
        key: 'writtenOff',
        label: '累计冲销',
        width: 110,
        numeric: true,
        cellBuilder: (context, row) =>
            Text(_fmt(row.item.amountWriteOffOriginal)),
      ),
    if (_isAr)
      EditableGridColumn<_LedgerRow>(
        key: 'prepaymentApplied',
        label: '预收已抵',
        width: 110,
        numeric: true,
        cellBuilder: (context, row) =>
            Text(row.item.prepaymentAppliedOriginal ?? '0.00'),
      ),
    EditableGridColumn<_LedgerRow>(
      key: 'balance',
      label: _isAr ? '本次可收' : '未付金额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => Text(
        row.item.amountBalanceOriginal == null
            ? '待财务核验'
            : _fmt(row.item.amountBalanceOriginal),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'thisAmt',
      label: '本次$_actionNoun金额',
      width: 130,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        key: ValueKey('ar-ap-amount-${row.item.id}'),
        controller: _amtCtrls[row.item.id],
        enabled: _canSelect(row.item),
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
  ];

  String _fmt(double? v) => v == null ? '—' : v.toStringAsFixed(2);

  String _currencyLabel(String currencyId) {
    for (final item in _knownItems.values) {
      if (item.currencyId == currencyId) {
        final label = financeCurrencyDisplayLabel(
          name: item.currencyName,
          code: item.currencyCode,
        );
        if (label != null) return label;
      }
    }
    final resolved = ref.read(financeNameServiceProvider).currency(currencyId);
    return financeCurrencyDisplayLabel(name: resolved) ?? '原币';
  }

  String _safeDate(String? value) {
    if (value == null || value.isEmpty) return '—';
    return value.length <= 10 ? value : value.substring(0, 10);
  }
}
