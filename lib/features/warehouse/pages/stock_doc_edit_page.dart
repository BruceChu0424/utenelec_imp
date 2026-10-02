// 仓库单据编辑页（新建/编辑）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 差异按 widget.docType 内联判断（仓库无独立 config 文件，与采购不同）：
// - 调拨 TRANSFER 显隐"调入仓"；领料 DRAW 显隐"装配班组"；盘点 CHECK 切换列定义（账面/实盘/盘盈亏）。
// - 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// - 日期统一 UtenDateField（outlined，与其它字段同款）。
// 明细改 Excel 表：货品/数量（+账面/实盘/盘盈亏 当 CHECK）+ 添加行/添加多行 + 行尾删除 + sticky 表头。
// 实称重量(ADR-135)：数量后是「实称重量」(可选，永不阻断保存)；盘点在实盘后加只读「账面重量」
// 与可选「实盘重量」(审核后账面重量按它定)。其它入库/产成品进仓与盘点的数量空着时可按称重
// 推算(黄框、qtyFromWeight)；出库类单据的 ⚖ 称重计数反推「秤上应显示多少」。
// 新建盘点可带 [StockCheckPrefill](库存分析「生成盘点单」经 GoRouter extra 传入)：预填仓库与
// 明细行(未保存)，账面数量/重量照常按仓库读取。
// 行级仓库(V787 2026-10-01「仓库不放表头，放表格里」，对齐销售出库 V631/委外批量拣货)：
// 其它/产成品出入库与领料把仓库挪进明细行内逐行选（同单可跨仓），库位号列改为可编辑、
// 按仓×货品记忆与主档通用库位预填；调拨(两腿)/盘点(账面)仍按表头仓。表头仓库字段随之只在
// 调拨/盘点显示；「本类型最近一张单的仓库」预填转为新行的默认行仓。
// 货品选择是多选(与新建销售同款)：选中的第一个填当前行，其余各自追加一行。
// 保存组装 body 调 create/update，成功后跳详情。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/measurement/weight_mass_units.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weigh_count_dialog.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/measurement/widgets/weight_sample_dialog.dart';
import '../../../shared/measurement/widgets/weight_totals.dart';
import '../../../shared/widgets/saved_document_fields.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';

import '../../../components/layout/uten_floating_action_group.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_edit_floating_actions.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/buttons/uten_drafts_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/platform_tables/platform_table_row.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/attachments/pending_attachment_controller.dart';
import '../../../shared/attachments/pending_attachment_flow.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/task_claim_badge.dart';
import '../../../shared/widgets/task_claim_handle.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/models/goods_node.dart' show GoodsListItem;
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../stock/repositories/stock_query_repository.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../models/stock_check_prefill.dart';
import '../models/stock_doc.dart';
import '../models/warehouse_form_draft_codec.dart';
import '../repositories/stock_doc_repository.dart';
import '../repositories/warehouse_place_suggestion_repository.dart';
import '../widgets/inbound_registration_widgets.dart';
import '../widgets/stock_grid_columns.dart';

class StockDocEditPage extends ConsumerStatefulWidget {
  const StockDocEditPage({
    super.key,
    required this.docType,
    this.id,
    this.checkPrefill,
  });
  final StockDocType docType;
  final String? id; // null=新建

  /// 新建盘点的预填(仓库 + 建议盘点的货品行)；null 时读路由 extra。
  final StockCheckPrefill? checkPrefill;

  @override
  ConsumerState<StockDocEditPage> createState() => _StockDocEditPageState();
}

/// 明细「选货品」滑窗(多选，与新建销售同款)。测试可替换成直接返回货品列表。
typedef StockGridGoodsPicker =
    Future<List<GoodsListItem>> Function(BuildContext context, WidgetRef ref);

/// 选货品范围：领料/退料=材料；产成品进/出仓=成品；调拨/其它出入库/盘点=全部。
UtenGoodsPickerScope stockDocPickerScope(StockDocType type) => switch (type) {
  StockDocType.draw || StockDocType.wdraw => UtenGoodsPickerScope.material,
  StockDocType.finishedIn ||
  StockDocType.finishedOut => UtenGoodsPickerScope.sellable,
  _ => UtenGoodsPickerScope.all,
};

final stockGridGoodsPickerProvider =
    Provider.family<StockGridGoodsPicker, StockDocType>((ref, type) {
      return (context, ref) => showUtenGoodsPickerMulti(
        context,
        ref,
        scope: stockDocPickerScope(type),
      );
    });

