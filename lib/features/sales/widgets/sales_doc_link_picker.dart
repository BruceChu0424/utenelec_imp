// 上游单据明细引入面板（销售编辑页"从上游引入"用）。
//
// 重做（2026-07-28）：从居中 Dialog 换成右滑入大面板（840，与 showUtenGoodsPicker 统一），
// 两步各自 Excel 表：
//  Step1 上游单据：MasterDataTableView（搜索 + 客户筛选 + 分页 + 排序，状态固定已审）。
//  Step2 该单据明细：UtenEditableGrid（showAddRow:false）勾选 + 本次数量。
// 确认返回所选 [SalesLinkedItem] 列表，编辑页据此外推明细行。
//
// 上游类型由 cfg 决定：
//  - linkToOutItem（退货链出货）：拉 shipments（已审）
//  - linkToOrderItem（出货/退货链订货）：拉 orders（已审）
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
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';

/// 上游引入回填项：货品 + 本次数量 + 单价 + 上游明细 id（用于回写 orderItemId/outItemId）+
/// 可选颜色/单位。
class SalesLinkedItem {
  const SalesLinkedItem({
    required this.goodsId,
    required this.qty,
    this.price,
    this.orderItemId,
    this.outItemId,
    this.colorId,
    this.unitId,
  });

  final String goodsId;
  final double qty;
  final double? price;
  final String? orderItemId;
  final String? outItemId;
  final String? colorId;
  final String? unitId;
}

/// 「从上游引入」的确认返回：所选明细 + 上游单据客户 id
///（编辑页表头未选客户时，据此外填表头客户并联动地址/电话）。
class SalesLinkPickResult {
  const SalesLinkPickResult({required this.items, this.clientId});

  final List<SalesLinkedItem> items;
  final String? clientId;
}

/// 决定引入源（订货 / 出货）。退货同时双挂时优先出货（outItemId 真骨干），
/// 订货 orderItemId 由编辑页"再引入一次订货"补全（v1 简化，逻辑沿用）。
SalesDocType _upstreamType(SalesDocConfig cfg) {
  if (cfg.linkToOutItem) return SalesDocType.shipment;
  if (cfg.linkToOrderItem) return SalesDocType.order;
  return SalesDocType.order;
}

