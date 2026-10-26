import '../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../shared/formatters/exact_decimal.dart';
// 「从上游单据引入」两步大面板（采购/销售/委外编辑页共用）。
//
// 结构收敛（2026-08-16，审计 §4.1 第 1 批）：purchase/sales/subcontract 三个
// 逐字重复的 _UpstreamImportSheet 状态机抽成本组件，外壳复用
// [showUtenAdaptivePanel]（compact 底部弹层降级 + 宽屏右滑入，browse 档 75% 屏宽、840 只作小屏下限，2026-10-17）。
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
// 注意：名称类闭包（docColumns、partyName、goodsName 等）
// 接收 sheet build 期由 [UtenDocLinkPickerConfig.watchNames] 统一解析
// （ref.watch）的名称对象，异步更新会触发 sheet 重建；异步上下文闭包
// （listDocs、loadDetail、initNames、loadGoodsNames）接收 WidgetRef，
// 实现内部用 ref.read。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../data_display/uten_goods_identity_cell.dart';
import '../inputs/uten_field_message.dart';
import '../../shared/models/paged_result.dart';
import '../../shared/models/procurement_source_terms.dart';
import '../forms/link_quantity_validator.dart';
import '../inputs/uten_input_decoration.dart';
import '../inputs/uten_search_bar.dart';
import 'uten_adaptive_panel.dart';
import 'uten_panel_header.dart';
import 'uten_editable_grid.dart';

// 过渡依赖：MasterDataTableView 目前仍在 features/basic_data 下
// （审计 §4.1 第 4 批迁入 components/ 后本导入同步改写）。
import '../../features/basic_data/widgets/master_data_table_view.dart';
import '../../features/basic_data/widgets/uten_master_picker.dart';
import '../../shared/providers/export_context_epoch_provider.dart';

typedef UtenDocLinkParty = ({String id, String name});

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
    this.sourceTerms,
    this.sourceEnded = false,
  });

  final String? partyId;
  final List<I> items;
  final String? docId;
  final String? docNo;
  final String? settlementMethodId;
  final ProcurementSourceTerms? sourceTerms;

  /// The domain marks administrative order closure; recorded differences remain intact.
  final bool sourceEnded;
}

/// 勾选并校验通过的一行引入草稿（归一化，不含领域映射）。
class UtenDocLinkPickedItem {
  const UtenDocLinkPickedItem({
    required this.goodsId,
    required this.qty,
    this.maxQty,
    this.maxGiftQtyText,
    this.giftQtyText,
    this.maxQtyText,
    this.qtyText,
    this.price,
    this.upstreamItemId,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.unitRateText,
  });

  final String goodsId;
  final double qty;
  final double? maxQty;
  final String? maxGiftQtyText;
  final String? giftQtyText;
  final String? maxQtyText;
  final String? qtyText;
  final double? price;
  final String? upstreamItemId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final String? unitRateText;
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
    this.sourceTerms,
  });

  final List<UtenDocLinkPickedItem> items;
  final String? partyId;
  final String? sourceDocId;
  final String? sourceDocNo;
  final String? settlementMethodId;
  final ProcurementSourceTerms? sourceTerms;
}

/// 上游明细勾选行：持上游明细引用 + 选中态 + 本次数量控制器。
class UtenDocLinkItemRow<I> extends EditableGridRow {
  UtenDocLinkItemRow(this.item);

  final I item;
  final ValueNotifier<bool> selectedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String?> qtyError = ValueNotifier<String?>(null);
  final TextEditingController qty = TextEditingController();
  final TextEditingController giftQty = TextEditingController(text: '0');
  bool get selected => selectedNotifier.value;

