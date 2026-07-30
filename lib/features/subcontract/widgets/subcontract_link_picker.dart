// 委外上游单据明细引入面板（编辑页"从上游引入"用）。
//
// 重做（2026-07-29）：从居中 Dialog + 卡片/ListTile 换成右滑入大面板（840，
// 与销售 showSalesDocLinkPicker 统一），两步各自 Excel 表：
//  Step1 上游单据：MasterDataTableView（搜索 + 委外商筛选 + 表头排序 +
//        「表头设置」列显隐 + 分页，状态固定已审）。
//  Step2 该单据明细：UtenEditableGrid（showAddRow:false）勾选 + 本次数量。
// 确认返回 [LinkedItem] 列表，编辑页据此外推明细行并回填对应 *ItemId。
//
// 委外 8 单据链路更复杂（4 个上游方向，见 upstreamTypeOf）：
//   订货 → 申请；进仓 → 订货；退货 → 进仓优先/订货；发料 → 订货；
//   材料退 → 发料优先/订货；损耗 → 发料。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/forms/link_quantity_validator.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../repositories/subcontract_repository.dart';
import '../providers/subcontract_providers.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;

/// 上游引入回填项：货品 + 本次数量 + 单价(可空) + 上游明细 id + 颜色/单位。
/// [upstreamItemId] 由编辑页按 cfg 映射为对应 *ItemId 字段。
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

/// 「从上游引入」的确认返回：所选明细 + 上游单据委外商 id（编辑页表头未选委外商时回填用）。
class SubcontractLinkPickResult {
  const SubcontractLinkPickResult({required this.items, this.supplierId});

  final List<LinkedItem> items;
  final String? supplierId;
}

/// 由 cfg 推断上游单据类型。退货/材料退双链时优先进仓/发料（更接近源头）。
SubcontractDocType upstreamTypeOf(SubcontractDocConfig cfg) {
  if (cfg.linkToReceiptItem) return SubcontractDocType.receipt;
  if (cfg.linkToMaterialIssueItem) return SubcontractDocType.materialIssue;
  if (cfg.linkToOrderItem) return SubcontractDocType.order;
  return SubcontractDocType.application;
}

