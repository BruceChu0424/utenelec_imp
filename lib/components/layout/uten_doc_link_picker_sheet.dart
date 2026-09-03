// 「从上游单据引入」两步大面板（采购/销售/委外编辑页共用）。
//
// 结构收敛（2026-08-16，审计 §4.1 第 1 批）：purchase/sales/subcontract 三个
// 逐字重复的 _UpstreamImportSheet 状态机抽成本组件，外壳复用
// [showUtenAdaptivePanel]（compact 底部弹层降级 + 宽屏 840 右滑入）。
//  两步各自 Excel 表：
//  Step1 上游单据：MasterDataTableView（搜索 + 往来方筛选 + 表头排序 +
//        「表头设置」列显隐 + 分页，状态固定已审——由配置方在 listDocs 里过滤）。
//  Step2 该单据明细：UtenEditableGrid（showAddRow:false）勾选 + 本次数量。
//
// 领域差异（列定义、剩余可引量公式、往来方名词、结果映射）全部由
// [UtenDocLinkPickerConfig] 的闭包提供；本组件只拥有结构与交互状态机
// （分页/排序/关键字、LatestLinkRequestGuard 竞态防护、全选/反选、
// 数量校验与提交）。确认后弹出 [UtenDocLinkPickResult]，由调用方
// 映射为各自领域的结果类型。
//
// 注意：名称类闭包（docColumns、partyEntries、partyName、goodsName 等）
// 接收 sheet build 期由 [UtenDocLinkPickerConfig.watchNames] 统一解析
// （ref.watch）的名称对象，异步更新会触发 sheet 重建；异步上下文闭包
// （listDocs、loadDetail、initNames、loadGoodsNames）接收 WidgetRef，
// 实现内部用 ref.read。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../inputs/uten_field_message.dart';
import '../../shared/models/paged_result.dart';
import '../forms/link_quantity_validator.dart';
import '../inputs/uten_dropdown_field.dart';
import '../inputs/uten_search_bar.dart';
import 'uten_adaptive_panel.dart';
import 'uten_editable_grid.dart';

// 过渡依赖：MasterDataTableView 目前仍在 features/basic_data 下
// （审计 §4.1 第 4 批迁入 components/ 后本导入同步改写）。
import '../../features/basic_data/widgets/master_data_table_view.dart';

/// 上游单据详情的归一化视图：往来方 id + 明细行（由配置方从领域模型转换）。
///
/// [docId]/[docNo] 为所选上游单据的 id/单号（可选）：配置方提供时随确认结果
/// 带回，供编辑页在引入行上回填「来源单据」并支持点击跳转。
/// [settlementMethodId]（可选）为上游单据的结账/结算方式：下游收货/进仓等沿用
/// 来源快照的单据引入后预填（编辑页仍按各自必填校验兜底）。
class UtenDocLinkDetail<I> {
  const UtenDocLinkDetail({
    required this.partyId,
    required this.items,
    this.docId,
    this.docNo,
    this.settlementMethodId,
  });

  final String? partyId;
  final List<I> items;
  final String? docId;
  final String? docNo;
  final String? settlementMethodId;
}

/// 勾选并校验通过的一行引入草稿（归一化，不含领域映射）。
class UtenDocLinkPickedItem {
  const UtenDocLinkPickedItem({
    required this.goodsId,
    required this.qty,
    this.maxQty,
    this.price,
    this.upstreamItemId,
    this.colorId,
    this.unitId,
    this.unitRate,
  });

  final String goodsId;
  final double qty;
  final double? maxQty;
  final double? price;
  final String? upstreamItemId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
}

/// 「从上游引入」的确认返回：所选明细 + 上游单据往来方 id
///（编辑页表头未选往来方时回填用）+ 所选上游单据 id/单号
///（可选，引入行回填来源单据用）+ 上游结账/结算方式（可选，下游沿用来源快照
/// 的单据预填用）。null 表示用户取消。
class UtenDocLinkPickResult<I> {
  const UtenDocLinkPickResult({
    required this.items,
    this.partyId,
    this.sourceDocId,
    this.sourceDocNo,
    this.settlementMethodId,
  });