  @override
  void dispose() {
    selectedNotifier.dispose();
    qtyError.dispose();
    qty.dispose();
    giftQty.dispose();
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
    this.unitRateText,
  });

  final String? Function(I item) goodsId;
  final String? Function(I item) colorId;
  final String? Function(I item) unitId;
  final double? Function(I item) price;
  final String? Function(I item) upstreamItemId;
  final double? Function(I item)? unitRate;
  final String? Function(I item)? unitRateText;
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
    required this.pickParty,
    required this.loadPartyNames,
    required this.partyName,
    required this.initNames,
    required this.loadGoodsNames,
    required this.listDocs,
    required this.loadDetail,
    required this.itemFields,
    required this.docColumns,
    required this.goodsName,
    this.goodsCode,
    required this.colorName,
    required this.unitName,
    required this.middleItemColumns,
    required this.remainQty,
    required this.createBlankRow,
    this.remainQtyText,
    this.remainGiftQtyText,
    this.allowOverRemaining = false,
    this.allowGiftOverRemaining = false,
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

  /// Complete, authorized candidates come from the existing paged master picker.
  final Future<UtenDocLinkParty?> Function(BuildContext context, WidgetRef ref)
  pickParty;
  final Future<void> Function(WidgetRef ref, Set<String> ids) loadPartyNames;

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

  /// 明细货品编号（2026-09-14 用户口径：货品身份要能同时看到名称+编号+颜色）。
  /// 宿主没接线时返回 null，货品格自然退回单行名称，不显示占位词。
  final String? Function(N names, String? goodsId)? goodsCode;

  /// 明细颜色名。
  final String Function(N names, String? colorId) colorName;

  /// 明细单位名。
  final String Function(N names, String? unitId) unitName;

  /// Step2 明细中段领域列（货品/颜色/单位之后、剩余/本次数量之前）。
  final List<EditableGridColumn<UtenDocLinkItemRow<I>>> Function(N names)
  middleItemColumns;

  /// 上游明细剩余可引量（也是"本次数量"默认值与上限）。
  final double Function(I item) remainQty;
  final String? Function(I item)? remainQtyText;
  final String? Function(I item)? remainGiftQtyText;

  /// UtenEditableGrid 的空白行工厂（showAddRow:false 下不会被调用）。
  final UtenDocLinkItemRow<I> Function() createBlankRow;

  /// 2026-09 订货超采放开：true 时「本次数量」允许超过剩余量（仅校验大于 0），
  /// 剩余量仍作为默认值与只读对照。采购/委外订货引入申请时置 true；
  /// 收货/退货等实物单据保持上限（默认 false）。
  final bool allowOverRemaining;

  /// Only demand-to-new-order entry may offer extra gifts beyond the request's
  /// declared gift default. Approved receipt/return sources keep strict caps.
  final bool allowGiftOverRemaining;
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
    extends ConsumerState<_UtenDocLinkPickerSheet<D, I, N>>
    with ScopedPagedReadViewMixin<_UtenDocLinkPickerSheet<D, I, N>> {
  final _readViewportRows = MasterDataTableRowsController<D>();
  int get _visibleReadPage => _docPage == null
      ? (_docPage?.page ?? 1)
      : (_readViewportRows.visiblePage ?? (_docPage?.page ?? 1));

  @override
  void scopedPagedReadOwnerChanged() {
    _docsRequests.invalidate();
    _detailRequests.invalidate();
    if (mounted) {
      setState(() {
        _docPage = null;
        _upDetail = null;
        _grid.clear();
        _loadingDocs = false;
        _loadingItems = false;
      });
    }
    if (mounted) {
      setState(() {
        _docsError = scopedPagedReadRejection?.message;
      });
    }
  }

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
  bool _readerInvalidated = false;
  final _detailRequests = LatestLinkRequestGuard();

  // Step2 · 明细
  UtenDocLinkDetail<I>? _upDetail;
  late final UtenEditableGridController<UtenDocLinkItemRow<I>> _grid;
  bool _loadingItems = false;
  bool _hasUnknownQuantities = false;
  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      lookupAppLocalizations(Localizations.localeOf(context));
  String _gridEmptyMessage = '该单据无明细'; // TODO(l10n): 补 arb

  bool get _partyLocked =>
      widget.initialPartyId != null && widget.initialPartyId!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (!mounted || _readerInvalidated || previous == next) return;
      _readerInvalidated = true;
      _docsRequests.invalidate();
      _detailRequests.invalidate();
      setState(() {
        _docPage = null;
        _upDetail = null;
        _grid.clear();
        _loadingDocs = false;
        _loadingItems = false;
        _docsError = null;
      });
      Navigator.of(context).pop();
    });
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

  Future<void> _loadDocs(int page, {bool useCache = false}) async {
    if (_readerInvalidated) return;
    final requestVersion = _docsRequests.begin();
    // 用户刷新筛选条件时，任何尚未完成的明细请求都不再有资格切换步骤。
    _detailRequests.invalidate();
    setState(() {
      _loadingDocs = true;
      _loadingItems = false;
      _docsError = null;
    });
    final config = _cfg;
    final keyword = _keyword.trim().isEmpty ? null : _keyword;
    final partyId = _partyId, sort = _sortKey;
    final order = sort == null ? null : (_sortAsc ? 'asc' : 'desc');
    Object pagingQuery() => [_cfg, _keyword, _partyId, _sortKey, _sortAsc];
    try {
      final r = await readScopedPage<D>(
        page,
        query: pagingQuery(),
        currentQuery: pagingQuery,
        useCache: useCache,
        fetchPage: (target) =>
            config.listDocs(ref, target, keyword, partyId, sort, order),
      );
      if (!mounted || !_docsRequests.isCurrent(requestVersion)) return;
      await _cfg.loadPartyNames(
        ref,
        r.items
            .map(_cfg.partyIdOf)
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toSet(),
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
      _docsError = null;
      _hasUnknownQuantities = false;
    });
    try {
      final detail = await _cfg.loadDetail(ref, _cfg.docIdOf(d));
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      if (detail.sourceEnded) {
        setState(() {
          _loadingItems = false;
          _docsError = _l10n.docLinkSourceEnded;
        });
        return;
      }
      if (!_matchesSelectedParty(detail.partyId)) {
        setState(() => _loadingItems = false);
        context.appError('上游单据${_cfg.partyNoun}与表头${_cfg.partyNoun}不一致，已阻止引入');
        return;
      }
      if (detail.partyId?.isNotEmpty == true) {
        await _cfg.loadPartyNames(ref, {detail.partyId!});
        if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      }
      final goodsIds = detail.items
          .map(_cfg.itemFields.goodsId)
          .whereType<String>()
          .toSet();
      await _cfg.loadGoodsNames(ref, goodsIds);
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      // Unknown source facts are neither a zero nor proof of completed delivery.
      bool known(I item) =>
          _cfg.remainQtyText == null ||
          financeExactDecimalUnits(_cfg.remainQtyText!.call(item)) != null;
      final hasUnknown = detail.items.any((item) => !known(item));
      // 只显示已核实且有剩余可引量的明细；其他明细可继续正常引入。
      final visible = detail.items
          .where(
            (it) =>
                known(it) &&
                ((_cfg.remainQtyText == null
                        ? _cfg.remainQty(it) > 0
                        : (financeExactDecimalUnits(
                                    _cfg.remainQtyText!.call(it),
                                  ) ??
                                  BigInt.zero) >
                              BigInt.zero) ||
                    (financeExactDecimalUnits(
                              _cfg.remainGiftQtyText?.call(it),
                            ) ??
                            BigInt.zero) >
                        BigInt.zero),
          )
          .toList();
      final rows = visible.map((it) {
        final row = UtenDocLinkItemRow<I>(it);
        row.qty.text =
            _cfg.remainQtyText?.call(it) ?? _cfg.remainQty(it).toString();
        row.giftQty.text = _cfg.remainGiftQtyText?.call(it) ?? '0';
        return row;
      }).toList();
      _grid.replaceAll(rows);
      setState(() {
        _upDetail = detail;
        _hasUnknownQuantities = hasUnknown;
        _gridEmptyMessage = detail.items.isEmpty
            ? '该单据无明细'
            : visible.isEmpty
            ? hasUnknown
                  ? _l10n.docLinkUnknownRemaining
                  : '该单据明细已全部完成，无剩余可引入'
            : '该单据无明细';
        _loadingItems = false;
      });
    } catch (error) {
      if (!mounted || !_detailRequests.isCurrent(requestVersion)) return;
      setState(() {
        _loadingItems = false;
        _docsError = error is ApiException
            ? error.message
            : _l10n.docLinkDetailLoadFailed;
      });
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

  String? _giftQuantityError(UtenDocLinkItemRow<I> row) {
    final qty = financeExactDecimalUnits(row.qty.text);
    final gift = financeExactDecimalUnits(row.giftQty.text);
    if (qty == null ||
        gift == null ||
        qty.isNegative ||
        gift.isNegative ||
        qty + gift <= BigInt.zero) {
      return '收费量和赠品量须不小于0，实物合计须大于0，小数最多4位';
    }
    final maxQty = financeExactDecimalUnits(
      _cfg.remainQtyText?.call(row.item) ?? _cfg.remainQty(row.item).toString(),
    );
    final maxGift = financeExactDecimalUnits(
      _cfg.remainGiftQtyText?.call(row.item),
    );
    if (maxGift == null) return '来源赠品可用量尚未留存，请刷新后核对';
    if (!_cfg.allowGiftOverRemaining && gift > maxGift) return '赠品量不能超过来源可用赠品量';
    if (!_cfg.allowOverRemaining && (maxQty == null || qty > maxQty)) {
      return '收费量不能超过来源剩余量';
    }
    return null;
  }

  void _submit() {
    final out = <UtenDocLinkPickedItem>[];
    var hasQuantityError = false;
    for (final row in _grid.rows) {
      if (!row.selected) continue;
      final it = row.item;
      final goodsId = _cfg.itemFields.goodsId(it);
      if (goodsId == null) continue;
      final remaining = _cfg.remainQty(it);
      final error = _cfg.remainGiftQtyText == null
          ? validateLinkQuantity(
              row.qty.text,
              remaining: remaining,
              allowOverRemaining: _cfg.allowOverRemaining,
            )
          : _giftQuantityError(row);
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
          qtyText: row.qty.text.trim(),
          giftQtyText: _cfg.remainGiftQtyText == null
              ? null
              : row.giftQty.text.trim(),
          maxQtyText: _cfg.remainQtyText?.call(it),
          maxGiftQtyText: _cfg.allowGiftOverRemaining
              ? null
              : _cfg.remainGiftQtyText?.call(it),
          maxQty: remaining,
          price: _cfg.itemFields.price(it),
          upstreamItemId: _cfg.itemFields.upstreamItemId(it),
          colorId: _cfg.itemFields.colorId(it),
          unitId: _cfg.itemFields.unitId(it),
          unitRate: _cfg.itemFields.unitRate?.call(it),
          unitRateText: _cfg.itemFields.unitRateText?.call(it),
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
        sourceTerms: _upDetail?.sourceTerms,
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
    return UtenPanelHeader(
      title: title,
      onClose: () => Navigator.of(context).pop(),
      leading: inStep2
          ? TextButton.icon(
              onPressed: () => setState(() => _upDetail = null),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('重选单据'), // TODO(l10n): 补 arb
            )
          : null,
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
                child: UtenMasterPickerField<UtenDocLinkParty>(
                  label: _partyLocked
                      ? '${_cfg.partyNoun}(已锁定)'
                      : _cfg.partyNoun,
                  icon: Icons.filter_alt_outlined,
                  hint: _cfg.allPartiesLabel,
                  initialId: _partyId,
                  initialName: _partyId == null
                      ? null
                      : _cfg.partyName(names, _partyId),
                  enabled: !_partyLocked && !_readerInvalidated,
                  allowClear: !_partyLocked,
                  idOf: (party) => party.id,
                  nameOf: (party) => party.name,
                  onPick: () => _cfg.pickParty(context, ref),
                  onChanged: (value) {
                    if (_partyLocked) return;
                    setState(() => _partyId = value);
                    _loadDocs(1);
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: MasterDataTableView<D>(
            rowsController: _readViewportRows,
            expensiveRowMounts: false,
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
            onRetry: () => _loadDocs(_visibleReadPage),
            emptyMessage: _cfg.step1EmptyMessage,
            currentPage: _docPage?.page ?? 1,
            totalPages: _docPage?.totalPages ?? 1,
            paginationScope: (_keyword, _partyId),
            onPageChange: (p) => _loadDocs(p, useCache: true),
          ),
        ),
      ],
    );
  }

  // ---- Step2 ------------------------------------------------------------

  Widget _buildStep2(ThemeData theme, N names) {
    return Column(
      children: [
        if (_hasUnknownQuantities && _grid.rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: UtenFieldMessage.autofill(
              _l10n.docLinkUnknownRemaining,
              maxLines: 2,
            ),
          ),
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

  /// 表头筛选桶标签：空白与主档未解析的「—」不建桶（返回 null → 计入「未填」）。
  String? _bucketOrNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == '—') return null;
    return trimmed;
  }

  // 2026-09-11 全站表头快速筛选补齐：上游单据明细动辄几十上百行，货品/颜色/
  // 单位给表头快速筛选（视图级过滤，不动勾选与已填本次数量）。
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
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    // 2026-10-10 数量+单位口径：单位内联进「剩余/本次数量」两格，独立「单位」列
    // 删除（单位筛选桶随之退役）。
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'goods',
      label: '货品名称',
      width: 200,
      filterValueOf: (row) => _bucketOrNull(
        _cfg.goodsName(names, _cfg.itemFields.goodsId(row.item)),
      ),
      cellBuilder: (context, row) => UtenGoodsIdentityCell(
        name: _cfg.goodsName(names, _cfg.itemFields.goodsId(row.item)),
      ),
    ),
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      filterValueOf: (row) => _bucketOrNull(
        _cfg.goodsCode?.call(names, _cfg.itemFields.goodsId(row.item)),
      ),
      cellBuilder: (context, row) => UtenGoodsAttributeCell(
        _cfg.goodsCode?.call(names, _cfg.itemFields.goodsId(row.item)),
      ),
    ),
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'color',
      label: '颜色',
      width: 90,
      filterValueOf: (row) => _bucketOrNull(
        _cfg.colorName(names, _cfg.itemFields.colorId(row.item)),
      ),
      cellBuilder: (context, row) =>
          Text(_cfg.colorName(names, _cfg.itemFields.colorId(row.item))),
    ),
    ..._cfg.middleItemColumns(names),
    EditableGridColumn<UtenDocLinkItemRow<I>>(
      key: 'remainingQty',
      label: '剩余',
      width: 120,
      numeric: true,
      cellBuilder: (context, row) {
        final text = _cfg.remainQtyText == null
            ? formatLinkQuantity(_cfg.remainQty(row.item))
            : financeExactTrimmed(_cfg.remainQtyText!.call(row.item)) ?? '—';
        final unit = _cfg
            .unitName(names, _cfg.itemFields.unitId(row.item))
            .trim();
        return Text(unit.isEmpty ? text : '$text $unit');
      },
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
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              hintText: '本次数量',
              // 2026-10-10 数量+单位口径：单位随输入框尾部显示（空 = 不显示）。
              suffixText: _cfg
                  .unitName(names, _cfg.itemFields.unitId(row.item))
                  .trim(),
              error: utenFieldError(error),
            ),
          ),
          onChanged: (value) {
            if (row.qtyError.value != null) {
              row.qtyError.value = _cfg.remainGiftQtyText != null
                  ? _giftQuantityError(row)
                  : validateLinkQuantity(
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
