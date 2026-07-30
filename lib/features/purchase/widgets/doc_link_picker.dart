// 上游单据明细引入面板（采购编辑页"从上游引入"用）。
//
// 重做（2026-07-29）：从居中 Dialog + 卡片/ListTile 换成右滑入大面板（840，
// 与销售 showSalesDocLinkPicker 统一），两步各自 Excel 表：
//  Step1 上游单据：MasterDataTableView（搜索 + 供应商筛选 + 表头排序 +
//        「表头设置」列显隐 + 分页，状态固定已审）。
//  Step2 该单据明细：UtenEditableGrid（showAddRow:false）勾选 + 本次数量。
// 确认返回所选 [LinkedItem] 列表，编辑页据此外推明细行并
// 回填 requestItemId/orderItemId/receiptItemId。
//
// 上游类型由 cfg 决定：linkToReceiptItem→收货（退货优先收货），linkToOrderItem→订货，
// linkToRequestItem→申请。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';

/// 上游引入回填项：货品 + 本次数量 + 单价 + 上游明细 id（用于回写 *ItemId）+
/// 可选颜色/单位。
class LinkedItem {
  const LinkedItem({
    required this.goodsId,
    required this.qty,
    this.price,
    this.upstreamItemId,
    this.colorId,
    this.unitId,
  });

  final String goodsId;
  final double qty;
  final double? price;
  final String? upstreamItemId;
  final String? colorId;
  final String? unitId;
}

/// 从 cfg 推断上游单据类型。退货同时可链收货/订货时优先收货。
PurchaseDocType _upstreamType(PurchaseDocConfig cfg) {
  if (cfg.linkToReceiptItem) return PurchaseDocType.receipt;
  if (cfg.linkToOrderItem) return PurchaseDocType.order;
  return PurchaseDocType.request;
}