/// 弹出"从上游引入"右滑入大面板；返回所选明细 + 上游客户（null 表示取消）。
/// [initialClientId]：编辑页表头已选客户时传入，面板客户筛选默认锁定该客户。
Future<SalesLinkPickResult?> showSalesDocLinkPicker(
  BuildContext context,
  WidgetRef ref,
  SalesDocConfig cfg, {
  String? initialClientId,
}) {
  final sheet = _UpstreamImportSheet(
    cfg: cfg,
    upstreamType: _upstreamType(cfg),
    initialClientId: initialClientId,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<SalesLinkPickResult>(
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
  return showGeneralDialog<SalesLinkPickResult>(
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
  final SalesDocItem item;
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
    required this.upstreamType,
    this.initialClientId,
  });

  final SalesDocConfig cfg;
  final SalesDocType upstreamType;

  /// 编辑页表头已选客户：面板客户筛选锁定为该客户，不允许切换。
  final String? initialClientId;

  @override
  ConsumerState<_UpstreamImportSheet> createState() =>
      _UpstreamImportSheetState();
}

class _UpstreamImportSheetState extends ConsumerState<_UpstreamImportSheet> {
  SalesDocType get _upType => widget.upstreamType;

  // Step1 · 上游单据
  PagedResult<SalesDocListItem>? _docPage;
  bool _loadingDocs = false;
  String? _docsError;
  final _keywordCtl = TextEditingController();
  String _keyword = '';
  String? _clientId;
  String? _sortKey;
  bool _sortAsc = true;
  final _docsRequests = LatestLinkRequestGuard();
  final _detailRequests = LatestLinkRequestGuard();

  // Step2 · 明细
  SalesDocDetail? _upDetail;
  late final UtenEditableGridController<_UpstreamItemRow> _grid;
  bool _loadingItems = false;
  String _gridEmptyMessage = '该单据无明细';

  bool get _clientLocked =>
      widget.initialClientId != null && widget.initialClientId!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _grid = UtenEditableGridController<_UpstreamItemRow>();
    // 表头已选客户 → 面板客户筛选锁定为该客户。
    _clientId = widget.initialClientId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesMasterNameServiceProvider).ensureLoaded();
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
      final r = await ref
          .read(salesRepositoryProvider(_upType))
          .list(
            page: page,
            // 业务约束：只引入已审单（草稿/红冲不可引入）。
            filter: SalesDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              clientId: _clientId,
              status: kSalesStatusApproved,
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

  Future<void> _pickDoc(SalesDocListItem d) async {
    if (_loadingDocs) return;
    if (!_matchesSelectedClient(d.clientId)) {
      context.appError('上游单据客户与当前筛选客户不一致，请刷新后重试');
      return;
    }
    final requestVersion = _detailRequests.begin();
    setState(() {
      _loadingItems = true;
      _upDetail = null;
    });
    try {
      final detail = await ref
          .read(salesRepositoryProvider(_upType))
          .detail(d.id);
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      if (!_matchesSelectedClient(detail.clientId)) {
        setState(() => _loadingItems = false);
        context.appError('上游单据客户与表头客户不一致，已阻止引入');
        return;
      }
      final goodsIds = detail.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      // 只显示有剩余可引量的明细：已发完（出货←订货）/已退完（退货←出货/订货）的行不显示。
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
  /// 出货←订货 = 订货数 − 已发；退货←出货/订货 = 原单数 − 已退；其它 = 全额。
  double _remainQty(SalesDocItem it) {
    final q = it.qty ?? 0;
    if (_upType == SalesDocType.order &&
        widget.cfg.type == SalesDocType.shipment) {
      return q - (it.shippedQty ?? 0);
    }
    if (widget.cfg.type == SalesDocType.returnDoc) {
      return q - (it.returnedQty ?? 0);
    }
    return q;
  }

  bool _matchesSelectedClient(String? clientId) {
    final expected = _clientId;
    return expected == null || expected.isEmpty || clientId == expected;
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
    final out = <SalesLinkedItem>[];
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
        SalesLinkedItem(
          goodsId: it.goodsId!,
          qty: q,
          price: it.price,
          orderItemId:
              widget.cfg.linkToOrderItem && _upType == SalesDocType.order
              ? it.id
              : null,
          outItemId:
              widget.cfg.linkToOutItem && _upType == SalesDocType.shipment
              ? it.id
              : null,
          colorId: it.colorId,
          unitId: it.unitId,
        ),
      );
    }
    if (hasQuantityError) {
      context.appError('请修正标红的本次数量后再引入');
      return;
    }
    Navigator.of(
      context,
    ).pop(SalesLinkPickResult(items: out, clientId: _upDetail?.clientId));
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
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
    SalesMasterNameService names,
  ) {
    final title = inStep2
        ? '选择明细（${names.client(_upDetail!.clientId)}）'
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

  Widget _buildStep1(ThemeData theme, SalesMasterNameService names) {
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
                  label: _clientLocked ? '客户（已锁定）' : '客户',
                  value: _clientId ?? '',
                  enabled: !_clientLocked,
                  allowClear: !_clientLocked,
                  items: [
                    if (!_clientLocked)
                      const UtenDropdownItem(
                        value: '',
                        label: '全部客户',
                      ), // TODO(l10n): 补 arb
                    for (final e in names.clientEntries.entries)
                      UtenDropdownItem(value: e.key, label: e.value),
                  ],
                  onChanged: (v) {
                    if (_clientLocked) return;
                    setState(
                      () => _clientId = (v == null || v.isEmpty) ? null : v,
                    );
                    _loadDocs(1);
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: MasterDataTableView<SalesDocListItem>(
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

  List<MasterColumnDef<SalesDocListItem>> _docColumns(
    SalesMasterNameService names,
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
      key: 'client',
      label: '客户',
      width: 200,
      value: (d) => names.client(d.clientId),
    ),
    if (_upType == SalesDocType.order)
      MasterColumnDef(
        key: 'currency',
        label: '币种',
        width: 100,
        value: (d) => names.currency(d.currencyId),
      ),
    MasterColumnDef(
      key: 'total',
      label: _upType == SalesDocType.order ? '订单金额' : '合计',
      width: 120,
      type: 'money',
      sortable: _upType != SalesDocType.order,
      value: (d) =>
          (_upType == SalesDocType.order ? d.totalOriginal : d.totalLocal)
              ?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 90,
      value: (d) => salesStatusLabel(d.status),
    ),
  ];

  // ---- Step2 ------------------------------------------------------------

  Widget _buildStep2(ThemeData theme, SalesMasterNameService names) {
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
          // UtenEditableGrid 表体 content-tall（shrinkWrap，不自竖滚），外层竖向滚动；
          // 明细行数一般可控（一张单几十行），表头随滚可接受（与编辑页明细一致）。
          child: SingleChildScrollView(
            child: UtenEditableGrid<_UpstreamItemRow>(
              controller: _grid,
              columns: _itemColumns(names),
              // showAddRow:false → 不显示"添加行"栏（这里是选明细不是编辑）。
              showAddRow: false,
              showRowDelete: false,
              createBlankRow: () =>
                  _UpstreamItemRow(const SalesDocItem(id: null)), // 不会被调用
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
    SalesMasterNameService names,
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
      key: 'qty',
      label: _upType == SalesDocType.order ? '订货数' : '出货数',
      width: 90,
      numeric: true,
      cellBuilder: (context, row) =>
          Text((row.item.qty ?? 0).toStringAsFixed(1)),
    ),
    EditableGridColumn<_UpstreamItemRow>(
      key: 'shipped',
      label: _upType == SalesDocType.order ? '已发' : '已退',
      width: 90,
      numeric: true,
      cellBuilder: (context, row) => Text(
        (_upType == SalesDocType.order
                ? (row.item.shippedQty ?? 0)
                : (row.item.returnedQty ?? 0))
            .toStringAsFixed(1),
      ),
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

  String _upTypeLabel() {
    switch (_upType) {
      case SalesDocType.order:
        return '订货';
      case SalesDocType.shipment:
        return '出货';
      default:
        return '上游';
    }
  }
}
