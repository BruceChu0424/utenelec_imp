import '../../../core/formatters/exact_number_text.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'dart:async';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
// 应收应付核销引入面板（收款/付款编辑页"从应收应付引入"用）。
//
// 右滑入大面板（browse 档 75% 屏宽、840 小屏下限，与销售/采购/委外引入统一，外壳 showUtenAdaptivePanel），
// Excel 表形式：
//  搜索框（按单据号过滤）+ UtenEditableGrid 勾选表：单据号 / 日期 / 立帐金额 /
//  已核销 / 余额 / 本次核销额（默认 = 余额）。
// 确认返回所选 [AppliedArAp] 列表，编辑页据此外推明细行（appliedLedgerId +
// amountOriginal/Local）。
//
// 输入：direction（AR=客户应收 / AP=供应商应付）+ partyId（客户/供应商）。
// 拉该往来方未清台账（settled=false）。
import 'package:flutter/material.dart';
import '../../../core/performance/ui_work_budget.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog_chrome.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/inputs/uten_multi_value_cell.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/platform_tables/platform_table_binding.dart';
import '../models/finance_decimal.dart';
import '../models/finance_doc.dart';
import '../models/finance_legacy_balance.dart';
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
    this.requestedSalesOrderId,
    this.clientId,
    this.clientName,
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
  final String? requestedSalesOrderId;
  final String? clientId, clientName;
  final List<String> salesOrderNos;
}

/// 弹出核销引入右滑入大面板。[direction] = 'AR'（收款）/ 'AP'（付款）。
/// [onSwitchToPrepayment] V632：客户尚未发货、没有可核销应收时，空列表处给一键
/// 「改为登记订单预收」——面板先关闭再回调，由收款页切换收款类型并打开订单选择。
Future<List<AppliedArAp>?> showArApPickerDialog(
  BuildContext context,
  WidgetRef ref, {
  required String direction,
  required String? partyId,
  String? lockedCurrencyId,
  VoidCallback? onSwitchToPrepayment,
  bool receiptBatches = false,
  Map<String, String> initialAmounts = const {},
}) {
  return showUtenAdaptivePanel<List<AppliedArAp>>(
    context: context,
    compactHeightFactor: 0.9,
    drawerWidth: 840,
    builder: (_) => _ArApPickerSheet(
      direction: direction,
      partyId: partyId,
      lockedCurrencyId: lockedCurrencyId,
      onSwitchToPrepayment: onSwitchToPrepayment,
      receiptBatches: receiptBatches,
      initialAmounts: Map.of(initialAmounts),
    ),
  );
}

/// 台账勾选行：只持选中态；金额控制器由面板按 ledgerId 持有（过滤重建行时不丢输入）。
class _LedgerRow extends EditableGridRow {
  _LedgerRow(this.item, bool selected)
    : selectedNotifier = ValueNotifier<bool>(selected);
  ArApLedgerItem item;
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
    this.onSwitchToPrepayment,
    this.receiptBatches = false,
    this.initialAmounts = const {},
  });
  final String direction;
  final String? partyId;
  final String? lockedCurrencyId;
  final VoidCallback? onSwitchToPrepayment;
  final bool receiptBatches;
  final Map<String, String> initialAmounts;

  @override
  ConsumerState<_ArApPickerSheet> createState() => _ArApPickerSheetState();
}