  final List<UtenDocLinkPickedItem> items;
  final String? partyId;
  final String? sourceDocId;
  final String? sourceDocNo;
  final String? settlementMethodId;
}

/// 上游明细勾选行：持上游明细引用 + 选中态 + 本次数量控制器。
class UtenDocLinkItemRow<I> extends EditableGridRow {
  UtenDocLinkItemRow(this.item);

  final I item;
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

/// 领域明细行的公共字段提取（货品/颜色/单位/单价/上游明细 id）。
///
/// 三个领域的 item 模型字段同名但无共同接口，用提取组保持类型安全，
/// 避免组件对领域模型做 dynamic 反射。
class UtenDocLinkItemFields<I> {
  const UtenDocLinkItemFields({
    required this.goodsId,
    required this.colorId,
    required this.unitId,
    required this.price,
    required this.upstreamItemId,
    this.unitRate,
  });

  final String? Function(I item) goodsId;
  final String? Function(I item) colorId;
  final String? Function(I item) unitId;
  final double? Function(I item) price;
  final String? Function(I item) upstreamItemId;
  final double? Function(I item)? unitRate;
}

/// 两步引入面板的领域配置（由采购/销售/委外的引入入口提供）。
///
/// 泛型：[D] 上游单据列表行，[I] 上游单据明细行，[N] 名称服务
///（build 期由 sheet 统一 watch 一次，再传给下列 names 闭包，
/// 与旧实现在 sheet build 中 resolve names 的时序一致）。
class UtenDocLinkPickerConfig<D, I, N> {
  const UtenDocLinkPickerConfig({
    required this.step1Title,
    required this.step1EmptyMessage,
    required this.partyNoun,
    required this.allPartiesLabel,
    required this.docIdOf,
    required this.partyIdOf,
    required this.watchNames,
    required this.partyEntries,
    required this.partyName,
    required this.initNames,
    required this.loadGoodsNames,
    required this.listDocs,
    required this.loadDetail,
    required this.itemFields,
    required this.docColumns,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.middleItemColumns,
    required this.remainQty,
    required this.createBlankRow,
    this.allowOverRemaining = false,
  });

  /// Step1 标题，如「从订货引入」。
  final String step1Title;

  /// Step1 空态文案，如「暂无已审订货单」。
  final String step1EmptyMessage;

  /// 往来方名词（供应商/客户/委外商），用于筛选器标签与一致性报错。
  final String partyNoun;

  /// 往来方筛选「全部」选项文案。
  final String allPartiesLabel;

  /// 上游单据列表行的 id（行点击加载详情用）。
  final String Function(D doc) docIdOf;

  /// 上游单据列表行的往来方 id（行点击一致性校验用）。
  final String? Function(D doc) partyIdOf;

  /// sheet build 期解析名称服务（实现内部用 ref.watch）。
  final N Function(WidgetRef ref) watchNames;

  /// 往来方下拉选项。
  final Map<String, String> Function(N names) partyEntries;

  /// 往来方显示名（Step2 标题用）。
  final String Function(N names, String? partyId) partyName;

  /// 打开面板时的名称服务预热（异步上下文，实现内部用 ref.read）。
  final Future<void> Function(WidgetRef ref) initNames;

  /// 明细货品名批量加载（异步上下文，实现内部用 ref.read）。
  final Future<void> Function(WidgetRef ref, Set<String> goodsIds)
  loadGoodsNames;

  /// Step1 分页拉单（异步上下文，实现内部用 ref.read）。已审状态等业务过滤由实现方负责。
  final Future<PagedResult<D>> Function(
    WidgetRef ref,
    int page,
    String? keyword,
    String? partyId,
    String? sort,
    String? order,
  )
  listDocs;