class _StockDocEditPageState extends ConsumerState<StockDocEditPage>
    with FormDraftMixin<StockDocEditPage> {
  bool get _isCheck => widget.docType == StockDocType.check;

  /// 行级仓库类型（V787）：出库 = 其它/产成品/领料，入库 = 其它/产成品。
  /// 调拨（调出/调入两腿）与盘点（账面按仓快照）仍走表头。
  bool get _usesLineWarehouse => switch (widget.docType) {
    StockDocType.otherIn ||
    StockDocType.otherOut ||
    StockDocType.finishedIn ||
    StockDocType.finishedOut ||
    StockDocType.draw => true,
    _ => false,
  };

  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();

  /// 领料单保存前暂存的出库凭证/照片（ADR-074：保存拿到真实 UUID 后逐个确认上传）。
  final _pendingFiles = PendingAttachmentController();

  /// 单据已创建但附件未全部上传：再点「保存」只重试附件，不重复建单。
  String? _createdDocId;
  final _assTeam = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();
  String? _warehouseId;
  String? _toWarehouseId;
  String? _departmentId; // 领料车间（仅 DRAW）

  final _grid = UtenEditableGridController<StockGridRow>();
  final _scrollCtl = ScrollController();

  /// 其它入库里按 0 成本进仓的货品 (ADR-131：回收料 = 水口料、破碎料)。
  ///
  /// 仓库单据明细没有金额列：这些货品保存时显式带单价 0、金额 0 (留空会变成
  /// 「成本未定」)，并在明细表上方提示。编辑已有单据时，原来就按 0 成本进仓的
  /// 明细也记在这里，保存时原样保持。
  final Set<String> _zeroCostGoodsIds = <String>{};

  bool get _isOtherIn => widget.docType == StockDocType.otherIn;

  /// 明细表 sticky 表头是否已置顶（页面滚动条门控：置顶前不显示，置顶后才显示）。
  final _gridPinned = ValueNotifier<bool>(false);
  bool _saving = false;
  bool _loadingCheckBooks = false;
  bool _loading = false;
  bool _loadedCanEdit = false;
  String? _editRestrictionReason;
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

  @override
  bool get formDraftEnabled => widget.id == null;
  @override
  bool get formDraftBusy => _saving;
  @override
  bool get formDraftCanReplaySubmission => _createdDocId != null;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.stockDocument.spec(
    title: '新建${widget.docType.label}',
    route: '/warehouse/${widget.docType.code}/new',
    draftKind: switch (widget.docType) {
      StockDocType.transfer => 'stockTransfer',
      StockDocType.check => 'stockCheck',
      _ => 'stockDocument',
    },
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _remark,
    _assTeam,
    _grid,
    _pendingFiles,
    for (final row in _grid.rows) ...[
      row.goodsNotifier,
      row.warehouseNotifier,
      row.place,
      row.qty,
      row.weight,
      row.bookQty,
      row.checkQty,
      row.countWeight,
      row.bookWeightKg,
    ],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'remark': _remark.text,
    'assTeam': _assTeam.text,
    'warehouseId': _warehouseId,
    'toWarehouseId': _toWarehouseId,
    'departmentId': _departmentId,
    'createdDocId': _createdDocId,
    'billDate': _billDate.toIso8601String(),
    'attachments': _pendingFiles.exportDraft(),
    'zeroCostGoodsIds': _zeroCostGoodsIds.toList(),
    'selected': draftGridSelection(_grid),
    'rows': [
      for (final row in _grid.rows)
        {
          'goods': draftGoods(row.goods),
          'unitRate': row.unitRate,
          'qty': row.qty.text,
          'weight': weightEntryDraft(row.weight, qty: row.qty),
          'bookQty': row.bookQty.text,
          'checkQty': row.checkQty.text,
          'countWeight': weightEntryDraft(row.countWeight, qty: row.checkQty),
          'bookWeightKg': row.bookWeightKg.value,
          'bookWeightEstimated': row.bookWeightEstimated,
          'upstreamItemId': row.upstreamItemId,
          'executionSegmentId': row.executionSegmentId,
          'executionSegmentSalesAllocationId':
              row.executionSegmentSalesAllocationId,
          'colorId': row.colorId,
          'unitId': row.unitId,
          'warehouseId': row.warehouseId,
          'place': row.place.text,
          'goodsCode': row.goodsCode,
          'goodsSeries': row.goodsSeries,
          'goodsStockPlace': row.goodsStockPlace,
          'colorName': row.colorName,
          'unitName': row.unitName,
        },
    ],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _remark.text = draftText(data, 'remark');
    _assTeam.text = draftText(data, 'assTeam');
    _warehouseId = data['warehouseId'] as String?;
    _toWarehouseId = data['toWarehouseId'] as String?;
    _departmentId = data['departmentId'] as String?;
    _createdDocId = data['createdDocId'] as String?;
    _billDate = DateTime.tryParse(draftText(data, 'billDate')) ?? _billDate;
    _pendingFiles.restoreDraft(draftMap(data['attachments']));
    _zeroCostGoodsIds
      ..clear()
      ..addAll([
        for (final id in (data['zeroCostGoodsIds'] as List?) ?? const [])
          if (id is String && id.isNotEmpty) id,
      ]);
    _grid.replaceAll([
      for (final item in draftMaps(data['rows']))
        (() {
          final row = StockGridRow(isCheck: _isCheck)
            ..goods = restoreDraftGoods(item['goods'])
            ..unitRate = (item['unitRate'] as num?)?.toDouble() ?? 1;
          row.upstreamItemId = item['upstreamItemId'] as String?;
          row.executionSegmentId = item['executionSegmentId'] as String?;
          row.executionSegmentSalesAllocationId =
              item['executionSegmentSalesAllocationId'] as String?;
          row.colorId = item['colorId'] as String?;
          row.unitId = item['unitId'] as String?;
          row.warehouseId = item['warehouseId'] as String?;
          row.place.text = draftText(item, 'place');
          row.goodsCode = item['goodsCode'] as String?;
          row.goodsSeries = item['goodsSeries'] as String?;
          row.goodsStockPlace = item['goodsStockPlace'] as String?;
          row.colorName = item['colorName'] as String?;
          row.unitName = item['unitName'] as String?;
          row.qty.text = draftText(item, 'qty');
          row.bookQty.text = draftText(item, 'bookQty');
          row.checkQty.text = draftText(item, 'checkQty');
          restoreWeightEntryDraft(row.weight, item['weight'], qty: row.qty);
          restoreWeightEntryDraft(
            row.countWeight,
            item['countWeight'],
            qty: row.checkQty,
          );
          row.bookWeightEstimated = item['bookWeightEstimated'] == true;
          row.bookWeightKg.value = (item['bookWeightKg'] as num?)?.toDouble();
          return row;
        })(),
    ]);
    restoreDraftGridSelection(_grid, data['selected']);
    _ensureWeightParams();
    if (mounted) setState(() {});
  }

  // ---- 实称重量(ADR-135) ----

  /// 页面级单重参数缓存(build 里 watch，离开页面释放)。
  WeightParamsCache get _weightCache => ref.read(weightParamsCacheProvider);

  /// 入库(其它入库/产成品进仓) / 出库(其它出库/产成品出仓/调拨/领料) / 盘点。
  WeightCaptureMode get _weightMode => switch (widget.docType) {
    StockDocType.check => WeightCaptureMode.count,
    StockDocType.otherIn ||
    StockDocType.finishedIn ||
    StockDocType.wdraw => WeightCaptureMode.inbound,
    StockDocType.transfer ||
    StockDocType.otherOut ||
    StockDocType.draw ||
    StockDocType.finishedOut => WeightCaptureMode.outbound,
  };

  /// 行生效仓库（V787）：行级仓库类型看行，其余看表头。
  String? _rowWarehouseOf(StockGridRow row) =>
      _usesLineWarehouse ? row.warehouseId ?? _warehouseId : _warehouseId;

  WeightParams? _paramsOf(StockGridRow row) => _weightCache.of(
    row.goods?.id,
    warehouseId: _rowWarehouseOf(row),
    colorId: row.colorId,
  );

  Iterable<WeightParamsLine> _weightParamsLines() => [
    for (final row in _grid.rows)
      if (row.goods case final goods?)
        WeightParamsLine(
          goodsId: goods.id,
          warehouseId: _rowWarehouseOf(row),
          colorId: row.colorId,
        ),
  ];

  void _ensureWeightParams() {
    if (!mounted) return;
    unawaited(_weightCache.ensure(_weightParamsLines()));
  }

  /// 货品或行单位按重量计时由数量精确换算(只读、不提交重量)；需要实称时为 null。
  double? _exactKg(StockGridRow row) => warehouseExactLineKg(
    lineQty: double.tryParse(row.activeQty.text.trim()),
    lineMassUnit:
        (ref.read(warehouseUnitMassUnitsProvider).valueOrNull ??
        const {})[row.unitId],
    unitRate: row.isCheck ? 1 : row.unitRate,
    params: _paramsOf(row),
  );

  /// 随明细提交的重量(千克)：精确换算行与没称的行不带。
  double? _sentKg(StockGridRow row) =>
      _exactKg(row) == null ? row.activeWeight.kg : null;

  String _goodsTitle(StockGridRow row) => warehouseWeighGoodsTitle(
    row.goods?.name ?? '',
    row.goodsCode,
    row.colorName,
  );

  /// 称重计数：入库与盘点「填入数量和重量」，出库反推「秤上应显示多少」只填重量。
  Future<void> _weighCount(BuildContext context, StockGridRow row) async {
    final goods = row.goods;
    if (goods == null) {
      context.appWarning('请先选择货品');
      return;
    }
    final outbound = _weightMode == WeightCaptureMode.outbound;
    await warehouseWeighCount(
      context,
      request: WeighCountRequest(
        mode: outbound ? WeighCountContext.outbound : WeighCountContext.count,
        goodsId: goods.id,
        goodsTitle: _goodsTitle(row),
        params: _paramsOf(row),
        warehouseId: _rowWarehouseOf(row),
        baseUnitName: row.isCheck || row.unitRate == 1 ? row.unitName : null,
        lineUnitName: row.unitName,
        unitRate: row.isCheck ? 1 : row.unitRate,
        currentQty: double.tryParse(row.activeQty.text.trim()),
        initialNetKg: row.activeWeight.kg,
        sampleRemark: _billNo.text.trim().isEmpty
            ? widget.docType.label
            : '${widget.docType.label} ${_billNo.text.trim()}',
      ),
      weight: row.activeWeight,
      qty: outbound ? null : row.activeQty,
      cache: _weightCache,
      refetch: _weightParamsLines(),
    );
  }

  /// 称样校准(行右键)：保存后刷新该货品单重。
  Future<void> _sampleCalibrate(StockGridRow row) async {
    final goods = row.goods;
    if (goods == null) return;
    final detail = await showWeightSampleDialog(
      context,
      goodsId: goods.id,
      goodsTitle: _goodsTitle(row),
      baseUnitName: row.isCheck || row.unitRate == 1 ? row.unitName : null,
      warehouseId: _rowWarehouseOf(row),
      params: _paramsOf(row),
      remark: widget.docType.label,
    );
    if (detail == null || !mounted) return;
    _weightCache.invalidateGoods(goods.id);
    _ensureWeightParams();
  }

  /// 行右键的称重条目(只对单行、已选货品)。
  List<UtenContextMenuEntry> _rowWeightMenu(
    BuildContext context,
    List<StockGridRow> selected,
  ) {
    if (selected.length != 1 || selected.single.goods == null) return const [];
    final row = selected.single;
    return weightRowMenuEntries(
      onWeighCount: () => _weighCount(context, row),
      onSample: () => _sampleCalibrate(row),
      sampleEnabled: ref.read(weightSampleAllowedProvider),
    );
  }

  /// 新建盘点的预填：构造参数优先，否则读路由 extra(库存分析「生成盘点单」)。
  StockCheckPrefill? _routeCheckPrefill() {
    if (!_isCheck || widget.id != null) return null;
    final direct = widget.checkPrefill;
    if (direct != null) return direct;
    final extra = goRouterPageStateOrNull(context)?.extra;
    return extra is StockCheckPrefill ? extra : null;
  }

  /// 按预填建明细行(未保存)：货品名称/编号/单位按主档带出，账面随后按仓库读取。
  Future<void> _applyCheckPrefill(StockCheckPrefill prefill) async {
    final names = ref.read(masterNameServiceProvider);
    final selectable = WarehouseSelection(
      names.warehouseHierarchy,
    ).selectableIds;
    if (selectable.contains(prefill.warehouseId)) {
      _warehouseId = prefill.warehouseId;
    }
    final goodsIds = {for (final line in prefill.lines) line.goodsId};
    await names.loadGoodsNamesWithCodes(goodsIds);
    if (!mounted) return;
    final rows = <StockGridRow>[];
    final seen = <String>{};
    for (final line in prefill.lines) {
      // 同一货品同一颜色只盘一行。
      if (!seen.add('${line.goodsId}|${line.colorId ?? ''}')) continue;
      final info = names.goodsInfo(line.goodsId);
      final row = StockGridRow(isCheck: true)
        ..goods = names.goodsOptionOf(line.goodsId)
        ..colorId = line.colorId
        ..unitId = info?.unitId
        ..goodsCode = info?.code
        ..goodsSeries = info?.series
        ..goodsStockPlace = info?.stockPlace
        ..colorName = line.colorId == null ? null : names.color(line.colorId)
        ..unitName = info?.unitId == null ? null : names.unit(info!.unitId);
      rows.add(row);
    }
    if (rows.isNotEmpty) _grid.replaceAll(rows);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _gridPinned.dispose();
    _billNo.dispose();
    _remark.dispose();
    _pendingFiles.dispose();
    _assTeam.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    if (!mounted) return;
    // 库存分析「生成盘点单」：预填仓库与明细行(未保存)，保存前照常读账面。
    final checkPrefill = _routeCheckPrefill();
    if (checkPrefill != null) await _applyCheckPrefill(checkPrefill);
    if (widget.id == null && _warehouseId == null) {
      // 仓库预填「本类型最近一张单的仓库」（与销售 D1 同款），减少手选。
      try {
        final last = await ref
            .read(stockDocRepositoryProvider(widget.docType))
            .list(size: 1);
        if (last.items.isNotEmpty &&
            WarehouseSelection(
              ref.read(masterNameServiceProvider).warehouseHierarchy,
            ).selectableIds.contains(last.items.first.warehouseId)) {
          _warehouseId = last.items.first.warehouseId;
        }
      } catch (_) {
        /* 预填失败静默，用户手选 */
      }
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(stockDocRepositoryProvider(widget.docType))
            .detail(widget.id!);
        final writable =
            !d.productionLinked &&
            d.canEdit &&
            await loadDocumentOwnerCanWrite(
              ref,
              DocumentDataScope.stockDocument,
              d.makerId,
            );
        if (!mounted) return;
        if (!writable) {
          context.appWarning(
            d.restrictionReason ?? documentScopeReadOnlyMessage,
            force: true,
          );
          context.replace(
            RoutePath.stockDocDetail(widget.docType.code, widget.id!),
          );
          return;
        }
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(masterNameServiceProvider).loadGoodsDetails(goodsIds);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        _assTeam.text = d.assTeam ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _warehouseId = d.warehouseId;
        _toWarehouseId = d.toWarehouseId;
        _departmentId = d.departmentId;
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        _loadedCanEdit = d.canEdit;
        _editRestrictionReason = d.restrictionReason;
        final rows = <StockGridRow>[];
        for (final it in d.items) {
          // 原来就按 0 成本进仓的其它入库明细 (回收料)：保存时保持 0 成本。
          if (_isOtherIn &&
              it.goodsId != null &&
              it.amountLocal != null &&
              it.amountLocal == 0) {
            _zeroCostGoodsIds.add(it.goodsId!);
          }
          final row = StockGridRow(isCheck: _isCheck)
            ..platformFields.sourceRecordId = it.id
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(masterNameServiceProvider).goods(it.goodsId),
                  );
          row
            ..upstreamItemId = it.upstreamItemId
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..unitRate = it.unitRate ?? 1
            // 行级仓库类型回显行仓（空沿用表头）；调拨/盘点行不带仓。
            ..warehouseId = _usesLineWarehouse
                ? it.warehouseId ?? d.warehouseId
                : null
            ..executionSegmentId = it.executionSegmentId
            ..executionSegmentSalesAllocationId =
                it.executionSegmentSalesAllocationId;
          if (_usesLineWarehouse) {
            row.place.text = it.place ?? '';
          }
          // 主档展示列：编号/系列/库位号（lookup 详情）+ 颜色/单位名（字典）。
          final info = ref
              .read(masterNameServiceProvider)
              .goodsInfo(it.goodsId);
          row
            ..goodsCode = info?.code
            ..goodsSeries = info?.series
            ..goodsStockPlace = info?.stockPlace
            ..colorName = ref.read(masterNameServiceProvider).color(it.colorId)
            ..unitName = ref.read(masterNameServiceProvider).unit(it.unitId);
          if (_isCheck) {
            // 盘点：账面 = items.qty，实盘 = items.countQty；账面重量 = 保存时快照，
            // 实盘重量 = items.countWeight(按称重推算的实盘数量保留黄框)。
            row.bookQty.text = it.qty?.toString() ?? '';
            row.bookWeightKg.value = it.bookWeight;
            _restoreSavedWeight(
              row.countWeight,
              row.checkQty,
              it.countQty?.toString() ?? '',
              it.countWeight,
              it.qtyFromWeight,
            );
          } else {
            _restoreSavedWeight(
              row.weight,
              row.qty,
              it.qty?.toString() ?? '',
              it.weight,
              it.qtyFromWeight,
            );
          }
          rows.add(row);
        }
        _grid.replaceAll(rows);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty) {
      _grid.addRow(StockGridRow(isCheck: _isCheck));
    }
    _ensureWeightParams();
    // 预填的盘点行先读账面，草稿基线里就是读好账面的样子(不算用户改动)。
    if (checkPrefill != null && mounted) await _refreshCheckBooks();
    if (mounted) {
      setState(() => _loading = false);
      await initializeFormDraft();
    }
  }

  /// 回显已保存行的数量与重量：数量是按称重折算的保留黄框(说明来源)。
  void _restoreSavedWeight(
    WeightEntryController weight,
    UtenAutofillTextController qty,
    String qtyText,
    double? kg,
    bool qtyFromWeight,
  ) {
    qty.text = qtyText;
    weight.setKg(kg, qtyFromWeight: qtyFromWeight, userEdited: kg != null);
    if (qtyFromWeight && qtyText.isNotEmpty) {
      qty.setAutomaticText(qtyText);
      weight.markQtyDerived(qtyText, note: '保存时按称重折算的数量');
    }
  }

  Future<void> _pickGoods(StockGridRow row) async {
    if (_isCheck && _warehouseId == null) {
      context.appWarning('请先选择盘点仓库，再添加货品');
      return;
    }
    // 多选（与新建销售同款）：选中的第一个填当前行，其余各自追加一行——
    // 一次选完不用逐个重复「加行→选货品」。
    final picked = await ref.read(stockGridGoodsPickerProvider(widget.docType))(
      context,
      ref,
    );
    if (!mounted || picked.isEmpty) return;
    final filled = <StockGridRow>[];
    void fill(StockGridRow target, GoodsListItem g) {
      target
        ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
        ..colorId = g.colorId
        ..unitId = g.unitId
        ..unitRate = 1
        ..goodsCode = g.code
        ..goodsSeries = g.series
        ..colorName = g.colorName
        ..unitName = g.unitName;
      // 其它入库的回收料 (水口料、破碎料，ADR-131)：金额预填 0，按 0 成本进仓。
      if (_isOtherIn && g.recycledMaterial) {
        _zeroCostGoodsIds.add(g.id);
        context.appInfo('「${g.name ?? g.code ?? ''}」是回收料，水口料按 0 成本进仓');
      }
      // 行级仓库（V787）：新选的行带上默认行仓（本类型最近一张单的仓库/用户刚改的仓）。
      if (_usesLineWarehouse && target.warehouseId == null) {
        target.warehouseId = _warehouseId;
      }
      filled.add(target);
    }

    fill(row, picked.first);
    final extraRows = <StockGridRow>[];
    if (picked.length > 1) {
      for (final g in picked.skip(1)) {
        final r = StockGridRow(isCheck: _isCheck);
        fill(r, g);
        extraRows.add(r);
      }
      _grid.addRows(extraRows);
    }
    // 主档展示列：编号/系列已在选项里；库位号不在选择器返回里，按需补全详情
    // （名称缓存命中也会拉取）。
    await ref.read(masterNameServiceProvider).loadGoodsDetails([
      for (final g in picked) g.id,
    ]);
    if (!mounted) return;
    for (final target in filled) {
      final id = target.goods?.id;
      if (id == null) continue;
      target.goodsStockPlace = ref
          .read(masterNameServiceProvider)
          .goodsInfo(id)
          ?.stockPlace;
    }
    if (mounted) setState(() {});
    _ensureWeightParams();
    await _refreshPlaceSuggestions();
    if (_isCheck) {
      for (final target in filled) {
        await _loadCheckBookQty(target);
      }
    }
  }

  /// 行级库位建议（V787「库位号要有记忆」）：按行仓库分组建议（仓库×货品×颜色的
  /// 历史入库记忆 → 货品资料通用库位），只预填还没手填的行；失败静默（可手填，不拦保存）。
  Future<void> _refreshPlaceSuggestions() async {
    if (!_usesLineWarehouse) return;
    final byWarehouse = <String, List<StockGridRow>>{};
    for (final row in _grid.rows) {
      final goods = row.goods;
      final warehouseId = row.warehouseId;
      if (goods == null || warehouseId == null) continue;
      byWarehouse.putIfAbsent(warehouseId, () => []).add(row);
    }
    for (final entry in byWarehouse.entries) {
      try {
        final suggestions = await ref
            .read(warehousePlaceSuggestionRepositoryProvider)
            .suggest(
              warehouseId: entry.key,
              goods: [
                for (final row in entry.value)
                  (goodsId: row.goods!.id, colorId: row.colorId),
              ],
            );
        if (!mounted) return;
        for (final row in entry.value) {
          // 只填空格：用户已手填（或建议先到）的不覆盖。
          if (row.place.text.trim().isNotEmpty) continue;
          final suggestion =
              suggestions[inboundGoodsColorKey(row.goods!.id, row.colorId)];
          final place = suggestion?.place;
          if (place != null && place.isNotEmpty) row.place.text = place;
        }
        if (mounted) setState(() {});
      } catch (_) {
        // 建议失败不拦录单：库位可直接手填。
      }
    }
  }

  /// 行仓库变化（V787）：记住本次选择作为后续新行默认仓，并刷新该行的库位建议与单重参数。
  void _onRowWarehouseChanged(StockGridRow row) {
    if (_usesLineWarehouse) _warehouseId = row.warehouseId;
    setState(() {});
    _ensureWeightParams();
    unawaited(_refreshPlaceSuggestions());
  }

  Future<void> _loadCheckBookQty(StockGridRow row) async {
    final warehouseId = _warehouseId;
    final goods = row.goods;
    final colorId = row.colorId;
    if (!_isCheck || warehouseId == null || goods == null) {
      row.bookQty.clear();
      row.bookWeightKg.value = null;
      return;
    }
    try {
      final result = await ref
          .read(stockQueryRepositoryProvider)
          .balances(size: 100, warehouseId: warehouseId, goodsId: goods.id);
      if (!mounted ||
          !_grid.rows.contains(row) ||
          _warehouseId != warehouseId ||
          row.goods?.id != goods.id ||
          row.colorId != colorId) {
        return;
      }
      // 没有余额行 = 账面 0 个、0 重量。
      var qty = 0.0;
      double? weightKg = 0;
      var estimated = false;
      var found = false;
      for (final balance in result.items) {
        if (balance.colorId == row.colorId) {
          qty = balance.qty ?? 0;
          weightKg = balance.weight;
          estimated = balance.weightEstimated;
          found = true;
          break;
        }
      }
      // 历史主档颜色缺失但该货品在目标仓只有一条余额时，沿用该余额颜色，避免误读为零。
      if (!found && row.colorId == null && result.items.length == 1) {
        final balance = result.items.single;
        row.colorId = balance.colorId;
        qty = balance.qty ?? 0;
        weightKg = balance.weight;
        estimated = balance.weightEstimated;
      }
      row.bookQty.text = _qtyText(qty);
      // 账面重量只作核对展示；保存时服务端按锁定的余额重新快照。
      row.bookWeightEstimated = estimated;
      row.bookWeightKg.value = weightKg;
      _ensureWeightParams();
    } catch (error) {
      if (!mounted ||
          !_grid.rows.contains(row) ||
          _warehouseId != warehouseId ||
          row.goods?.id != goods.id ||
          row.colorId != colorId) {
        return;
      }
      row.bookQty.clear();
      row.bookWeightKg.value = null;
      if (mounted) {
        context.appApiError(error, fallback: '读取账面库存失败，请重试');
      }
    }
  }

  Future<void> _refreshCheckBooks() async {
    if (!_isCheck) return;
    if (mounted) setState(() => _loadingCheckBooks = true);
    try {
      for (final row in _grid.rows.where((row) => row.goods != null)) {
        await _loadCheckBookQty(row);
      }
    } finally {
      if (mounted) setState(() => _loadingCheckBooks = false);
    }
  }

  String _qtyText(double value) {
    final fixed = value.toStringAsFixed(4);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  /// 只有领料单接了 STOCK_DOCUMENT 附件策略的可见入口（详情页「出库凭证/照片」常驻区）；
  /// 其它仓库单据详情没有附件区，编辑页不提供上传以免文件无处回看。
  bool get _hasAttachmentArea => widget.docType == StockDocType.draw;

  /// 可管口径与服务端 StockDocumentAttachmentAccessPolicy 草稿态一致：审核∩出库
  ///（出库即审核）；组件内再叠加 attachment:upload。
  bool get _canManageAttachments {
    final perms = ref.read(currentPermissionsProvider);
    return perms.contains(Perm.stockDocApprove) &&
        perms.contains(Perm.stockDocIssue);
  }

  /// 把暂存附件上传到刚创建的领料单；全部成功才跳详情，失败项留在页面供重试。
  Future<void> _finishCreatedDoc(String createdId) async {
    setState(() => _saving = true);
    try {
      final ok = await flushPendingAttachments(
        context,
        ref,
        _pendingFiles,
        ownerType: 'STOCK_DOCUMENT',
        ownerIds: [createdId],
      );
      if (!mounted || !ok) return;
      await completeFormDraft();
      if (!mounted) return;
      context.replace(RoutePath.stockDocDetail(widget.docType.code, createdId));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_createdDocId case final createdId?) {
      await _finishCreatedDoc(createdId);
      return;
    }
    if (widget.id != null && !_loadedCanEdit) {
      return context.appError(_editRestrictionReason ?? '该单据不可通过仓库通用页面编辑');
    }

    final rows = _grid.rows;
    if (!_usesLineWarehouse && _warehouseId == null) {
      return context.appError('请选择仓库');
    }
    // 行级仓库（V787）：整表扫完一起报，多行时不用改一行存一次才看到下一行。
    if (_usesLineWarehouse) {
      final missingWarehouse = <String>[];
      for (var index = 0; index < rows.length; index++) {
        final r = rows[index];
        if (r.goods == null) continue;
        if (r.warehouseId == null) {
          missingWarehouse.add(
            '第 ${index + 1} 行（${r.goods!.name ?? r.goods!.code ?? ''}）',
          );
        }
      }
      if (missingWarehouse.isNotEmpty) {
        return context.appError(
          '${missingWarehouse.join('、')}未选择仓库，请在表格的仓库列逐行选择',
        );
      }
    }
    if (widget.docType == StockDocType.transfer && _toWarehouseId == null) {
      return context.appError('请选择调入仓');
    }
    if (_isCheck && _loadingCheckBooks) {
      return context.appInfo('账面库存仍在读取，请稍候');
    }
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      return context.appError('请至少添加一条明细');
    }
    // 行级仓库类型的表头仓 = 首条明细的行仓（列表/汇总列仍需一个仓展示）。
    final String? headerWarehouseId = _usesLineWarehouse
        ? rows
              .firstWhere((r) => r.goods != null, orElse: () => rows.first)
              .warehouseId
        : _warehouseId;
    final items = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final m = <String, dynamic>{
        'goodsId': r.goods!.id,
        ...platformRowPayload(r),
      };
      if (r.colorId != null) m['colorId'] = r.colorId;
      if (r.unitId != null) m['unitId'] = r.unitId;
      m['unitRate'] = r.unitRate;
      if (_usesLineWarehouse) {
        m['warehouseId'] = r.warehouseId;
        final place = r.place.text.trim();
        if (place.isNotEmpty) m['place'] = place;
      }
      // 重量(ADR-135)：可选，千克 4 位；看不懂的输入拦下，没称不带，货品按重量计不带。
      if (r.activeWeight.hasError) {
        return context.appError(
          '${r.goods!.name} 的${_isCheck ? '实盘重量' : '实称重量'}看不懂，'
          '例：850g、1.2t、3斤、12',
        );
      }
      final sentKg = _sentKg(r);
      if (_isCheck) {
        final bookQty = double.tryParse(r.bookQty.text);
        if (bookQty == null) {
          return context.appError('${r.goods!.name} 的账面库存尚未读取');
        }
        final countQty = double.tryParse(r.checkQty.text.trim());
        if (countQty == null || countQty < 0) {
          return context.appError('${r.goods!.name} 的实盘数量必须填写且不能小于 0');
        }
        if (countQty == 0 && sentKg != null) {
          return context.appError('${r.goods!.name} 的实盘数量为 0，不能再填实盘重量');
        }
        m['qty'] = bookQty; // 账面写入 items.qty
        m['countQty'] = countQty;
        // 仅作前端预览；后端会按权威账面快照重新计算盈亏。
        m['surplusQty'] = countQty - bookQty;
        if (sentKg != null) m['countWeight'] = sentKg;
      } else {
        m['qty'] = double.tryParse(r.qty.text) ?? 0;
        if (sentKg != null) m['weight'] = sentKg;
      }
      // 回收料按 0 成本进仓：显式单价 0、金额 0 (不留空，留空是「成本未定」)。
      if (_isOtherIn && _zeroCostGoodsIds.contains(r.goods!.id)) {
        m['price'] = 0;
        m['amountLocal'] = 0;
      }

      if (r.activeWeight.qtyFromWeight) m['qtyFromWeight'] = true;
      if (r.upstreamItemId != null) m['upstreamItemId'] = r.upstreamItemId;
      if (r.executionSegmentId != null) {
        m['executionSegmentId'] = r.executionSegmentId;
      }
      if (r.executionSegmentSalesAllocationId != null) {
        m['executionSegmentSalesAllocationId'] =
            r.executionSegmentSalesAllocationId;
      }
      items.add(m);
    }
    if (items.isEmpty) {
      return context.appError('请至少添加一条明细');
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'docType': widget.docType.code,
      'billDate': _fmt(_billDate),
      'warehouseId': headerWarehouseId,
      if (widget.docType == StockDocType.transfer)
        'toWarehouseId': _toWarehouseId,
      if (widget.docType == StockDocType.draw) ...{
        'assTeam': _assTeam.text.trim().isEmpty ? null : _assTeam.text.trim(),
        'departmentId': _departmentId,
      },
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      'items': items,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      final d = widget.id == null
          ? await runFormDraftSubmission(() => repo.create(body))
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      bumpListRefresh(ref, widget.docType.refreshKey);
      if (widget.id == null && _hasAttachmentArea && _pendingFiles.isNotEmpty) {
        // 新建领料单：先拿到真实 UUID，再把保存前暂存的凭证逐个确认上传。
        setState(() => _createdDocId = d.id);
        await checkpointFormDraftAfterCreation();
        await _finishCreatedDoc(d.id);
        return;
      }
      await completeFormDraft();
      if (!mounted) return;
      context.replace(RoutePath.stockDocDetail(widget.docType.code, d.id));
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '保存失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 明细里按 0 成本进仓的货品名 (去重，保持表内顺序)。
  List<String> get _zeroCostNames {
    final names = <String>[];
    for (final row in _grid.rows) {
      final goods = row.goods;
      if (goods == null || !_zeroCostGoodsIds.contains(goods.id)) continue;
      final name = goods.name ?? goods.code ?? '';
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    return names;
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 新建态 AppBar 右上角「草稿(N)」入口。
  ///
  /// 仓库单据 8 种类型共用一张 stock_documents，跨模块草稿计数只有一个
  /// stockDocument 桶，因此数字是整模块合计、而落点列表只列当前类型；
  /// 用 countScopeNote 在 tooltip 里说明，避免用户以为列表漏单。
  List<Widget>? get _draftsAction {
    if (widget.id != null) return null;
    return [
      UtenDraftsButton(
        kind: DraftDocKind.stockDocument,
        listLocation: '/warehouse/${widget.docType.code}',
        countScopeNote: '全部仓库单据合计',
      ),
    ];
  }

  Widget _savedFields(Widget child) =>
      SavedDocumentFields(locked: _createdDocId != null, child: child);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    // 单重参数缓存与单位字典随页面存活；录入/显示单位是用户偏好。
    ref.watch(weightParamsCacheProvider);
    ref.watch(warehouseUnitMassUnitsProvider);
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: widget.id == null
              ? '新建${widget.docType.label}'
              : '编辑${widget.docType.label}',
          showBackButton: true,
          actions: _draftsAction,
        ),
        body: SafeArea(
          child: Stack(
            children: [
              _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : UtenGridPageScrollbar(
                      pinned: _gridPinned,
                      controller: _scrollCtl,
                      // 滚动条贴屏幕右缘（2026-09-15）：包装在内容容器之外，右缘窄条
                      // 恒在屏幕最右，不随限宽容器/列宽漂移。
                      child: UtenContentContainer(
                        child: ListView(
                          controller: _scrollCtl,
                          // 底部多留一屏悬浮按钮的高度，最后一行明细不被「取消/保存」压住。
                          padding: const EdgeInsets.fromLTRB(
                            UtenSpacing.s12,
                            UtenSpacing.s12,
                            UtenSpacing.s12,
                            UtenFloatingActionGroup.scrollClearance,
                          ),
                          children: [
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(UtenSpacing.s12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _savedFields(
                                      UtenFormGrid(
                                        children: [
                                          // 单据号：系统自动生成，只读显示。
                                          TextFormField(
                                            errorBuilder:
                                                utenTextFieldErrorBuilder,
                                            readOnly: true,
                                            controller: _billNo,
                                            decoration: UtenInputDecoration(
                                              InputDecoration(
                                                labelText: '单据号',
                                                hintText: _billNo.text.isEmpty
                                                    ? '保存后自动生成'
                                                    : null,
                                                filled: _billNo.text.isEmpty,
                                                suffixIcon: _billNo.text.isEmpty
                                                    ? const Icon(
                                                        Icons
                                                            .autorenew_outlined,
                                                        size: 18,
                                                      )
                                                    : const Icon(
                                                        Icons.lock_outline,
                                                        size: 16,
                                                      ),
                                              ),
                                            ),
                                          ),
                                          // 制单员/制单时间：服务端权威，只读展示（责任制）。
                                          ...utenMakerAuditCells(
                                            ref,
                                            makerName: _makerName,
                                            createdAt: _createdAt,
                                          ),
                                          UtenDateField(
                                            label: '单据日期',
                                            required: true,
                                            value: _billDate,
                                            onChanged: (d) =>
                                                setState(() => _billDate = d),
                                          ),
                                          // V476：仓库下拉带主/子层级（父仓置灰分组，单据落具体仓）。
                                          // V787 行级仓库类型不再放表头——仓库在明细
                                          // 表格里逐行选（同单可跨仓），此处只剩调拨/盘点。
                                          if (!_usesLineWarehouse)
                                            UtenDropdownField(
                                              label: '仓库',
                                              value: _warehouseId,
                                              required: true,
                                              items: warehouseHierarchyItems(
                                                names.warehouseHierarchy,
                                                currentValue: _warehouseId,
                                              ),
                                              onChanged: (v) {
                                                setState(
                                                  () => _warehouseId = v,
                                                );
                                                _ensureWeightParams();
                                                if (_isCheck) {
                                                  unawaited(
                                                    _refreshCheckBooks(),
                                                  );
                                                }
                                              },
                                            ),
                                          if (widget.docType ==
                                              StockDocType.transfer)
                                            UtenDropdownField(
                                              label: '调入仓',
                                              value: _toWarehouseId,
                                              required: true,
                                              items: warehouseHierarchyItems(
                                                names.warehouseHierarchy,
                                                currentValue: _toWarehouseId,
                                              ),
                                              onChanged: (v) => setState(
                                                () => _toWarehouseId = v,
                                              ),
                                            ),
                                          if (widget.docType ==
                                              StockDocType.draw) ...[
                                            _dd(
                                              '领料车间',
                                              _departmentId,
                                              names.departmentEntries,
                                              (v) => setState(
                                                () => _departmentId = v,
                                              ),
                                            ),
                                            TextField(
                                              controller: _assTeam,
                                              decoration: const InputDecoration(
                                                labelText: '装配班组',
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: UtenSpacing.s12),
                                    TextField(
                                      controller: _remark,
                                      decoration: const InputDecoration(
                                        labelText: '备注',
                                      ),
                                      maxLines: 2,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                            // 出库凭证/照片（2026-09-10 G4「其他有上传处同样」）：编辑态直接挂
                            // 已保存 UUID；新建态先暂存，保存成功后逐个确认上传。
                            if (_hasAttachmentArea) ...[
                              if (widget.id != null)
                                BusinessAttachmentSection(
                                  key: const Key('stock-doc-edit-attachments'),
                                  ownerType: 'STOCK_DOCUMENT',
                                  ownerId: widget.id!,
                                  canView: ref
                                      .watch(currentPermissionsProvider)
                                      .contains(Perm.stockDocView),
                                  canManage: _canManageAttachments,
                                  title: '出库凭证/照片',
                                  categories: const ['出库凭证', '照片', '其他'],
                                )
                              else ...[
                                if (_createdDocId != null)
                                  PendingAttachmentRetryNotice(
                                    documentLabel: '领料单',
                                    controller: _pendingFiles,
                                  ),
                                BusinessAttachmentSection.draft(
                                  key: const ValueKey(
                                    'stock-doc-draft-attachments',
                                  ),
                                  controller: _pendingFiles,
                                  canManage: _canManageAttachments,
                                  title: '出库凭证/照片',
                                  categories: const ['出库凭证', '照片', '其他'],
                                ),
                              ],
                              const SizedBox(height: UtenSpacing.s12),
                            ],
                            if (_isCheck) ...[
                              Text(
                                '账面数量由系统按所选仓库读取，保存后形成盘点快照。'
                                '审核前如发生其它出入库，系统会拒绝用旧快照修正库存，'
                                '请刷新账面并重新核对实盘数。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                            ],
                            // 其它入库含回收料 (ADR-131)：提示这些货品按 0 成本进仓。
                            if (_isOtherIn && _zeroCostNames.isNotEmpty) ...[
                              Container(
                                key: const Key('stock-doc-zero-cost-hint'),
                                width: double.infinity,
                                padding: const EdgeInsets.all(UtenSpacing.s8),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(
                                    UtenRadius.control,
                                  ),
                                ),
                                child: Text(
                                  '水口料按 0 成本进仓：${_zeroCostNames.join('、')}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                            ],
                            // 「明细 (N)」标题行 2026-09-11 撤除（全站同改）：本页无右侧入口，整行删除。
                            _savedFields(
                              UtenEditableGrid<StockGridRow>(
                                columnEditingEnabled:
                                    !_loading &&
                                    !_saving &&
                                    _createdDocId == null &&
                                    (widget.id == null || _loadedCanEdit),
                                tableKey:
                                    'warehouse.${widget.docType.name}.items',
                                controller: _grid,
                                stickyHeaderPinned: _gridPinned,
                                columns: stockGridColumns(
                                  _pickGoods,
                                  isCheck: _isCheck,
                                  // V787 行级仓库：出库/入库类单据在表格里逐行选仓。
                                  warehouse: _usesLineWarehouse
                                      ? StockGridWarehouseWiring(
                                          entries: names.warehouseHierarchy,
                                          label: switch (widget.docType) {
                                            StockDocType.otherIn ||
                                            StockDocType.finishedIn => '入库仓',
                                            _ => '发出仓',
                                          },
                                          onWarehouseChanged:
                                              _onRowWarehouseChanged,
                                        )
                                      : null,
                                  weight: StockGridWeightWiring(
                                    entryUnit: weightUnits.entry,
                                    mode: _weightMode,
                                    paramsOf: _paramsOf,
                                    paramsListenable: _weightCache,
                                    exactKgOf: _exactKg,
                                    onWeighCount: _weighCount,
                                    display: weightUnits.display,
                                  ),
                                ),
                                createBlankRow: () =>
                                    StockGridRow(isCheck: _isCheck),
                                cloneRow: (r) => r.clone(),
                                // 「称重单位: 千克▾」：录入单位是用户级偏好。
                                toolbarActions: const [WeightEntryUnitButton()],
                                rowMenuExtraBuilder: _rowWeightMenu,
                                footer: _gridTotals(weightUnits.display),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
              // 保存/上传凭证网络段的全屏加载遮罩。
              if (_saving)
                UtenBusyOverlay(
                  title: widget.id == null ? '正在创建单据' : '正在保存单据',
                  description: '正在写入${widget.docType.label}，请勿重复提交或离开本页。',
                ),
            ],
          ),
        ),
        // 底部固定操作条 2026-09-11 收口为右下角悬浮；合计不再重复（明细表下方已有）。
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _loading ? null : _floatingActions(theme),
      ),
    );
  }

  /// 明细表尾：「总行数 N 行 · 数量(按单位分组) · 实称 125.3 kg (未称 3 行) · 称重偏差 N 行」；
  /// 盘点口径为实盘数量与实盘重量。行集变化、逐格输入与单重参数到达都即时刷新。
  Widget _gridTotals(WeightDisplay display) => ListenableBuilder(
    listenable: _grid,
    builder: (context, _) {
      final rows = _grid.rows
          .where((row) => row.goods != null)
          .toList(growable: false);
      return ListenableBuilder(
        listenable: Listenable.merge([
          _weightCache,
          for (final row in rows) ...[row.activeQty, row.activeWeight],
        ]),
        builder: (context, _) => UtenTotalsSummaryBar(
          key: const Key('stock-doc-edit-totals'),
          density: true,
          rowCount: rows.length,
          entries: [
            utenQuantityTotalEntry(
              rows.map(
                (row) => MeasuredAmount(
                  value: double.tryParse(row.activeQty.text.trim()) ?? 0,
                  unitId: row.unitId,
                  unitName: row.unitName,
                ),
              ),
              label: _isCheck ? '实盘' : '数量',
            ),
            ...weightTotalEntries(
              warehouseWeightTotals<StockGridRow>(
                rows,
                weightOf: (row) => row.activeWeight,
                exactKgOf: _exactKg,
                paramsOf: _paramsOf,
                qtyBaseOf: (row) => row.qtyBase,
                mode: _weightMode,
              ),
              label: _isCheck ? '实盘重量' : '实称',
              display: display,
            ),
          ],
        ),
      );
    },
  );

  /// 右下角悬浮「取消 / 保存」。
  ///
  /// 编辑态外面仍套 TaskClaimHandle：他人正在编辑同一单据时禁用保存，
  /// 「XX 处理中」提示改排在取消左侧（原来挂在保存按钮上方，悬浮组里没有上下位）。
  /// 账面库存读取中沿用「保存中」的转圈态，让用户知道现在点不动是在等数据。
  Widget _floatingActions(ThemeData theme) {
    final busy = _saving || _loadingCheckBooks;
    void cancel() => popOrBackTo(
      context,
      defaultPath: RoutePath.stockDocList(widget.docType.code),
    );
    if (widget.id == null) {
      return UtenEditFloatingActions(
        onCancel: cancel,
        onSave: _save,
        saving: busy,
      );
    }
    return TaskClaimHandle(
      key: ValueKey('fulfillment_claim_${widget.id}'),
      targetType: 'FULFILLMENT_TASK_EDIT',
      targetKey: widget.id!,
      builder: (heldByMe, claim) {
        // 他人正编辑同一仓库单据 → 显示「XX 处理中」并禁用保存（UX 层；后端守卫兜底）。
        final blocked = !heldByMe && claim != null;
        return UtenEditFloatingActions(
          onCancel: cancel,
          onSave: (blocked || !_loadedCanEdit) ? null : _save,
          saving: busy,
          extraLeading: [
            if (blocked)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(UtenRadius.control),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TaskClaimBadge(claim: claim),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      '他人正在编辑，保存已禁用',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _dd(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged, {
    bool required = false,
  }) {
    return UtenDropdownField(
      label: label,
      required: required,
      value: value,
      items: [
        for (final e in entries.entries)
          UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
    );
  }
}