class _ArApPickerSheetState extends ConsumerState<_ArApPickerSheet>
    with ScopedPagedReadViewMixin<_ArApPickerSheet> {
  @override
  Future<void> onReadViewResumed() => _load();

  List<ArApLedgerItem> _items = const [];
  final Map<String, ArApLedgerItem> _knownItems = {};
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  int? _activeReadVersion;
  String? _activeReadKeyword;
  bool _readRetired = false;

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

  @override
  void scopedPagedReadOwnerChanged() {
    ++_requestVersion;
    if (!mounted) return;
    setState(() {
      _readRetired = true;
      _items = const [];
      _knownItems.clear();
      _selectedIds.clear();
      _loading = false;
      _error = scopedPagedReadRejection?.message ?? '读取身份已变化，请关闭后重新打开';
    });
    _rebuildGrid();
  }

  Object get _readQuery => [
    widget.receiptBatches,
    if (widget.receiptBatches) ref.read(apiClientProvider),
    ref.read(arApLedgerRepositoryProvider),
    widget.direction,
    widget.partyId,
    widget.lockedCurrencyId,
    _keyword,
  ];

  Future<void> _load() async {
    if (!mounted || _readRetired || _isQueryPending(_keyword)) return;
    final version = ++_requestVersion;
    final keyword = _keyword;
    if (!widget.receiptBatches &&
        (widget.partyId == null || widget.partyId!.isEmpty)) {
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
    _activeReadVersion = version;
    _activeReadKeyword = keyword.trim();
    try {
      final repository = ref.read(arApLedgerRepositoryProvider);
      final direction = widget.direction;
      final partyId = widget.partyId;
      final query = _readQuery;
      final r = await readScopedPage<ArApLedgerItem>(
        1,
        idOf: (row) => row.id,
        query: query,
        currentQuery: () => _readQuery,
        fetchPage: (target) async {
          if (widget.receiptBatches) {
            final json = await ref
                .read(apiClientProvider)
                .get(
                  '/finance/receipts/shipment-sources',
                  query: {
                    'clientId': ?partyId,
                    'page': target,
                    'size': 100,
                    if (keyword.isNotEmpty) 'keyword': keyword,
                  },
                );
            return PagedResult.fromJsonResponsive(
              json,
              ArApLedgerItem.fromJson,
            );
          }
          return repository.openItemsForParty(
            direction: direction,
            partyId: partyId!,
            page: target,
            size: 100,
            keyword: keyword,
          );
        },
      );
      if (!mounted || version != _requestVersion) return;
      if (!widget.receiptBatches) {
        await ref
            .read(financeNameServiceProvider)
            .loadPartyNames(
              clientIds: widget.direction == 'AR'
                  ? [widget.partyId!]
                  : const [],
              supplierIds: widget.direction == 'AP'
                  ? [widget.partyId!]
                  : const [],
            );
      }
      if (!mounted || version != _requestVersion) return;
      final work = UiWorkBudget(
        isCurrent: () => mounted && !_readRetired && version == _requestVersion,
      );
      for (final it in r.items) {
        work.ensureCurrent();
        _knownItems[it.id] = it;
        _amtCtrls.putIfAbsent(
          it.id,
          () => TextEditingController(
            text: widget.receiptBatches
                ? widget.initialAmounts[it.id] ?? ''
                : it.amountBalanceOriginalText ??
                      (it.amountBalanceOriginal == null
                          ? ''
                          : it.amountBalanceOriginal!.toString()),
          ),
        );
        await work.checkpoint();
      }
      setState(() {
        _items = {for (final row in r.items) row.id: row}.values.toList();
        _loading = false;
      });
      _rebuildGrid();
    } on ApiException catch (e) {
      if (isRetiredViewRead(e)) return;
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (retiredReadError) {
      if (isRetiredViewRead(retiredReadError)) return;
      if (!mounted || version != _requestVersion) return;
      setState(() {
        final message = '加载$_ledgerNoun台账失败'; // TODO(l10n): 补 arb
        _error = message;
        _loading = false;
      });
    } finally {
      if (_activeReadVersion == version) {
        _activeReadVersion = null;
        _activeReadKeyword = null;
      }
    }
  }

  bool _isQueryPending(String value) =>
      _activeReadVersion == _requestVersion &&
      _activeReadKeyword == value.trim();

  List<ArApLedgerItem> get _visibleItems => _items;

  void _rebuildGrid() {
    final previous = {for (final row in _grid.rows) row.item.id: row};
    final next = <_LedgerRow>[];
    for (final item in _visibleItems) {
      final row =
          previous.remove(item.id) ??
          _LedgerRow(item, _selectedIds.contains(item.id));
      row.item = item;
      row.selectedNotifier.value = _selectedIds.contains(item.id);
      next.add(row);
    }
    _grid.swapRows(next);
    for (final removed in previous.values) {
      removed.dispose();
    }
  }

  /// 每次键入先同步更新关键词（供空态判断），检索交给 UtenSearchBar
  /// 内置 300ms 防抖回调发起。
  void _onKeywordInput(String v) {
    _keyword = v;
    _requestVersion++;
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
    if (_readRetired) return;
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
      final blank = widget.receiptBatches && amountText.isEmpty;
      if (!blank && (amountUnits == null || amountUnits <= BigInt.zero)) {
        _showSelectionMessage(
          '${it.billNo ?? '该$_ledgerNoun'}：请填写大于 0 的本次$_actionNoun金额',
        );
        return;
      }
      final openUnits = financeAmountUnits(it.amountBalanceOriginalText);
      if (openUnits != null && amountUnits != null && amountUnits > openUnits) {
        _showSelectionMessage(
          '${it.billNo ?? '该$_ledgerNoun'}：本次$_actionNoun不能超过${_isAr ? '未收' : '未付'}金额',
        );
        return;
      }
      out.add(
        AppliedArAp(
          ledgerId: it.id,
          clientId: it.clientId,
          clientName: it.clientName,
          appliedBillNo: it.billNo,
          receiptAmountText: blank ? '' : financeAmountFromUnits(amountUnits!),
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
    if (item.openItemKind == 'LEGACY_UNVERIFIED') {
      final reason = financeLegacyBalanceBlockReason(
        originalBalance:
            item.amountBalanceOriginalText ??
            item.amountBalanceOriginal?.toString(),
        currencyId: item.currencyId,
      );
      return reason == null ? null : '$bill：$reason';
    }
    if (item.openItemKind == 'CUSTOMER_PREPAYMENT' ||
        item.sourceDocType == 'DIRECT_RECEIPT') {
      return '$bill：客户预收必须使用“应用预收”，不能作为普通收款明细';
    }
    if (item.amountBalanceOriginal == null) {
      return '$bill：历史原币余额待财务核验，暂不能引用';
    }
    if (item.currencyId == null || item.currencyId!.isEmpty) {
      return '$bill：币种待财务核验，暂不能引用';
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
    if (_readRetired) {
      final route = ModalRoute.of(context);
      return Scaffold(
        appBar: UtenAppBar(
          title: '读取范围已变化',
          showPagePermissionAction: false,
          leading:
              route?.impliesAppBarDismissal == true && !route!.fullscreenDialog
              ? UtenBackButton(onPressed: () => Navigator.maybePop(context))
              : null,
          actions: [
            UtenCloseButton(onPressed: () => Navigator.of(context).pop()),
          ],
        ),
        body: Center(child: Text(_error ?? '请关闭后重新打开')),
      );
    }

    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    final partyName = _isAr
        ? names.client(widget.partyId)
        : names.supplier(widget.partyId);
    return Stack(
      children: [
        Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _buildHeader(theme, partyName),
                const Divider(height: 1),
                Expanded(child: _buildBody(theme)),
                _buildFooter(theme),
              ],
            ),
          ),
        ),
        if (_loading)
          UtenBusyOverlay(
            title: _isAr ? '加载出货应收' : '加载应付',
            showDoNotLeaveHint: false,
            cancelLabel: '取消选择',
            onCancel: () {
              invalidateScopedPageReads();
              ++_requestVersion;
              Navigator.of(context).pop();
            },
          ),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme, String partyName) {
    final title = widget.receiptBatches
        ? '选出货单'
        : _isAr
        ? '引用应收'
        : '引用应付';
    return UtenPanelHeader(
      title: widget.partyId == null ? title : '$title · $partyName',
      closeButtonKey: const ValueKey('ar-ap-close'),
      onClose: () => Navigator.of(context).pop(),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (!widget.receiptBatches &&
        (widget.partyId == null || widget.partyId!.isEmpty)) {
      return Center(
        child: Text(
          '请先选择${_isAr ? '客户' : '供应商'}', // TODO(l10n): 补 arb
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    // 搜索行恒挂载，loading/错误/空态只切换下方内容区：搜索中焦点与输入法
    // 组合不因状态切换被打断（2026-10-09「拼音打一半丢输入法」根因修复）。
    final searchRow = Padding(
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
            isQueryPending: _isQueryPending,
            onChanged: (_) => _load(),
          );
          final actions = Wrap(
            spacing: UtenSpacing.s4,
            children: [
              TextButton(
                onPressed: () => _setSelectedAllVisible(true),
                child: const Text('全选'),
              ),
              TextButton(onPressed: _invertSelection, child: const Text('反选')),
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
    );
    // 行区空态占位（2026-10-09 用户口径「无结果/加载/错误表格骨架也要在」）：
    // 网格（含表头）恒挂载，loading/错误/初始引导都渲染在行区，页面不整块切换。
    Widget? emptyPlaceholder;
    if (_loading) {
      emptyPlaceholder = const Padding(
        padding: EdgeInsets.all(UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    } else if (_error != null) {
      emptyPlaceholder = Padding(
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
      );
    } else if (_items.isEmpty && _keyword.trim().isEmpty) {
      // 2026-09-14：应收在仓库「确认出库」后才立账——客户没走过完整出货时
      // 选择器必然为空。明说生成时机，避免误以为丢数据（用户实测困惑点）。
      final switchToPrepayment = _isAr ? widget.onSwitchToPrepayment : null;
      emptyPlaceholder = Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isAr
                  ? '暂无未清$_ledgerNoun。应收在仓库确认出货单出库后自动生成；客户尚未发货时这里没有内容，收到的是订单定金/预付款请改用「登记订单预收」。'
                  : '暂无未清$_ledgerNoun', // TODO(l10n): 补 arb
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            if (switchToPrepayment != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              // V632：用户实测「明明下了销售单却找不到」——订单没出货就没有应收，
              // 这里直接切到登记订单预收并打开订单选择，不用回头找收款类型下拉。
              FilledButton.tonalIcon(
                key: const ValueKey('ar-picker-switch-to-prepayment'),
                onPressed: () {
                  Navigator.of(context).pop();
                  switchToPrepayment();
                },
                icon: const Icon(Icons.savings_outlined),
                label: const Text('改为登记订单预收并选择订单'),
              ),
            ],
          ],
        ),
      );
    }
    final content = SingleChildScrollView(
      child: UtenEditableGrid<_LedgerRow>(
        headerFilterScopeDescription: '按当前往来单位的全部未结台账筛选；币种及可核销金额由原台账决定',
        tableKey:
            'features.finance.widgets.ar_ap_picker_dialog.ArApPickerSheetState._buildBody.1',
        platformBinding: PlatformTableBinding<_LedgerRow>(
          tableKey:
              'features.finance.widgets.ar_ap_picker_dialog.ArApPickerSheetState._buildBody.1',
          scope: 'view_ar_ap_ledger',
          recordIdOf: (_) => null,
          columnAliases: const {
            'amount': 'amountOriginal',
            'settled': 'amountReceivedOriginal',
            'writtenOff': 'amountWriteOffOriginal',
            'prepaymentApplied': 'prepaymentAppliedOriginal',
            'balance': 'amountBalanceOriginal',
            'thisAmt': 'appliedAmountOriginal',
          },
        ),
        controller: _grid,
        columns: _columns(),
        showAddRow: false,
        showRowDelete: false,
        createBlankRow: () =>
            _LedgerRow(const ArApLedgerItem(id: ''), false), // 不会被调用
        emptyMessage: '没有匹配的台账行', // TODO(l10n): 补 arb
        emptyPlaceholder: emptyPlaceholder,
      ),
    );
    return Column(
      children: [
        searchRow,
        Expanded(child: content),
      ],
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final n = _selectedIds.length;
    final currencyId = _selectedCurrencyId;
    final summary = Wrap(
      key: const ValueKey('ar-ap-selection-summary'),
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s4,
      children: [
        Text(
          '已选 $n 行',
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
      ],
    );
    final actions = UtenDialogActions(
      padding: EdgeInsets.zero,
      showDivider: false,
      alignment: MainAxisAlignment.end,
      overflowAlignment: OverflowBarAlignment.end,
      children: [
        TextButton(
          key: const ValueKey('ar-ap-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          key: const ValueKey('ar-ap-confirm'),
          onPressed: _readRetired || n == 0 ? null : _confirm,
          icon: const Icon(Icons.check_rounded, size: 18),
          label: Text(
            widget.receiptBatches
                ? '引用出货单'
                : _isAr
                ? '引用应收'
                : '引用应付',
          ),
        ),
      ],
    );
    return SizedBox(
      key: const ValueKey('ar-ap-footer'),
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 600) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    summary,
                    const SizedBox(height: UtenSpacing.s8),
                    actions,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: UtenSpacing.s12),
                  SizedBox(width: 280, child: actions),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 表头筛选桶标签：空白与「—」不建桶（返回 null → 计入「未填」）。
  String? _bucketOrNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == '—') return null;
    return trimmed;
  }

  // 2026-09-11 全站表头快速筛选补齐：来源类型与币别给表头快速筛选
  // （视图级过滤，不动勾选与已填本次金额）。单号/金额列不做筛选。
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
              // 2026-10-06 表格控件统一口径：Checkbox 默认 40 点击区会撑高
              // 编辑行（行高标准=39 输入格），收紧点击区到控件本身。
              child: Theme(
                data: Theme.of(context).copyWith(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Checkbox(
                  key: ValueKey('ar-ap-select-${row.item.id}'),
                  value: sel,
                  onChanged: _canSelect(row.item)
                      ? (v) => _toggleRow(row, v ?? false)
                      : null,
                ),
              ),
            ),
          );
        },
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'billNo',
      label: widget.receiptBatches ? '出货单/原来源' : '$_ledgerNoun单号',
      width: 160,
      cellBuilder: (context, row) => Text(
        (widget.receiptBatches ? row.item.sourceDocNo : null) ??
            row.item.billNo ??
            '—',
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
      headerInfo: _isAr ? '订单号仅辅助归属；本次收款只核销明确勾选的出货应收，不跨批次自动分摊。' : null,
      width: 230,
      // textOf（复制/编辑态）保留全量；屏幕格走多值截断+弹窗口径（2026-10-29）。
      textOf: (row) => row.item.salesOrderNos.isEmpty
          ? '—'
          : row.item.salesOrderNos.join('、'),
      cellBuilder: (context, row) => UtenMultiValueCell(
        values: row.item.salesOrderNos,
        title: _isAr ? '销售订单号' : '关联单号',
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'source',
      label: '来源类型 / 单号',
      width: 200,
      // 桶按「来源类型」聚合（单号逐行唯一，带上就没有收敛意义）。
      filterValueOf: (row) =>
          _bucketOrNull(financeArApSourceTypeLabel(row.item.sourceDocType)),
      textOf: (row) =>
          '${financeArApSourceTypeLabel(row.item.sourceDocType)}'
          '${row.item.sourceDocNo?.trim().isNotEmpty == true ? ' · ${row.item.sourceDocNo}' : ''}',
      cellBuilder: (context, row) => Text(
        '${financeArApSourceTypeLabel(row.item.sourceDocType)}'
        '${row.item.sourceDocNo?.trim().isNotEmpty == true ? ' · ${row.item.sourceDocNo}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'currency',
      label: '币别',
      width: 80,
      filterValueOf: (row) => _bucketOrNull(
        financeCurrencyDisplayLabel(
          name: row.item.currencyName,
          code: row.item.currencyCode,
        ),
      ),
      cellBuilder: (context, row) => Text(
        financeCurrencyDisplayLabel(
              name: row.item.currencyName,
              code: row.item.currencyCode,
            ) ??
            '—',
      ),
    ),
    // 金额「数值 币种」后缀（2026-10-10 口径）：随行 currencyName/Code；
    // 行缺币种或金额非数字（—/***)时不拼单位。
    EditableGridColumn<_LedgerRow>(
      key: 'amount',
      label: widget.receiptBatches
          ? '货款'
          : _isAr
          ? '应收总额'
          : '应付金额',
      headerInfo: widget.receiptBatches
          ? '本次明确选择的出货批次已立账原币货款；不包含同订单其他出货批次。'
          : null,
      width: 140,
      numeric: true,
      columnSearchEnabled: false,
      exactValueOf: (row) =>
          row.item.amountOriginalText ?? row.item.amountOriginalLocalText,
      cellBuilder: (context, row) => Text(
        _moneyWithRowCurrency(
          row,
          row.item.amountOriginalText ??
              row.item.amountOriginalLocalText ??
              '—',
        ),
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'settled',
      label: widget.receiptBatches
          ? '已收'
          : _isAr
          ? '累计已收'
          : '已付金额',
      headerInfo: widget.receiptBatches
          ? '本批核准现金收款加已经实际抵扣到本批的定金；未抵定金、未来约定及退减不冒充收款。'
          : null,
      width: 140,
      numeric: true,
      columnSearchEnabled: false,
      exactValueOf: (row) => widget.receiptBatches
          ? financeExactSumTexts([
              row.item.amountReceivedOriginalText,
              row.item.prepaymentAppliedOriginal ?? '0',
            ])
          : row.item.amountReceivedOriginalText ??
                (_isAr ? null : row.item.amountSettledText),
      cellBuilder: (context, row) => Text(
        _moneyWithRowCurrency(
          row,
          widget.receiptBatches
              ? financeExactSumTexts([
                      row.item.amountReceivedOriginalText,
                      row.item.prepaymentAppliedOriginal ?? '0',
                    ]) ??
                    '—'
              : _fmt(
                  _isAr
                      ? row.item.amountReceivedOriginal
                      : row.item.amountReceivedOriginal ??
                            row.item.amountSettled,
                ),
        ),
      ),
    ),
    if (_isAr)
      EditableGridColumn<_LedgerRow>(
        key: 'writtenOff',
        label: '累计冲销',
        width: 140,
        numeric: true,
        columnSearchEnabled: false,
        exactValueOf: (row) => row.item.amountWriteOffOriginalText,
        cellBuilder: (context, row) => Text(
          _moneyWithRowCurrency(row, _fmt(row.item.amountWriteOffOriginal)),
        ),
      ),
    if (_isAr)
      EditableGridColumn<_LedgerRow>(
        key: 'prepaymentApplied',
        label: '预收已抵',
        width: 140,
        numeric: true,
        columnSearchEnabled: false,
        exactValueOf: (row) => row.item.prepaymentAppliedOriginal,
        cellBuilder: (context, row) => Text(
          _moneyWithRowCurrency(
            row,
            row.item.prepaymentAppliedOriginal ?? '0.00',
          ),
        ),
      ),
    EditableGridColumn<_LedgerRow>(
      key: 'balance',
      label: widget.receiptBatches
          ? '还欠'
          : _isAr
          ? '本次可收'
          : '未付金额',
      headerInfo: widget.receiptBatches
          ? '本批正式应收当前原币未收余额；只收部分时余额保留，不跨其他出货批次自动扣款。'
          : null,
      width: 140,
      numeric: true,
      columnSearchEnabled: false,
      exactValueOf: (row) => row.item.amountBalanceOriginalText,
      cellBuilder: (context, row) => Text(
        row.item.amountBalanceOriginal == null
            ? '待财务核验'
            : _moneyWithRowCurrency(row, _fmt(row.item.amountBalanceOriginal)),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color:
              widget.receiptBatches &&
                  (financeAmountUnits(
                            row.item.amountBalanceOriginalText ?? '',
                          ) ??
                          BigInt.zero) >
                      BigInt.zero
              ? Theme.of(context).colorScheme.error
              : null,
        ),
      ),
    ),
    EditableGridColumn<_LedgerRow>(
      key: 'thisAmt',
      label: '本次$_actionNoun金额',
      headerInfo: widget.receiptBatches
          ? '只填这次实际收到并分给本批的钱，不把还欠金额当作已到账。留空可先引用，主表仍须明确填写后才能保存。'
          : null,
      width: 160,
      numeric: true,
      columnSearchEnabled: false,
      exactValueOf: (row) => _amtCtrls[row.item.id]?.text,
      exactListenableOf: (row) => _amtCtrls[row.item.id],
      cellBuilder: (context, row) => TextField(
        key: ValueKey('ar-ap-amount-${row.item.id}'),
        controller: _amtCtrls[row.item.id],
        enabled: _canSelect(row.item),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        // 输入格同样带币种后缀（与「数量 单位」输入格对称）；行缺币种不显示。
        decoration: UtenInputDecoration(
          InputDecoration(
            isDense: true,
            labelText: '本次$_actionNoun金额',
            suffixText: financeCurrencyDisplayLabel(
              name: row.item.currencyName,
              code: row.item.currencyCode,
            ),
          ),
        ),
      ),
    ),
    if (widget.receiptBatches)
      EditableGridColumn<_LedgerRow>(
        key: 'receiptClient',
        label: '客户',
        width: 180,
        textOf: (row) => row.item.clientName ?? '—',
        cellBuilder: (_, row) => Text(row.item.clientName ?? '—'),
      ),
  ];

  /// 金额文本 + 行币种单位（行缺币种或金额非数字时原文返回）。
  String _moneyWithRowCurrency(_LedgerRow row, String amount) =>
      financeMoneyWithUnitSuffix(
        amount,
        currencyName: row.item.currencyName,
        currencyCode: row.item.currencyCode,
      );

  String _fmt(double? v) =>
      v == null ? '—' : v.toExactString(minimumFractionDigits: 2);

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