  /// 拉单据详情并归一化（异步上下文，实现内部用 ref.read）。
  final Future<UtenDocLinkDetail<I>> Function(WidgetRef ref, String docId)
  loadDetail;

  /// 明细行公共字段提取组。
  final UtenDocLinkItemFields<I> itemFields;

  /// Step1 表格列。
  final List<MasterColumnDef<D>> Function(N names) docColumns;

  /// 明细货品名。
  final String Function(N names, String? goodsId) goodsName;

  /// 明细颜色名。
  final String Function(N names, String? colorId) colorName;

  /// 明细单位名。
  final String Function(N names, String? unitId) unitName;

  /// Step2 明细中段领域列（货品/颜色/单位之后、剩余/本次数量之前）。
  final List<EditableGridColumn<UtenDocLinkItemRow<I>>> Function(N names)
  middleItemColumns;

  /// 上游明细剩余可引量（也是"本次数量"默认值与上限）。
  final double Function(I item) remainQty;

  /// UtenEditableGrid 的空白行工厂（showAddRow:false 下不会被调用）。
  final UtenDocLinkItemRow<I> Function() createBlankRow;

  /// 2026-09 订货超采放开：true 时「本次数量」允许超过剩余量（仅校验大于 0），
  /// 剩余量仍作为默认值与只读对照。采购/委外订货引入申请时置 true；
  /// 收货/退货等实物单据保持上限（默认 false）。
  final bool allowOverRemaining;
}

/// 弹出「从上游引入」两步面板（compact 底部弹层 / 宽屏 840 右滑入）。
///
/// [initialPartyId]：编辑页表头已选往来方时传入，面板往来方筛选默认锁定。
Future<UtenDocLinkPickResult<I>?> showUtenDocLinkPickerSheet<D, I, N>(
  BuildContext context,
  UtenDocLinkPickerConfig<D, I, N> config, {
  String? initialPartyId,
}) {
  return showUtenAdaptivePanel<UtenDocLinkPickResult<I>>(
    context: context,
    compactHeightFactor: 0.9,
    drawerWidth: 840,
    builder: (_) => _UtenDocLinkPickerSheet<D, I, N>(
      config: config,
      initialPartyId: initialPartyId,
    ),
  );
}

class _UtenDocLinkPickerSheet<D, I, N> extends ConsumerStatefulWidget {
  const _UtenDocLinkPickerSheet({required this.config, this.initialPartyId});

  final UtenDocLinkPickerConfig<D, I, N> config;

  /// 编辑页表头已选往来方：面板往来方筛选锁定为该往来方，不允许切换。
  final String? initialPartyId;