/// 弹出"从上游引入"右滑入大面板。null=取消；返回所选明细 + 上游委外商。
/// [initialSupplierId]：编辑页表头已选委外商时传入，面板委外商筛选默认锁定该委外商。
Future<SubcontractLinkPickResult?> showSubcontractLinkPicker(
  BuildContext context,
  WidgetRef ref,
  SubcontractDocConfig cfg, {
  String? initialSupplierId,
}) {
  final sheet = _UpstreamImportSheet(
    cfg: cfg,
    upstream: upstreamTypeOf(cfg),
    initialSupplierId: initialSupplierId,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<SubcontractLinkPickResult>(
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
  return showGeneralDialog<SubcontractLinkPickResult>(
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
  final SubcontractDocItem item;
  final ValueNotifier<bool> selectedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String?> qtyError = ValueNotifier<String?>(null);
  final TextEditingController qty = TextEditingController();
  bool get selected => selectedNotifier.value;

  @override
  void dispose() {
    selectedNotifier.dispose();
    qtyError.dispose();
    qty.dispose();
    super.dispose();
  }
}

class _UpstreamImportSheet extends ConsumerStatefulWidget {
  const _UpstreamImportSheet({
    required this.cfg,
    required this.upstream,
    this.initialSupplierId,
  });
  final SubcontractDocConfig cfg;
  final SubcontractDocType upstream;

  /// 编辑页表头已选委外商：面板委外商筛选锁定为该委外商，不允许切换。
  final String? initialSupplierId;

  @override
  ConsumerState<_UpstreamImportSheet> createState() =>
      _UpstreamImportSheetState();
}

class _UpstreamImportSheetState extends ConsumerState<_UpstreamImportSheet> {
  SubcontractDocType get _upstream => widget.upstream;

  // Step1 · 上游单据
  PagedResult<SubcontractDocListItem>? _docPage;
  bool _loadingDocs = false;
  String? _docsError;
  final _keywordCtl = TextEditingController();
  String _keyword = '';
  String? _supplierId;
  String? _sortKey;
  bool _sortAsc = true;
  final _docsRequests = LatestLinkRequestGuard();
  final _detailRequests = LatestLinkRequestGuard();

  // Step2 · 明细
  SubcontractDocDetail? _upDetail;
  late final UtenEditableGridController<_UpstreamItemRow> _grid;
  bool _loadingItems = false;
  String _gridEmptyMessage = '该单据无明细';

  bool get _supplierLocked =>
      widget.initialSupplierId != null && widget.initialSupplierId!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _grid = UtenEditableGridController<_UpstreamItemRow>();
    // 表头已选委外商 → 面板委外商筛选锁定为该委外商。
    _supplierId = widget.initialSupplierId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(mn.masterNameServiceProvider).ensureLoaded();
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
    final requestVersion = _docsRequests.begin();
    _detailRequests.invalidate();
    setState(() {
      _loadingDocs = true;
      _loadingItems = false;
      _docsError = null;
    });
    try {
      // 拉已审单据（草稿单据的明细不该被引入）。
      final r = await ref
          .read(subcontractRepositoryProvider(_upstream))
          .list(
            page: page,
            filter: SubcontractDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              supplierId: _supplierId,
              status: kSubcontractStatusApproved,
            ),
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || !_docsRequests.isCurrent(requestVersion)) return;
      setState(() {
        _docPage = r;
        _loadingDocs = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_docsRequests.isCurrent(requestVersion)) return;
      setState(() {
        _docsError = e.message;
        _loadingDocs = false;
      });
    } catch (_) {
      if (!mounted || !_docsRequests.isCurrent(requestVersion)) return;
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

  Future<void> _pickDoc(SubcontractDocListItem d) async {
    if (_loadingDocs) return;
    if (!_matchesSelectedSupplier(d.supplierId)) {
      context.appError('上游单据委外商与当前筛选委外商不一致，请刷新后重试');
      return;
    }
    final requestVersion = _detailRequests.begin();
    setState(() {
      _loadingItems = true;
      _upDetail = null;
    });
    try {
      final detail = await ref
          .read(subcontractRepositoryProvider(_upstream))
          .detail(d.id);
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      if (!_matchesSelectedSupplier(detail.supplierId)) {
        setState(() => _loadingItems = false);
        context.appError('上游单据委外商与表头委外商不一致，已阻止引入');
        return;
      }
      final goodsIds = detail.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      // 只显示有剩余可引量的明细：已收完/已发完料/已退完/已损耗完的行不显示。
      final visible = detail.items.where((it) => _remainQty(it) > 0).toList();
      final rows = visible.map((it) {
        final row = _UpstreamItemRow(it);
        row.qty.text = _remainQty(it).toString();
        return row;
      }).toList();
      _grid.replaceAll(rows);
      setState(() {
        _upDetail = detail;
        _gridEmptyMessage = detail.items.isEmpty
            ? '该单据无明细'
            : visible.isEmpty
            ? '该单据明细已全部完成，无剩余可引入'
            : '该单据无明细';
        _loadingItems = false;
      });
    } catch (_) {
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      setState(() => _loadingItems = false);
      // 静默降级（与 v1 一致）
    }
  }

  /// 上游明细剩余可引量（也是"本次数量"默认值）：
  /// 进仓←订货 = 订货数 − 已收；发料←订货 = 订货数 − 已发料；
  /// 退货←进仓/订货 = 原单数 − 已退；材料退/损耗←发料 = 发出数 − 已退 − 已损耗；
  /// 其它（订货←申请）= 全额。
  double _remainQty(SubcontractDocItem it) {
    final q = it.qty ?? 0;
    switch (_upstream) {
      case SubcontractDocType.order:
        if (widget.cfg.type == SubcontractDocType.receipt) {
          return q - (it.receivedQty ?? 0);
        }
        if (widget.cfg.type == SubcontractDocType.materialIssue) {
          return q - (it.issuedQty ?? 0);
        }
        return q - (it.returnedQty ?? 0);
      case SubcontractDocType.receipt:
        return q - (it.returnedQty ?? 0);
      case SubcontractDocType.materialIssue:
        return q - (it.returnedQty ?? 0) - (it.wastedQty ?? 0);
      default:
        return q;
    }
  }

  bool _matchesSelectedSupplier(String? supplierId) {
    final expected = _supplierId;
    return expected == null || expected.isEmpty || supplierId == expected;
  }

  void _setSelectedAll(bool v) {
    for (final r in _grid.rows) {
      r.selectedNotifier.value = v;
      if (!v) r.qtyError.value = null;
    }
    setState(() {});
  }

  void _invertSelection() {
    for (final r in _grid.rows) {
      r.selectedNotifier.value = !r.selectedNotifier.value;
      if (!r.selected) r.qtyError.value = null;
    }
    setState(() {});
  }

  void _toggleRow(_UpstreamItemRow row, bool v) {
    row.selectedNotifier.value = v;
    if (!v) row.qtyError.value = null;
    setState(() {});
  }

  int get _selectedCount => _grid.rows.where((r) => r.selected).length;

  void _submit() {
    final out = <LinkedItem>[];
    var hasQuantityError = false;
    for (final row in _grid.rows) {
      if (!row.selected) continue;
      final it = row.item;
      if (it.goodsId == null) continue;
      final error = validateLinkQuantity(
        row.qty.text,
        remaining: _remainQty(it),
      );
      row.qtyError.value = error;
      if (error != null) {
        hasQuantityError = true;
        continue;
      }
      final q = double.parse(row.qty.text.trim());
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
    if (hasQuantityError) {
      context.appError('请修正标红的本次数量后再引入');
      return;
    }
    Navigator.of(context).pop(
      SubcontractLinkPickResult(items: out, supplierId: _upDetail?.supplierId),
    );
  }

  String get _upstreamLabel {
    switch (_upstream) {
      case SubcontractDocType.application:
        return '委外申请单';
      case SubcontractDocType.order:
        return '委外订货单';
      case SubcontractDocType.receipt:
        return '委外进仓单';
      case SubcontractDocType.materialIssue:
        return '委外发料单';
      default:
        return '上游单据';
    }
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(mn.masterNameServiceProvider);
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
    mn.MasterNameService names,
  ) {
    final title = inStep2
        ? '选择明细（${names.supplier(_upDetail!.supplierId)}）'
        : '从$_upstreamLabel引入';
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

  Widget _buildStep1(ThemeData theme, mn.MasterNameService names) {
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
                  label: _supplierLocked ? '委外商（已锁定）' : '委外商',
                  value: _supplierId ?? '',
                  enabled: !_supplierLocked,
                  allowClear: !_supplierLocked,
                  items: [
                    if (!_supplierLocked)
                      const UtenDropdownItem(
                        value: '',
                        label: '全部委外商',
                      ), // TODO(l10n): 补 arb
                    for (final e in names.supplierEntries.entries)
                      UtenDropdownItem(value: e.key, label: e.value),
                  ],
                  onChanged: (v) {
                    if (_supplierLocked) return;
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
          child: MasterDataTableView<SubcontractDocListItem>(
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
            emptyMessage: '暂无已审的$_upstreamLabel', // TODO(l10n): 补 arb
            currentPage: _docPage?.page ?? 1,
            totalPages: _docPage?.totalPages ?? 1,
            onPageChange: (p) => _loadDocs(p),
          ),
        ),
      ],
    );
  }

  List<MasterColumnDef<SubcontractDocListItem>> _docColumns(
    mn.MasterNameService names,
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
      label: '委外商',
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
      value: (d) => subcontractStatusLabel(d.status),
    ),
  ];

  // ---- Step2 ------------------------------------------------------------

  Widget _buildStep2(ThemeData theme, mn.MasterNameService names) {
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
              createBlankRow: () =>
                  _UpstreamItemRow(const SubcontractDocItem(id: null)), // 不会被调用
              emptyMessage: _gridEmptyMessage, // TODO(l10n): 补 arb
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
    mn.MasterNameService names,
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
      label: '上游数量',
      width: 90,
      numeric: true,
      cellBuilder: (context, row) =>
          Text((row.item.qty ?? 0).toStringAsFixed(1)),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'remainingQty',
      label: '剩余',
      width: 90,
      numeric: true,
      cellBuilder: (context, row) =>
          Text(formatLinkQuantity(_remainQty(row.item))),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'thisQty',
      label: '本次数量',
      width: 170,
      numeric: true,
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.qtyError,
        builder: (context, error, _) => TextField(
          controller: row.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            isDense: true,
            hintText: '0',
            errorText: error,
          ),
          onChanged: (value) {
            if (row.qtyError.value != null) {
              row.qtyError.value = validateLinkQuantity(
                value,
                remaining: _remainQty(row.item),
              );
            }
          },
        ),
      ),
    ),
  ];
}