/// 弹出"从上游引入"右滑入大面板；返回所选明细（null 表示用户取消）。
Future<List<LinkedItem>?> showDocLinkPicker(
  BuildContext context,
  WidgetRef ref,
  PurchaseDocConfig cfg,
) {
  final sheet = _UpstreamImportSheet(cfg: cfg, upstreamType: _upstreamType(cfg));
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<List<LinkedItem>>(
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
  return showGeneralDialog<List<LinkedItem>>(
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

/// 上游明细勾选行：持上游明细引用 + 选中态 + 本次数量控制器。
class _UpstreamItemRow extends EditableGridRow {
  _UpstreamItemRow(this.item);
  final PurchaseDocItem item;
  final ValueNotifier<bool> selectedNotifier = ValueNotifier<bool>(false);
  final TextEditingController qty = TextEditingController();
  bool get selected => selectedNotifier.value;

  @override
  void dispose() {
    selectedNotifier.dispose();
    qty.dispose();
    super.dispose();
  }
}

class _UpstreamImportSheet extends ConsumerStatefulWidget {
  const _UpstreamImportSheet({required this.cfg, required this.upstreamType});

  final PurchaseDocConfig cfg;
  final PurchaseDocType upstreamType;

  @override
  ConsumerState<_UpstreamImportSheet> createState() =>
      _UpstreamImportSheetState();
}

class _UpstreamImportSheetState extends ConsumerState<_UpstreamImportSheet> {
  PurchaseDocType get _upType => widget.upstreamType;

  // Step1 · 上游单据
  PagedResult<PurchaseDocListItem>? _docPage;
  bool _loadingDocs = false;
  String? _docsError;
  final _keywordCtl = TextEditingController();
  String _keyword = '';
  String? _supplierId;
  String? _sortKey;
  bool _sortAsc = true;

  // Step2 · 明细
  PurchaseDocDetail? _upDetail;
  late final UtenEditableGridController<_UpstreamItemRow> _grid;
  bool _loadingItems = false;

  @override
  void initState() {
    super.initState();
    _grid = UtenEditableGridController<_UpstreamItemRow>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _loadDocs(1);
    });
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    _grid.dispose();
    super.dispose();
  }

  // ---- Step1：上游单据 ---------------------------------------------------

  Future<void> _loadDocs(int page) async {
    setState(() {
      _loadingDocs = true;
      _docsError = null;
    });
    try {
      final r = await ref
          .read(purchaseRepositoryProvider(_upType))
          .list(
            page: page,
            // 业务约束：只引入已审单（草稿/红冲不可引入）。
            filter: PurchaseDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              supplierId: _supplierId,
              status: kPurchaseStatusApproved,
            ),
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted) return;
      setState(() {
        _docPage = r;
        _loadingDocs = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _docsError = e.message;
        _loadingDocs = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _docsError = '加载上游单据失败'; // TODO(l10n): 补 arb
        _loadingDocs = false;
      });
    }
  }

  void _onKeywordChanged(String v) {
    _keyword = v;
    _loadDocs(1);
  }

  void _onSortChange(String? col, bool asc) {
    setState(() {
      _sortKey = col;
      _sortAsc = asc;
    });
    _loadDocs(1);
  }

  // ---- Step2：选中单据的明细 --------------------------------------------

  Future<void> _pickDoc(PurchaseDocListItem d) async {
    setState(() {
      _loadingItems = true;
      _upDetail = null;
    });
    try {
      final detail = await ref
          .read(purchaseRepositoryProvider(_upType))
          .detail(d.id);
      final goodsIds = detail.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      final rows = detail.items.map((it) {
        final row = _UpstreamItemRow(it);
        row.qty.text = _defaultQty(it).toString();
        return row;
      }).toList();
      _grid.replaceAll(rows);
      setState(() {
        _upDetail = detail;
        _loadingItems = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingItems = false);
      // 静默降级（与 v1 一致）
    }
  }

  /// 默认本次数量：收货引入订货 → max(0, qty - receivedQty)；其它 → qty。
  double _defaultQty(PurchaseDocItem it) {
    if (_upType == PurchaseDocType.order &&
        widget.cfg.type == PurchaseDocType.receipt) {
      return math.max(0.0, (it.qty ?? 0) - (it.receivedQty ?? 0));
    }
    return it.qty ?? 0;
  }

  void _setSelectedAll(bool v) {
    for (final r in _grid.rows) {
      r.selectedNotifier.value = v;
    }
    setState(() {});
  }

  void _invertSelection() {
    for (final r in _grid.rows) {
      r.selectedNotifier.value = !r.selectedNotifier.value;
    }
    setState(() {});
  }

  void _toggleRow(_UpstreamItemRow row, bool v) {
    row.selectedNotifier.value = v;
    setState(() {});
  }

  int get _selectedCount => _grid.rows.where((r) => r.selected).length;

  void _submit() {
    final out = <LinkedItem>[];
    for (final row in _grid.rows) {
      if (!row.selected) continue;
      final it = row.item;
      if (it.goodsId == null) continue;
      final q = double.tryParse(row.qty.text) ?? 0;
      if (q <= 0) continue;
      out.add(
        LinkedItem(
          goodsId: it.goodsId!,
          qty: q,
          price: it.price,
          upstreamItemId: it.id,
          colorId: it.colorId,
          unitId: it.unitId,
        ),
      );
    }
    Navigator.of(context).pop(out);
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final inStep2 = _upDetail != null;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(theme, inStep2, names),
            const Divider(height: 1),
            Expanded(
              child: inStep2
                  ? (_loadingItems
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : _buildStep2(theme, names))
                  : _buildStep1(theme, names),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    ThemeData theme,
    bool inStep2,
    MasterNameService names,
  ) {
    final title = inStep2
        ? '选择明细（${names.supplier(_upDetail!.supplierId)}）'
        : '从${_upTypeLabel()}引入';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s8,
        UtenSpacing.s12,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      child: Row(
        children: [
          if (inStep2)
            TextButton.icon(
              onPressed: () => setState(() => _upDetail = null),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('重选单据'), // TODO(l10n): 补 arb
            ),
          Expanded(
            child: Text(
              title,
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
    );
  }

  // ---- Step1 ------------------------------------------------------------

  Widget _buildStep1(ThemeData theme, MasterNameService names) {
    return Column(
      children: [
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
              SizedBox(
                width: 240,
                child: UtenDropdownField(
                  label: '供应商',
                  value: _supplierId ?? '',
                  items: [
                    const UtenDropdownItem(
                      value: '',
                      label: '全部供应商',
                    ), // TODO(l10n): 补 arb
                    for (final e in names.supplierEntries.entries)
                      UtenDropdownItem(value: e.key, label: e.value),
                  ],
                  onChanged: (v) {
                    setState(
                      () => _supplierId = (v == null || v.isEmpty) ? null : v,
                    );
                    _loadDocs(1);
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: MasterDataTableView<PurchaseDocListItem>(
            columns: _docColumns(names),
            items: _docPage?.items ?? const [],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            sortColumn: _sortKey,
            sortAscending: _sortAsc,
            onSortChange: _onSortChange,
            onRowTap: _pickDoc,
            isLoading: _loadingDocs && _docPage == null,
            loadingMore: _loadingDocs && _docPage != null,
            error: _docsError,
            onRetry: () => _loadDocs(1),
            emptyMessage: '暂无已审${_upTypeLabel()}单', // TODO(l10n): 补 arb
            currentPage: _docPage?.page ?? 1,
            totalPages: _docPage?.totalPages ?? 1,
            onPageChange: (p) => _loadDocs(p),
          ),
        ),
      ],
    );
  }

  List<MasterColumnDef<PurchaseDocListItem>> _docColumns(
    MasterNameService names,
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
      value: (d) => (d.billDate ?? '').substring(0, 10),
    ),
    MasterColumnDef(
      key: 'supplier',
      label: '供应商',
      width: 200,
      value: (d) => names.supplier(d.supplierId),
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
      value: (d) => purchaseStatusLabel(d.status),
    ),
  ];

  // ---- Step2 ------------------------------------------------------------

  Widget _buildStep2(ThemeData theme, MasterNameService names) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s12,
            UtenSpacing.s8,
            UtenSpacing.s12,
            UtenSpacing.s4,
          ),
          child: Row(
            children: [
              TextButton(
                onPressed: () => _setSelectedAll(true),
                child: const Text('全选'),
              ), // TODO(l10n): 补 arb
              TextButton(
                onPressed: _invertSelection,
                child: const Text('反选'),
              ), // TODO(l10n): 补 arb
              TextButton(
                onPressed: () => _setSelectedAll(false),
                child: const Text('取消全选'),
              ), // TODO(l10n): 补 arb
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: UtenEditableGrid<_UpstreamItemRow>(
              controller: _grid,
              columns: _itemColumns(names),
              showAddRow: false,
              showRowDelete: false,
              createBlankRow: () => _UpstreamItemRow(
                const PurchaseDocItem(id: null),
              ), // 不会被调用
              emptyMessage: '该单据无明细', // TODO(l10n): 补 arb
            ),
          ),
        ),
        _buildStep2Footer(theme),
      ],
    );
  }

  Widget _buildStep2Footer(ThemeData theme) {
    final n = _selectedCount;
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
              onPressed: n == 0 ? null : _submit,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('引入'), // TODO(l10n): 补 arb
            ),
          ],
        ),
      ),
    );
  }

  List<EditableGridColumn<_UpstreamItemRow>> _itemColumns(
    MasterNameService names,
  ) => [
    EditableGridColumn<_UpstreamItemRow>(
      key: 'sel',
      label: '',
      width: 50,
      cellBuilder: (context, row) => ValueListenableBuilder<bool>(
        valueListenable: row.selectedNotifier,
        builder: (_, sel, _) =>
            Checkbox(value: sel, onChanged: (v) => _toggleRow(row, v ?? false)),
      ),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'goods',
      label: '货品',
      width: 200,
      cellBuilder: (context, row) => Text(names.goods(row.item.goodsId)),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'color',
      label: '颜色',
      width: 90,
      cellBuilder: (context, row) => Text(names.color(row.item.colorId)),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'unit',
      label: '单位',
      width: 80,
      cellBuilder: (context, row) => Text(names.unit(row.item.unitId)),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'price',
      label: '单价',
      width: 90,
      numeric: true,
      cellBuilder: (context, row) =>
          Text((row.item.price ?? 0).toStringAsFixed(2)),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'qty',
      label: '${_upTypeLabel()}数',
      width: 90,
      numeric: true,
      cellBuilder: (context, row) =>
          Text((row.item.qty ?? 0).toStringAsFixed(1)),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'doneQty',
      label: _upType == PurchaseDocType.order ? '已收' : '已退',
      width: 90,
      numeric: true,
      cellBuilder: (context, row) => Text(
        (_upType == PurchaseDocType.order
                ? (row.item.receivedQty ?? 0)
                : (row.item.returnedQty ?? 0))
            .toStringAsFixed(1),
      ),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'thisQty',
      label: '本次数量',
      width: 120,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.qty,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
  ];

  String _upTypeLabel() {
    switch (_upType) {
      case PurchaseDocType.request:
        return '申请';
      case PurchaseDocType.order:
        return '订货';
      case PurchaseDocType.receipt:
        return '收货';
      case PurchaseDocType.returnDoc:
        return '退货';
    }
  }
}