  @override
  ConsumerState<_UtenDocLinkPickerSheet<D, I, N>> createState() =>
      _UtenDocLinkPickerSheetState<D, I, N>();
}

class _UtenDocLinkPickerSheetState<D, I, N>
    extends ConsumerState<_UtenDocLinkPickerSheet<D, I, N>> {
  UtenDocLinkPickerConfig<D, I, N> get _cfg => widget.config;

  // Step1 · 上游单据
  PagedResult<D>? _docPage;
  bool _loadingDocs = false;
  String? _docsError;
  final _keywordCtl = TextEditingController();
  String _keyword = '';
  String? _partyId;
  String? _sortKey;
  bool _sortAsc = true;
  final _docsRequests = LatestLinkRequestGuard();
  final _detailRequests = LatestLinkRequestGuard();

  // Step2 · 明细
  UtenDocLinkDetail<I>? _upDetail;
  late final UtenEditableGridController<UtenDocLinkItemRow<I>> _grid;
  bool _loadingItems = false;
  String _gridEmptyMessage = '该单据无明细'; // TODO(l10n): 补 arb

  bool get _partyLocked =>
      widget.initialPartyId != null && widget.initialPartyId!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _grid = UtenEditableGridController<UtenDocLinkItemRow<I>>();
    // 表头已选往来方 → 面板往来方筛选锁定为该往来方。
    _partyId = widget.initialPartyId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cfg.initNames(ref);
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
    // 用户刷新筛选条件时，任何尚未完成的明细请求都不再有资格切换步骤。
    _detailRequests.invalidate();
    setState(() {
      _loadingDocs = true;
      _loadingItems = false;
      _docsError = null;
    });
    try {
      final r = await _cfg.listDocs(
        ref,
        page,
        _keyword.trim().isEmpty ? null : _keyword,
        _partyId,
        _sortKey,
        _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
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

  Future<void> _pickDoc(D d) async {
    if (_loadingDocs) return;
    if (!_matchesSelectedParty(_cfg.partyIdOf(d))) {
      context.appError('上游单据${_cfg.partyNoun}与当前筛选${_cfg.partyNoun}不一致，请刷新后重试');
      return;
    }
    final requestVersion = _detailRequests.begin();
    setState(() {
      _loadingItems = true;
      _upDetail = null;
    });
    try {
      final detail = await _cfg.loadDetail(ref, _cfg.docIdOf(d));
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      if (!_matchesSelectedParty(detail.partyId)) {
        setState(() => _loadingItems = false);
        context.appError('上游单据${_cfg.partyNoun}与表头${_cfg.partyNoun}不一致，已阻止引入');
        return;
      }
      final goodsIds = detail.items
          .map(_cfg.itemFields.goodsId)
          .whereType<String>()
          .toSet();
      await _cfg.loadGoodsNames(ref, goodsIds);
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      // 只显示有剩余可引量的明细：已收完/已发完/已退完的行不显示。
      final visible = detail.items
          .where((it) => _cfg.remainQty(it) > 0)
          .toList();
      final rows = visible.map((it) {
        final row = UtenDocLinkItemRow<I>(it);
        row.qty.text = _cfg.remainQty(it).toString();
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

  bool _matchesSelectedParty(String? partyId) {
    final expected = _partyId;
    return expected == null || expected.isEmpty || partyId == expected;
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

  void _toggleRow(UtenDocLinkItemRow<I> row, bool v) {
    row.selectedNotifier.value = v;
    if (!v) row.qtyError.value = null;
    setState(() {});
  }

  int get _selectedCount => _grid.rows.where((r) => r.selected).length;

  void _submit() {
    final out = <UtenDocLinkPickedItem>[];
    var hasQuantityError = false;
    for (final row in _grid.rows) {
      if (!row.selected) continue;
      final it = row.item;
      final goodsId = _cfg.itemFields.goodsId(it);
      if (goodsId == null) continue;
      final remaining = _cfg.remainQty(it);
      final error = validateLinkQuantity(
        row.qty.text,
        remaining: remaining,
        allowOverRemaining: _cfg.allowOverRemaining,
      );
      row.qtyError.value = error;
      if (error != null) {
        hasQuantityError = true;
        continue;
      }
      final q = double.parse(row.qty.text.trim());
      out.add(
        UtenDocLinkPickedItem(
          goodsId: goodsId,
          qty: q,
          maxQty: remaining,
          price: _cfg.itemFields.price(it),
          upstreamItemId: _cfg.itemFields.upstreamItemId(it),
          colorId: _cfg.itemFields.colorId(it),
          unitId: _cfg.itemFields.unitId(it),
          unitRate: _cfg.itemFields.unitRate?.call(it),
        ),
      );
    }
    if (hasQuantityError) {
      context.appError('请修正标红的本次数量后再引入');
      return;
    }
    Navigator.of(context).pop(
      UtenDocLinkPickResult<I>(
        items: out,
        partyId: _upDetail?.partyId,
        sourceDocId: _upDetail?.docId,
        sourceDocNo: _upDetail?.docNo,
        settlementMethodId: _upDetail?.settlementMethodId,
      ),
    );
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 名称服务在 sheet build 期统一 watch 一次（ensureLoaded 异步完成后自动重建）。
    final names = _cfg.watchNames(ref);
    final inStep2 = _upDetail != null;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(theme, names, inStep2),
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

  Widget _buildHeader(ThemeData theme, N names, bool inStep2) {
    final title = inStep2
        ? '选择明细(${_cfg.partyName(names, _upDetail!.partyId)})'
        : _cfg.step1Title;
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

  Widget _buildStep1(ThemeData theme, N names) {
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
                child: UtenSearchBar(
                  controller: _keywordCtl,
                  hint: '搜索单据号', // TODO(l10n): 补 arb
                  onChanged: _onKeywordChanged,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              SizedBox(
                width: 240,
                child: UtenDropdownField(
                  label: _partyLocked
                      ? '${_cfg.partyNoun}(已锁定)'
                      : _cfg.partyNoun,
                  value: _partyId ?? '',
                  enabled: !_partyLocked,
                  allowClear: !_partyLocked,
                  items: [
                    if (!_partyLocked)
                      UtenDropdownItem(value: '', label: _cfg.allPartiesLabel),
                    for (final e in _cfg.partyEntries(names).entries)
                      UtenDropdownItem(value: e.key, label: e.value),
                  ],
                  onChanged: (v) {
                    if (_partyLocked) return;
                    setState(() {
                      _partyId = (v == null || v.isEmpty) ? null : v;
                    });
                    _loadDocs(1);
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: MasterDataTableView<D>(
            columns: _cfg.docColumns(names),
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
            emptyMessage: _cfg.step1EmptyMessage,
            currentPage: _docPage?.page ?? 1,
            totalPages: _docPage?.totalPages ?? 1,
            onPageChange: (p) => _loadDocs(p),
          ),
        ),
      ],
    );
  }

  // ---- Step2 ------------------------------------------------------------

  Widget _buildStep2(ThemeData theme, N names) {
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
            child: UtenEditableGrid<UtenDocLinkItemRow<I>>(
              controller: _grid,
              columns: _itemColumns(names),
              // showAddRow:false → 不显示"添加行"栏（这里是选明细不是编辑）。
              showAddRow: false,
              showRowDelete: false,
              createBlankRow: _cfg.createBlankRow,
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

  List<EditableGridColumn<UtenDocLinkItemRow<I>>> _itemColumns(N names) => [
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'sel',
      label: '',
      width: 50,
      cellBuilder: (context, row) => ValueListenableBuilder<bool>(
        valueListenable: row.selectedNotifier,
        builder: (_, sel, _) =>
            Checkbox(value: sel, onChanged: (v) => _toggleRow(row, v ?? false)),
      ),
    ),
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'goods',
      label: '货品',
      width: 200,
      cellBuilder: (context, row) =>
          Text(_cfg.goodsName(names, _cfg.itemFields.goodsId(row.item))),
    ),
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'color',
      label: '颜色',
      width: 90,
      cellBuilder: (context, row) =>
          Text(_cfg.colorName(names, _cfg.itemFields.colorId(row.item))),
    ),
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'unit',
      label: '单位',
      width: 80,
      cellBuilder: (context, row) =>
          Text(_cfg.unitName(names, _cfg.itemFields.unitId(row.item))),
    ),
    ..._cfg.middleItemColumns(names),
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'remainingQty',
      label: '剩余',
      width: 90,
      numeric: true,
      cellBuilder: (context, row) =>
          Text(formatLinkQuantity(_cfg.remainQty(row.item))),
    ),
    EditableGridColumn<UtenDocLinkItemRow<I>>(
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
            error: utenFieldError(error),
          ),
          onChanged: (value) {
            if (row.qtyError.value != null) {
              row.qtyError.value = validateLinkQuantity(
                value,
                remaining: _cfg.remainQty(row.item),
                allowOverRemaining: _cfg.allowOverRemaining,
              );
            }
          },
        ),
      ),
    ),
  ];
}
