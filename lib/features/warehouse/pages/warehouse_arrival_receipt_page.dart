// 仓库登记实际到货独立页（/warehouse/inbound/receipts/new）。
//
// 与采购/委外收货单编辑页分立的仓库专属登记页：
//   - 不出现币种/汇率/结帐方式/交货人/单价金额（价格对仓库不可见，审核时服务端权威回填）；
//   - 采购员、收货人必选（收货人=仓库收货人，默认当前登录人，默认部门仓储 SUB_WH）；
//   - 明细逐行登记本次实收 + 库位号/物料系列/物料编码（主档带出，保存后「学习」回写）；
//   - 入库仓库（2026-09-06 行级必填）：表头不再设默认仓——每行必选入库仓库，走
//     右侧主/子仓级联滑窗（先选主仓再选子仓，显示「主仓名-子仓名」）；预计到货带
//     建议仓（物料分析目标仓）时逐行预填，改离建议仓时提示（合格库存将入所选仓，
//     分析进度按所选仓刷新）；**勾选多行后在其中任意一行改仓/写库位即整批落值**
//     （2026-09-11 起不再有表头上方的批量按钮），并记住上次所落仓与库位下次自动带；
//   - 提交时按行级仓库分组，每仓一张收货单顺序登记（幂等键按「仓库+行+数量」内容
//     派生：响应丢失重试复用同键安全重放，部分失败时已成功仓不会重复登记）；
//   - 单位紧跟「本次实收」列展示；数量组之后是「实称重量」列(ADR-135，可选，永不阻断
//     登记)：到货过磅填净重，按本供应商学到的单重核对「称重核对」；格内 ⚖ 称重计数默认
//     「只记重量」，「按称重改数量」需显式点(按估算数量入账，影响对账)。货品或行单位本身
//     是重量单位时重量由数量精确换算、只读不提交。重量(千克 4 位)与「按称重改数量」随
//     明细提交，并计入幂等键；
//   - 「先质检后入库」(2026-09-20 前叫「登记并送检」)一步完成：保存（服务端按订货单
//     回填币族并建收货单草稿）+ 审核
//     （转品质部待检 IQC）同事务；实到超量时服务端隔离并通知财务，返回隔离结果。
//     登记后 pop(结果) 回预计到货任务中心就地刷新——仓库流程全程不进入采购/委外模块。
// 审核通过后采购/委外侧即生成同一张收货单记录（本页创建的就是该单据）。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_values.dart';
import '../../../shared/measurement/weight_mass_units.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weigh_count_dialog.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../models/arrival_form_draft_codec.dart';
import '../models/warehouse_form_draft_codec.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../purchase/config/purchase_doc_config.dart';
import '../../purchase/models/purchase_doc.dart';
import '../../subcontract/config/subcontract_doc_config.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../widgets/subcontract_short_delivery_confirm_dialog.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/inbound_allocation.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../models/inbound_registration_line.dart';
import '../providers/inbound_warehouse_fill_memory.dart';
import '../repositories/warehouse_place_suggestion_repository.dart';
import '../widgets/inbound_registration_widgets.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../widgets/batch_place_fill_dialog.dart';
import '../widgets/warehouse_inbound_allocation_view.dart';
import '../widgets/warehouse_autofill_text_field.dart';
import '../widgets/warehouse_arrival_source_field.dart';

class WarehouseArrivalReceiptPage extends ConsumerStatefulWidget {
  const WarehouseArrivalReceiptPage({
    super.key,
    this.prefill,
    this.canRegister,
  });

  /// 预计到货任务带入的预填；null = 无来源直达（不允许，需从任务中心进入）。
  final ProcurementReceiptPrefill? prefill;

  /// 仅供独立预览/测试覆盖；正式路由为空时从当前登录权限实时推导。
  final bool? canRegister;

  @override
  ConsumerState<WarehouseArrivalReceiptPage> createState() =>
      _WarehouseArrivalReceiptPageState();
}

class _WarehouseArrivalReceiptPageState
    extends ConsumerState<WarehouseArrivalReceiptPage>
    with FormDraftMixin<WarehouseArrivalReceiptPage> {
  ProcurementReceiptPrefill? _restoredPrefill;
  ProcurementReceiptPrefill? get _prefill => _restoredPrefill ?? widget.prefill;

  @override
  bool get formDraftBusy => _saving;
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.arrival.spec(
    title: '登记实际到货',
    route: RouteName.warehouseArrivalReceiptNew,
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _remark,
    _lineGrid,
    for (final line in _lines) ...[
      line.qty,
      line.weight,
      line.warehouse,
      line.place,
      line.series,
    ],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'prefill': _prefill == null ? null : arrivalPrefillDraft(_prefill!),
    'remark': _remark.text,
    'billDate': _billDate.toIso8601String(),
    'purchaserId': _purchaserId,
    'receiverId': _receiverId,
    'registrationId': _registrationId,
    'removedLineCount': _removedLineCount,
    'stockInBeforeInspection': _route.isStockInFirst,
    'employees': draftEmployees(_empCache),
    'rows': draftGridRows(
      _lineGrid,
      (line) => {
        'item': arrivalItemDraft(line.item),
        'qty': line.qty.text,
        'weight': weightEntryDraft(line.weight, qty: line.qty),
        'warehouseId': line.warehouseId,
        'warehouseAutofilled': line.warehouseAutofilled,
        'stockPlace': line.place.text,
        'stockPlaceAutofilled': line.place.autofilled,
        'series': line.series.text,
        'seriesAutofilled': line.series.autofilled,
        'source': line.source.name,
      },
    ),
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _restoredPrefill = restoreArrivalPrefillDraft(draftMap(data['prefill']));
    _remark.text = draftText(data, 'remark');
    _billDate = DateTime.parse(draftText(data, 'billDate'));
    _purchaserId = data['purchaserId'] as String?;
    _receiverId = data['receiverId'] as String?;
    _registrationId = draftText(data, 'registrationId');
    _removedLineCount = data['removedLineCount'] as int? ?? 0;
    _route = data['stockInBeforeInspection'] == true
        ? InboundRoute.stockInFirst
        : InboundRoute.inspectFirst;
    restoreDraftEmployees(_empCache, data['employees']);
    restoreDraftGrid(
      _lineGrid,
      data['rows'],
      (row) =>
          _ArrivalReceiptLine(
              restoreArrivalItemDraft(draftMap(row['item'])),
              warehouseId: row['warehouseId'] as String?,
              onChanged: _onLineChanged,
            )
            ..qty.text = draftText(row, 'qty')
            ..series.text = draftText(row, 'series')
            ..warehouseAutofilled = row['warehouseAutofilled'] == true
            ..source = WarehouseArrivalSource.values.byName(
              draftText(row, 'source'),
            ),
    );
    final rows = draftMaps(data['rows']);
    for (var index = 0; index < _lines.length; index++) {
      final row = rows[index];
      final line = _lines[index];
      restoreArrivalDraftText(
        line.place,
        draftText(row, 'stockPlace'),
        row['stockPlaceAutofilled'] == true,
      );
      restoreArrivalDraftText(
        line.series,
        draftText(row, 'series'),
        row['seriesAutofilled'] == true,
      );
      restoreWeightEntryDraft(line.weight, row['weight'], qty: line.qty);
    }
    _ensureWeightParams();
  }

  final _remark = TextEditingController();
  final _scrollCtl = ScrollController();

  /// 明细表 sticky 表头是否已置顶（页面滚动条门控：置顶前不显示，置顶后才显示）。
  final _gridPinned = ValueNotifier<bool>(false);
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  DateTime _billDate = ChinaDateTime.today();
  String? _purchaserId; // 仅采购收货（委外进仓单主档无采购员列）
  String? _receiverId;
  bool _loading = false;
  bool _saving = false;

  /// 短交确认弹窗要先撤「正在登记」全屏遮罩才点得动(遮罩是 root Overlay 的裸图层, 每次路由
  /// 重排都被重新抬到最顶, 一定压住后推的弹窗)。
  void _setSaving(bool saving) {
    if (mounted) setState(() => _saving = saving);
  }

  String _registrationId = const Uuid().v4();
  int _removedLineCount = 0;

  /// 单张页由双击行进入、未预选路线，两条路线按钮并排(与产成品单张登记页一致)：
  /// 记住最近一次点的是哪条，库位列是否必填(红框)跟着它走。
  InboundRoute _route = InboundRoute.inspectFirst;

  late final _suggestions = InboundPlaceSuggestionLoader(
    ref.read(warehousePlaceSuggestionRepositoryProvider),
  );

  final UtenEditableGridController<_ArrivalReceiptLine> _lineGrid =
      UtenEditableGridController<_ArrivalReceiptLine>();

  List<_ArrivalReceiptLine> get _lines => _lineGrid.rows;

  bool get _isPurchase =>
      _prefill?.orderType == ProcurementInboundOrderType.purchase;

  bool get _canRegisterNow {
    final override = widget.canRegister;
    if (override != null) return override;
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseInboundView) &&
        permissions.contains(Perm.warehouseInboundStockIn);
  }

  /// 「先入库后质检」按钮只对持有独立权限的账号显示(服务端同样兜底)。
  bool get _canStockInBeforeInspection {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.warehouseIqcStockInBeforeInspection);
  }

  /// 建议仓（物料分析目标仓）存在时预填；仓库可按实际到货情况更换，
  /// 改离建议仓时必须明示：合格库存不会计入原物料分析的目标仓备料。
  String? get _suggestedWarehouseId {
    final id = _prefill?.suggestedWarehouseId;
    return id == null || id.isEmpty ? null : id;
  }

  /// 行的有效入库仓库：2026-09-06 起行级必填（表头默认仓已删），
  /// 建议仓（物料分析目标仓）在 _init 时已逐行预填。
  String? _effectiveWarehouseId(_ArrivalReceiptLine line) => line.warehouseId;

  String? _warehouseLabel(String? id) =>
      inboundWarehouseLabel(ref.read(masterNameServiceProvider), id);

  double _lineInputBaseQty(_ArrivalReceiptLine line) {
    final input = double.tryParse(line.qty.text.trim()) ?? 0;
    final rate = line.item.unitRate.toDouble();
    return input * (rate.isFinite && rate > 0 ? rate : 1);
  }

  List<WarehouseInboundAllocation> _lineProjectedAllocations(
    _ArrivalReceiptLine line,
  ) => warehouseInboundAllocationForWarehouse(
    line.item.expectedAllocations,
    double.tryParse(line.qty.text.trim()) ?? 0,
    actualWarehouseId: _effectiveWarehouseId(line),
    actualWarehouseName: _warehouseLabel(_effectiveWarehouseId(line)) ?? '',
    sameMainWarehouse: (target, actual) => warehousesShareMain(
      ref.read(masterNameServiceProvider).warehouseHierarchy,
      target,
      actual,
    ),
    unitRate: line.item.unitRate.toDouble(),
  );

  String _lineBaseUnitLabel(_ArrivalReceiptLine line) =>
      line.item.baseUnitName?.trim().isNotEmpty == true
      ? line.item.baseUnitName!.trim()
      : line.item.expectedAllocations
                .map((item) => item.baseUnitName)
                .whereType<String>()
                .where((name) => name.trim().isNotEmpty)
                .firstOrNull ??
            '基本量';

  WarehouseInboundAllocationSection _lineAllocationSection(
    _ArrivalReceiptLine line,
  ) => WarehouseInboundAllocationSection(
    id: line.item.orderItemId,
    goodsLabel: '${line.item.goodsName}(${line.item.goodsCode})',
    quantity: _lineInputBaseQty(line),
    unitName: _lineBaseUnitLabel(line),
    sourceOrderNo: _prefill?.orderBillNo,
    allocations: _lineProjectedAllocations(line),
  );

  // ---- 实称重量(ADR-135)：单重参数按「货品 × 本单供应商」取，页面生命周期内缓存 ----

  /// 页面级单重参数缓存(build 里 watch，离开页面释放)。
  WeightParamsCache get _weightCache => ref.read(weightParamsCacheProvider);

  /// 单位 -> 重量单位(行单位本身按重量计时精确换算)。
  Map<String, WeightUnit> get _massUnits =>
      ref.read(warehouseUnitMassUnitsProvider).valueOrNull ?? const {};

  WeightParams? _paramsOf(_ArrivalReceiptLine line) =>
      _weightCache.of(line.goodsId, supplierId: _prefill?.supplierId);

  Iterable<WeightParamsLine> _weightParamsLines() => [
    for (final line in _lines)
      WeightParamsLine(goodsId: line.goodsId, supplierId: _prefill?.supplierId),
  ];

  void _ensureWeightParams() {
    if (!mounted) return;
    unawaited(_weightCache.ensure(_weightParamsLines()));
  }

  /// 按数量精确换算的重量(货品或行单位是重量单位)；需要实称时为 null。
  double? _exactKg(_ArrivalReceiptLine line) => warehouseExactLineKg(
    lineQty: double.tryParse(line.qty.text.trim()),
    lineMassUnit: _massUnits[line.item.unitId],
    unitRate: line.unitRate,
    params: _paramsOf(line),
  );

  /// 实际随明细提交的重量：精确换算行不带(服务端按数量算)，其余带实称千克。
  double? _sentKg(_ArrivalReceiptLine line) =>
      _exactKg(line) == null ? line.weight.kg : null;

  /// 幂等键的行重量片段(没称又没按称重改数量时为空串，键与不称重时一致)。
  String _weightKeyPart(_ArrivalReceiptLine line) {
    final part = warehouseWeightKeyPart(
      'w',
      _sentKg(line),
      line.weight.qtyFromWeight,
    );
    return part == null ? '' : ':$part';
  }

  String? _baseUnitName(_ArrivalReceiptLine line) {
    final base = line.item.baseUnitName?.trim();
    if (base != null && base.isNotEmpty) return base;
    return line.unitRate == 1 ? line.item.unitName : null;
  }

  /// 称重计数(到货口径)：默认「只记重量」，「按称重改数量」需显式点。
  Future<void> _weighCount(BuildContext context, _ArrivalReceiptLine line) =>
      warehouseWeighCount(
        context,
        request: WeighCountRequest(
          mode: WeighCountContext.receipt,
          goodsId: line.goodsId,
          goodsTitle: warehouseWeighGoodsTitle(
            line.item.goodsName,
            line.item.goodsCode,
            line.item.colorName,
          ),
          params: _paramsOf(line),
          supplierId: _prefill?.supplierId,
          warehouseId: line.warehouseId,
          baseUnitName: _baseUnitName(line),
          lineUnitName: line.item.unitName,
          unitRate: line.unitRate,
          currentQty: double.tryParse(line.qty.text.trim()),
          initialNetKg: line.weight.kg,
          sampleRemark: _prefill == null
              ? null
              : '到货登记 ${_prefill!.orderBillNo}',
        ),
        weight: line.weight,
        qty: line.qty,
        cache: _weightCache,
        refetch: _weightParamsLines(),
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _suggestions.dispose();
    _remark.dispose();
    _scrollCtl.dispose();
    _lineGrid.dispose();
    _gridPinned.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final prefill = _prefill;
    if (prefill == null) {
      try {
        await ref.read(masterNameServiceProvider).ensureLoaded();
      } catch (_) {
        // A local recovery snapshot must remain available while offline.
      }
      await initializeFormDraft();
      return;
    }
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    // 行级入库仓库预填（表头默认仓已删）：建议仓（物料分析目标仓）优先，
    // 无建议仓时退订货单仓库；都没有则留空、由仓库逐行必选。
    final lineWarehouse = prefill.suggestedWarehouseId?.isNotEmpty == true
        ? prefill.suggestedWarehouseId
        : prefill.warehouseId;
    if (_isPurchase && prefill.purchaserId?.isNotEmpty == true) {
      _purchaserId = prefill.purchaserId;
    }
    // 收货人默认当前登录人（仓库收货人，非采购员）。
    final meId = ref.read(sessionProvider).user?.employeeId;
    if (meId != null && meId.isNotEmpty) {
      _receiverId = meId;
    }
    _lineGrid.replaceAll([
      for (final item in prefill.items)
        _ArrivalReceiptLine(
          item,
          warehouseId: item.lastReceiptWarehouseId ?? lineWarehouse,
          onChanged: _onLineChanged,
        ),
    ]);
    // 进页默认全选（2026-09-17，与批量登记页同款）：勾选=本次要登记送检的行，
    // 右下两个提交按钮只认勾选行；默认全选让「进来直接提交」行为不变。
    _lineGrid.setSelected(_lineGrid.rows, true);
    _ensureWeightParams();
    final selectable = WarehouseSelection(
      ref.read(masterNameServiceProvider).warehouseHierarchy,
    ).selectableIds;
    // 个人选仓上下文只补空位：行内已有值(归属仓 / 建议仓)优先级更高，
    // 见 inbound_warehouse_fill_memory.dart。
    final memory = ref.read(
      inboundWarehouseFillMemoryProvider(InboundFillScope.procurement),
    );
    final rememberedWarehouse = selectable.contains(memory.warehouseId)
        ? memory.warehouseId
        : null;
    for (final line in _lineGrid.rows) {
      if (!selectable.contains(line.warehouseId)) {
        line.setWarehouse(rememberedWarehouse, autofilled: true);
      }
    }
    _removedLineCount = 0;
    await _preloadEmployees([prefill.purchaserId, meId]);
    if (mounted) setState(() => _loading = false);
    // 按行上的仓带出库位(该仓记住的库位 → 货品资料通用库位；手填/草稿值不覆盖)。
    await _suggestions.reload(_lines);
    if (mounted) await initializeFormDraft();
  }

  void _onLineChanged() {
    if (mounted) setState(() {});
  }

  /// 仅从当前登记请求移出，不调用删除 API、不改来源订货或到货累计。
  /// 返回任务中心后，这些行仍按服务端剩余量显示为“待登记送检”。
  void _removeFromThisRegistration(List<_ArrivalReceiptLine> rows) {
    if (_saving || !_canRegisterNow || rows.isEmpty) return;
    _lineGrid.removeRows(rows);
    if (!mounted) return;
    setState(() => _removedLineCount += rows.length);
    context.appInfo('已从本次登记移出 ${rows.length} 行；未写入数据库，返回任务中心后仍可继续登记送检');
  }

  /// 并发按 id 拉人员名字（picker 的 initial 显示用）。失败静默。
  Future<void> _preloadEmployees(Iterable<String?> ids) async {
    final uniq = ids.whereType<String>().where((id) => id.isNotEmpty).toSet();
    if (uniq.isEmpty) return;
    final repo = ref.read(employeeRepositoryProvider);
    await Future.wait(
      uniq.map((id) async {
        try {
          final p = await repo.getById(id);
          _empCache[id] = UtenEmployeePickerItem(
            id: p.id,
            name: p.fullName ?? '',
            employeeCode: p.code,
            departmentName: p.departmentName,
          );
        } catch (_) {
          // 静默：picker 的 initial 为 null 时不显示名字，不阻塞流程。
        }
      }),
    );
  }

  /// 一次改动的落值范围（与批量登记页、新建采购订货单同一套口径）。
  ///
  /// 2026-09-11 起表头上方不再有「批量设置入库仓库 / 批量填写库位」按钮：
  /// **勾选若干行 → 在其中任意一行改仓/写库位 = 批量落到全部选中行**；
  /// 点的行不在选中集里（或压根没勾）就只改这一行。
  List<_ArrivalReceiptLine> _writeTargets(_ArrivalReceiptLine row) {
    final selected = _lineGrid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 行内写库位：落到 [_writeTargets] 并记住本次库位号（下次登记自动带）。
  void _onStockPlaceChanged(_ArrivalReceiptLine line, String value) {
    final targets = _writeTargets(line);
    if (targets.length > 1) {
      setState(() {
        for (final target in targets) {
          if (identical(target, line)) continue;
          target.setCheckedPlace(value);
        }
      });
    }
  }

  /// 行级入库仓库选择（主/子仓级联滑窗；行级必填）：
  /// 落到 [_writeTargets]，并记住这次选的仓。
  Future<void> _pickLineWarehouse(_ArrivalReceiptLine line) async {
    if (_saving) return;
    await _pickWarehouseFor(
      _writeTargets(line),
      fallbackWarehouseId: _suggestedWarehouseId,
    );
  }

  /// 选仓核心（行内点击与右键「批量设置入库仓库」共用，2026-09-12）：
  /// 面板返回后落到目标行、记住这次选的仓。
  Future<void> _pickWarehouseFor(
    List<_ArrivalReceiptLine> targets, {
    String? fallbackWarehouseId,
  }) async {
    if (_saving || targets.isEmpty) return;
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
      initialWarehouseId: targets.first.warehouseId ?? fallbackWarehouseId,
      title: targets.length > 1
          ? '批量设置入库仓库（选中 ${targets.length} 行）'
          : '选择入库仓库 · ${targets.first.goodsName}',
    );
    if (picked == null || !mounted) return;
    setState(() {
      for (final target in targets) {
        target.setWarehouse(picked.id);
      }
    });
    ref
        .read(
          inboundWarehouseFillMemoryProvider(
            InboundFillScope.procurement,
          ).notifier,
        )
        .rememberWarehouse(picked.id);
    if (targets.length > 1) {
      context.appInfo('已把入库仓库写到选中的 ${targets.length} 行');
    }
    // 按新仓重新带出库位(只覆盖没手填过的行)。
    await _suggestions.reload(targets);
  }

  /// 右键「批量设置库位号」（2026-09-12，与批量登记页统一口径）：一次输入应用
  /// 到全部选中行，只作用本次选中行(成功入库后按仓库、货品和颜色学习)。
  Future<void> _batchFillStockPlace(List<_ArrivalReceiptLine> rows) async {
    if (_saving || rows.isEmpty) return;
    final place = await showBatchPlaceFillDialog(
      context,
      rowCount: rows.length,
      inputKey: const Key('warehouse-arrival-receipt-place-input'),
      applyKey: const Key('warehouse-arrival-receipt-place-apply'),
    );
    if (place == null || !mounted) return;
    if (place.isEmpty) {
      context.appWarning('库位号不能为空');
      return;
    }
    setState(() {
      for (final line in rows) {
        line.setCheckedPlace(place);
      }
    });
  }

  /// [route] = 点的是哪条路线的按钮(两条并排)。
  Future<void> _save(InboundRoute route) async {
    if (!_canRegisterNow) {
      context.appError('当前账号没有登记并送检权限，请返回任务中心刷新权限');
      return;
    }
    final effective = route.isStockInFirst && !_canStockInBeforeInspection
        ? InboundRoute.inspectFirst
        : route;
    if (_route != effective) {
      // 先切路线再校验：缺库位的行立刻红框，用户补齐后再点同一个按钮。
      setState(() => _route = effective);
    }
    if (_suggestions.loading) {
      context.appInfo('正在读取所选仓库的默认库位，请稍候再提交');
      return;
    }
    final prefill = _prefill;
    if (prefill == null) return;
    if (_isPurchase && (_purchaserId == null || _purchaserId!.isEmpty)) {
      context.appError('请选择采购员');
      return;
    }
    if (_receiverId == null || _receiverId!.isEmpty) {
      context.appError('请选择收货人(仓库收货人)');
      return;
    }
    if (_lines.isEmpty) {
      context.appError(
        _removedLineCount > 0
            ? '本次登记已无明细（已移出 $_removedLineCount 行）；'
                  '请至少保留一行，或返回任务中心重新进入——移出的来源行仍是待登记送检。'
            : '该任务没有可登记明细，请返回任务中心刷新',
      );
      return;
    }
    // 勾选=本次要登记送检的行（2026-09-17，与批量登记页/订货单编辑页同款）：
    // 右下两个提交按钮没勾行时已置灰，这里再兜一层；未勾选行不进校验与提交。
    final submitLines = _lineGrid.selectedRows;
    if (submitLines.isEmpty) {
      context.appError('请先勾选要登记送检的明细行（未勾选的行本次不登记）');
      return;
    }
    final submitted = submitLines.toSet();
    final excludedCount = _lines.length - submitLines.length;
    // 行级有效仓库分组（LinkedHashMap 保序）：每仓一张收货单顺序登记。
    // 同时整表扫完再报：原先首个违规就 return，用户补一行提交一次才看到下一行，
    // 观感像「怎么老是报错」。判定条件不变，只把问题按类别各汇总成一条。
    final groups = <String, List<_ArrivalReceiptLine>>{};
    final badQty = <String>[];
    final missingWarehouse = <String>[];
    final missingPlace = <String>[];
    final stockInFirst = _route.isStockInFirst;
    for (var index = 0; index < _lines.length; index++) {
      final line = _lines[index];
      if (!submitted.contains(line)) continue;
      final label = '第 ${index + 1} 行（${line.item.goodsName}）';
      final qty = double.tryParse(line.qty.text.trim()) ?? 0;
      if (qty <= 0) badQty.add(label);
      // 先入库后质检：库位是实物落点，逐行必填(原流程仍只是学习字段)。
      if (stockInFirst && line.place.text.trim().isEmpty) {
        missingPlace.add(label);
      }
      final warehouseId = _effectiveWarehouseId(line);
      if (warehouseId == null || warehouseId.isEmpty) {
        missingWarehouse.add(label);
        continue;
      }
      groups.putIfAbsent(warehouseId, () => []).add(line);
    }
    final rowIssues = <String>[
      if (badQty.isNotEmpty)
        inboundRowIssueMessage(badQty, '的本次实收不是大于 0 的数字', action: '请改正后再提交'),
      if (missingWarehouse.isNotEmpty)
        inboundRowIssueMessage(missingWarehouse, '未选择入库仓库', action: '请补齐后再提交'),
      if (missingPlace.isNotEmpty)
        inboundRowIssueMessage(
          missingPlace,
          '未填写库位号(先入库后质检必填)',
          action: '请补齐后再提交',
        ),
    ];
    if (rowIssues.isNotEmpty) {
      // 不同类别分行列出，混成一句会让人看不清到底要改哪几处。
      context.appError(rowIssues.join('\n'));
      return;
    }
    // 预计去向按员工本次实收、unitRate 和各自行有效仓重算；
    // 真正归属仍由后续 IQC 入库事务决定。
    final projectedSections = [
      for (final line in submitLines) _lineAllocationSection(line),
    ];
    final hasCrossWarehouse = projectedSections.any(
      (section) => section.allocations.any((item) => item.isCrossWarehouse),
    );
    final confirmed = await showWarehouseInboundAllocationConfirmDialog(
      context,
      title: route.label,
      actionLabel: stockInFirst ? '登记先入库' : '登记送检',
      confirmLabel: stockInFirst
          ? (hasCrossWarehouse ? '确认跨仓登记并先入库' : '确认登记并先入库')
          : (hasCrossWarehouse ? '确认跨仓登记送检' : '确认登记送检'),
      sections: projectedSections,
      // 有未勾选行时先说清去向，防「取消勾选=静默不登记」。
      description:
          (stockInFirst
              ? '确认后按本次实收数量登记到货、送品质部待检，并在同一事务里把每行实物按库位号上架(先入库后质检)：'
                    '品质部到库位检验，合格后系统自动按上架位置转正入库，不合格由仓库从库位取出登记退回；'
                    '${groups.length > 1 ? '本批将按 ${groups.length} 个入库仓库分别建立收货单；' : ''}'
                    '${hasCrossWarehouse ? '红色跨仓部分只是预计，将不绑定原计划并按实际仓公共入库，请重点复核；' : ''}'
                    '实到超过财务批准量时系统自动隔离并通知财务审核组，隔离单不上架、不入库、不生成应付。'
              : '确认后按本次实收数量登记到货并直接送品质部待检(IQC)：'
                    '检验合格后转仓库待入库任务，仓库确认实物与库位后库存才增加；'
                    '${groups.length > 1 ? '本批将按 ${groups.length} 个入库仓库分别建立收货单；' : ''}'
                    '${hasCrossWarehouse ? '红色跨仓部分只是预计，将不绑定原计划并按实际仓公共入库，请重点复核；' : ''}'
                    '实到超过财务批准量时系统自动隔离并通知财务审核组，'
                    '不会入库、不会生成应付。最终预定归属以 IQC 合格后仓库确认入库事务为准。') +
          (excludedCount > 0
              ? '另有 $excludedCount 行未勾选：本次不登记、不写库存，仍留在待登记送检。'
              : ''),
    );
    if (!confirmed) return;
    setState(() => _saving = true);
    final registrations = <WarehouseArrivalRegistration>[];
    try {
      await saveFormDraftNow();
      final repo = ref.read(procurementInboundRepositoryProvider);
      for (final entry in groups.entries) {
        final lines = entry.value;
        // 幂等键按「仓库+行+数量(+实称重量)」内容派生：响应丢失重试复用同键安全重放；
        // 部分仓库失败后原地重试，已成功仓按同键重放、不会重复登记；改了重量是另一个请求。
        final canonical = [
          _registrationId,
          entry.key,
          if (stockInFirst) 'stock-in-first',
          for (final line in lines)
            '${line.item.orderItemId}:${(double.tryParse(line.qty.text.trim()) ?? 0)}'
                '${line.source.apiValue == null ? '' : ':${line.source.apiValue}'}'
                '${_weightKeyPart(line)}',
        ].join('|');
        final body = <String, dynamic>{
          'idempotencyKey': businessIdempotencyKey(
            'warehouse-arrival-create',
            canonical,
          ),
          'billDate': _fmt(_billDate),
          'warehouseId': entry.key,
          'supplierId': prefill.supplierId,
          'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
          if (_isPurchase) ...{
            'purchaserId': _purchaserId,
            'receiverEmployeeId': _receiverId,
          } else
            // 委外进仓单主档仅 sender_id 一个人员列（服务端按「收货人」语义解析）。
            'receiverEmployeeId': _receiverId,
          // 先入库后质检(V596)：同事务按库位上架；点「登记并送检」时不传，老哈希逐字不变。
          if (stockInFirst) 'stockInBeforeInspection': true,
          'items': [
            for (final line in lines)
              {
                'goodsId': line.item.goodsId,
                'qty': double.tryParse(line.qty.text.trim()) ?? 0,
                'orderItemId': line.item.orderItemId,
                if (stockInFirst) 'preStockPlace': line.place.text.trim(),
                if (line.source.apiValue != null)
                  'replacementIntent': line.source.apiValue,
                // 来源单据编号谱系（来源订货单号），与编辑页口径一致。
                'sourceDocNo': prefill.orderBillNo,
                if (line.item.colorId != null) 'colorId': line.item.colorId,
                if (line.item.unitId != null) 'unitId': line.item.unitId,
                // 委外进仓明细带单位换算率（与委外编辑页口径一致）；采购收货不需要。
                if (!_isPurchase) 'unitRate': line.item.unitRate,
                // 实称净重(千克 4 位；没称不带，精确换算行不带)与「按称重改数量」。
                // 不带 price：价格对仓库不可见(审核时服务端按订货明细权威回填)。
                'weight': ?_sentKg(line),
                if (line.weight.qtyFromWeight) 'qtyFromWeight': true,
              },
          ],
        };
        try {
          if (!mounted) return;
          // ADR-098：委外回厂累计低于允许损耗下限时服务端先 409，弹窗确认后带确认重发。
          final registration = await registerArrivalConfirmingShortDelivery(
            context: context,
            body: body,
            register: (payload) => runFormDraftSubmission(
              () => repo.registerArrival(
                orderType: prefill.orderType,
                body: payload,
              ),
            ),
            setBusy: _setSaving,
          );
          if (registration == null) {
            // 仓库选择「返回修改」：原地停下；已成功仓不回滚（同键重放安全）。
            if (!mounted) return;
            if (registrations.isNotEmpty) {
              context.appWarning(
                '已按 ${registrations.length} 个仓库登记送检；其余已取消，修改数量后可直接重试',
              );
            }
            return;
          }
          registrations.add(registration);
        } on ApiException catch (e) {
          if (!mounted) return;
          // 部分失败：停在原页保住已选内容；已成功仓同键重放，直接重试即可。
          if (registrations.isNotEmpty) {
            context.appError(
              '已按 ${registrations.length} 个仓库登记送检；仓库'
              '「${_warehouseLabel(entry.key) ?? entry.key}」登记失败：${e.message}。'
              '可直接重试，已成功部分不会重复登记',
            );
          } else {
            context.appError(e.message);
          }
          return;
        }
      }
      // 货品资料「学习」回写（best-effort）：不阻塞返回任务中心，失败静默。
      // 只学习实际登记了的行（未勾选行不产生本次事实）。
      unawaited(_learnGoodsProfiles(submitLines));
      if (!mounted) return;
      await completeFormDraft();
      if (!mounted) return;
      bumpListRefresh(
        ref,
        _isPurchase
            ? PurchaseDocConfig.by(PurchaseDocType.receipt).refreshKey
            : SubcontractDocConfig.by(SubcontractDocType.receipt).refreshKey,
      );
      invalidateWarehouseTaskCounts(ref);
      final batch = WarehouseArrivalRegistrationBatch(
        registrations: registrations,
      );
      // pop(登记结果) 让任务中心就地刷新并提示下一步；不再跳采购/委外收货单详情页——
      // 仓库流程全程不离开仓储模块（超收时任务中心引导到「到货异常任务中心」）。
      if (context.canPop()) {
        context.pop(batch);
      } else {
        context.go(RouteName.warehouseInboundExpectations);
      }
    } catch (_) {
      if (mounted) context.appError('登记送检失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 学习回写：仅上报用户实际填了值的字段（空值跳过由服务端兜底）。失败不阻断主流程。
  Future<void> _learnGoodsProfiles(List<_ArrivalReceiptLine> lines) async {
    final hints = <Map<String, dynamic>>[
      for (final line in lines)
        {
          'goodsId': line.item.goodsId,
          if (line.item.goodsCode.trim().isNotEmpty)
            'goodsCode': line.item.goodsCode.trim(),
          if (line.series.text.trim().isNotEmpty)
            'series': line.series.text.trim(),
          if (line.place.text.trim().isNotEmpty)
            'stockPlace': line.place.text.trim(),
        },
    ];
    if (hints.isEmpty) return;
    try {
      await ref
          .read(procurementInboundRepositoryProvider)
          .saveGoodsProfileHints(hints);
    } catch (_) {
      // 静默：学习回写失败不影响已保存的到货登记。
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    // 单重参数缓存与单位字典随页面存活；录入/显示单位是用户偏好。
    ref.watch(weightParamsCacheProvider);
    ref.watch(warehouseUnitMassUnitsProvider);
    final prefill = _prefill;
    final theme = Theme.of(context);
    final permissionSnapshot = widget.canRegister == null
        ? ref.watch(currentPermissionsProvider)
        : const <String>{};
    final isAdmin =
        widget.canRegister == null && ref.watch(isSuperAdminProvider);
    final canRegister =
        widget.canRegister ??
        (isAdmin ||
            (permissionSnapshot.contains(Perm.warehouseInboundView) &&
                permissionSnapshot.contains(Perm.warehouseInboundStockIn)));
    // 「先入库后质检」按钮随权限快照实时显隐(独立权限点，与 canRegister 注入无关)。
    final canPreStock =
        ref.watch(isSuperAdminProvider) ||
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.warehouseIqcStockInBeforeInspection);
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: prefill == null
              ? '登记实际到货'
              : '登记实际到货 · ${prefill.orderType.label}',
          leading: UtenBackButton(
            onPressed: () => popOrBackTo(
              context,
              defaultPath: RouteName.warehouseInboundExpectations,
            ),
          ),
        ),
        body: SafeArea(
          child: prefill == null
              ? _missingPrefill(context)
              : _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : Stack(
                  children: [
                    AbsorbPointer(
                      absorbing: _saving || !canRegister,
                      child: _buildForm(context, theme, prefill, canRegister),
                    ),
                    // 提交期间全屏加载遮罩（按仓库逐张登记，可能连续多笔网络）。
                    if (_saving)
                      const UtenBusyOverlay(
                        title: '正在登记到货并送检',
                        description: '正在按入库仓库逐张建立收货单，请勿重复提交或离开本页。',
                      ),
                  ],
                ),
        ),
        // 2026-09-14 UI 统一口径：吸底操作条改右下悬浮组（按钮已是 large）。
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        // 提交集=勾选集（2026-09-17）：监听表格选择集，一行都没勾时右下两个
        // 提交按钮置灰（灰态点击说明原因），勾回任意行立即恢复。
        floatingActionButton: prefill == null
            ? null
            : ListenableBuilder(
                listenable: Listenable.merge([_lineGrid, _suggestions]),
                builder: (context, _) =>
                    _buildBottomBar(canRegister, canPreStock),
              ),
      ),
    );
  }

  Widget _missingPrefill(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_shipping_outlined, size: 40),
          const SizedBox(height: UtenSpacing.s12),
          const Text('请从「预计到货任务中心」选择任务后登记到货'),
          const SizedBox(height: UtenSpacing.s16),
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.arrow_back_rounded,
            onPressed: () => context.go(RouteName.warehouseInboundExpectations),
            child: const Text('返回任务中心'),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    ThemeData theme,
    ProcurementReceiptPrefill prefill,
    bool canRegister,
  ) {
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    return UtenGridPageScrollbar(
      pinned: _gridPinned,
      controller: _scrollCtl,
      // 滚动条贴屏幕右缘（2026-09-15）：包装在内容容器之外，右缘窄条
      // 恒在屏幕最右，不随限宽容器/列宽漂移。
      child: UtenContentContainer(
        child: ListView(
          controller: _scrollCtl,
          // 底部留出右下悬浮操作组的高度，末段明细可滚出按钮区。
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
                    UtenFormGrid(
                      children: [
                        UtenDateField(
                          label: '单据日期',
                          required: true,
                          value: _billDate,
                          onChanged: (d) => setState(() => _billDate = d),
                        ),
                        // 供应商来自预计到货任务，只读防改坏来源关联。
                        TextFormField(
                          errorBuilder: utenTextFieldErrorBuilder,
                          readOnly: true,
                          initialValue: prefill.supplierName ?? '—',
                          decoration: const UtenInputDecoration(
                            InputDecoration(labelText: '供应商', filled: true),
                          ),
                        ),
                        // 采购员（采购收货必选；委外进仓单主档无此列，不录）。
                        if (_isPurchase)
                          _employeePicker(
                            label: '采购员',
                            currentId: _purchaserId,
                            defaultDeptCode: kDeptCodePurchase,
                            onChanged: (id) =>
                                setState(() => _purchaserId = id),
                          ),
                        _employeePicker(
                          label: '收货人',
                          currentId: _receiverId,
                          defaultDeptCode: kDeptCodeWarehouse,
                          onChanged: (id) => setState(() => _receiverId = id),
                        ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      controller: _remark,
                      decoration: const InputDecoration(labelText: '备注'),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            ..._warehouseNotices(theme),
            InboundPlaceSuggestionStatus(
              loader: _suggestions,
              onRetry: () => _suggestions.reload(_lines),
            ),
            // 「明细(N 行)」标题与表格上方的「统一设置入库仓库」按钮 2026-09-11
            // 一并撤除：落仓/填库位改由表格操作条的批量动作承载（勾选若干行后
            // 作用于选中行，未勾选时沿用旧口径作用于全部明细行）。
            const SizedBox(height: UtenSpacing.s8),
            // 勾选口径说明(与批量登记页、产成品登记页同一句式)。
            InboundGridIntro(
              sourceSummary: '来源订货单 ${prefill.orderBillNo}',
              submitLabel:
                  '${InboundRoute.stockInFirst.label} / ${InboundRoute.inspectFirst.label}',
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenEditableGrid<_ArrivalReceiptLine>(
              tableKey:
                  'features.warehouse.pages.warehouse_arrival_receipt_page.WarehouseArrivalReceiptPageState._buildForm.1',
              key: const Key('warehouse-arrival-lines-grid'),
              controller: _lineGrid,
              stickyHeaderPinned: _gridPinned,
              columns: _arrivalLineColumns(canRegister, weightUnits.entry),
              createBlankRow: () => throw UnsupportedError('到货任务明细由订货单固定带入'),
              showAddRow: false,
              showRowDelete: false,
              selectable: canRegister,
              selectionEnabled: canRegister && !_saving,
              onRemoveRows: canRegister ? _removeFromThisRegistration : null,
              removeRowsActionLabel: '移出本次登记',
              removeRowsDialogTitle: '移出本次登记',
              removeRowsConfirmLabel: '确认移出',
              removeRowsMessageBuilder: (count) =>
                  '确认从本次登记移出选中的 $count 行？'
                  '该操作不删除订货明细、不改变库存或历史；返回任务中心后仍保持待登记送检。',
              // 2026-09-11 表头上方常驻按钮全撤：全选走表头复选框，移出走行右键，
              // 落仓/写库位改成「勾选多行后改任意一行即整批落值」。
              showSelectAllToggle: false,
              showRemoveRowsAction: false,
              // 2026-09-14：只走右键在宽屏桌面等于没有入口（提示被窄屏门控吃掉，
              // 右键落在可编辑单元格弹的是输入框自带菜单），用户判定「不能删除
              // 部分」。补每行常驻 ⊖，点击走同一条「移出本次登记」确认与回调。
              showInlineRemoveAction: true,
              // 2026-09-12 右键菜单补显式批量入口（与批量登记页、产成品登记页
              // 统一口径）：勾选多行后右键可批量设仓/批量填库位。
              rowMenuExtraBuilder: canRegister && !_saving
                  ? (context, selected) => [
                      UtenMenuItem(
                        label: '批量设置入库仓库 (${selected.length})',
                        icon: Icons.warehouse_outlined,
                        enabled: selected.isNotEmpty,
                        onTap: () => _pickWarehouseFor(selected),
                      ),
                      UtenMenuItem(
                        label: '批量设置库位号 (${selected.length})',
                        icon: Icons.edit_note_outlined,
                        enabled: selected.isNotEmpty,
                        onTap: () => _batchFillStockPlace(selected),
                      ),
                    ]
                  : null,
              emptyMessage: '该任务没有可登记明细，请返回任务中心刷新',
              // 「称重单位: 千克▾」：录入单位是用户级偏好，表头与已填重量跟着换。
              toolbarActions: const [WeightEntryUnitButton()],
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 单重参数到达后「称重偏差 N 行」随之刷新。
                  ListenableBuilder(
                    listenable: _weightCache,
                    builder: (context, _) =>
                        inboundTotalsBar<_ArrivalReceiptLine>(
                          key: const Key('warehouse-arrival-totals'),
                          lines: _lines,
                          qtyLabel: '本次实收',
                          qtyOf: (line) =>
                              double.tryParse(line.qty.text.trim()) ?? 0,
                          unitIdOf: (line) => line.item.unitId,
                          unitNameOf: (line) => line.item.unitName,
                          weight: warehouseWeightTotals<_ArrivalReceiptLine>(
                            _lines,
                            weightOf: (line) => line.weight,
                            exactKgOf: _exactKg,
                            paramsOf: _paramsOf,
                            qtyBaseOf: (line) => line.qtyBase,
                          ),
                          weightDisplay: weightUnits.display,
                        ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    _removedLineCount == 0
                        ? '本次实收默认=批准剩余量，可改；入库仓库行级必填(按订货单建议仓或上次所选仓'
                              '预填)，库位按该仓记住的库位或货品资料带出(黄框请核对)，入库后自动记住'
                              '为该仓默认库位。明细默认全选，提交只含勾选行。'
                        : '已移出 $_removedLineCount 行(仅本页临时选择)；这些来源行未写收货、未写库存，仍在待登记。'
                              '明细默认全选，提交只含勾选行。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }

  /// 仓库相关提示：多仓分组说明（信息）+ 跨仓预定警告（错误色）。
  List<Widget> _warehouseNotices(ThemeData theme) {
    final effectiveLabels = <String>{};
    var crossLineCount = 0;
    for (final line in _lines) {
      final label = _warehouseLabel(_effectiveWarehouseId(line));
      if (label != null) effectiveLabels.add(label);
      if (_lineProjectedAllocations(line).any((a) => a.isCrossWarehouse)) {
        crossLineCount++;
      }
    }
    if (effectiveLabels.length <= 1 && crossLineCount == 0) {
      return const [];
    }
    return [
      for (final (index, notice) in _buildWarehouseNoticeData(
        theme,
        effectiveLabels,
        crossLineCount,
      ).indexed) ...[
        notice,
        if (index == 0) const SizedBox(height: UtenSpacing.s12),
      ],
    ];
  }

  List<Widget> _buildWarehouseNoticeData(
    ThemeData theme,
    Set<String> effectiveLabels,
    int crossLineCount,
  ) {
    final widgets = <Widget>[];
    if (effectiveLabels.length > 1) {
      widgets.add(
        _noticeContainer(
          theme,
          color: theme.colorScheme.tertiary,
          icon: Icons.call_split_rounded,
          title: '本批将按 ${effectiveLabels.length} 个入库仓库分别建收货单',
          detail:
              '仓库：${effectiveLabels.join(' / ')}。提交后每个仓库一张收货单'
              '（顺序登记、逐张送检）；如需调整，点击各行「入库仓库」单独改仓。',
          key: const Key('warehouse-arrival-multi-warehouse-notice'),
        ),
      );
    }
    if (crossLineCount > 0) {
      widgets.add(
        _noticeContainer(
          theme,
          color: theme.colorScheme.error,
          icon: Icons.warning_amber_rounded,
          title: '当前有 $crossLineCount 行包含跨仓预定',
          detail:
              '这些行的本次实收超过所选入库仓的分析预定量。可把本次实收改小到所选仓预定量，'
              '或勾选/右键移出整行，按实际到仓分批登记；若实物确在该仓，'
              '确认后跨仓部分预计转公共库存，最终由 IQC 入库事务复核。',
          key: const Key('warehouse-arrival-allocation-warehouse-notice'),
        ),
      );
    }
    return widgets;
  }

  Widget _noticeContainer(
    ThemeData theme, {
    required Color color,
    required IconData icon,
    required String title,
    required String detail,
    Key? key,
  }) {
    return Semantics(
      key: key,
      container: true,
      liveRegion: true,
      label: '$title。$detail',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(detail, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 明细表列(与批量登记页、产成品登记页同一套共用列，列名/列序/格式一致)：
  // 货品名称 → 编号 → 颜色 → 批准剩余 → 到货来源 → 本次实收 → 单位 → 实称重量 →
  // 称重核对 → 入库仓库 → 预计去向 → 库位号 → 物料系列。
  List<EditableGridColumn<_ArrivalReceiptLine>> _arrivalLineColumns(
    bool canRegister,
    WeightUnit weightEntryUnit,
  ) {
    final names = ref.read(masterNameServiceProvider);
    final shared = InboundGridColumns<_ArrivalReceiptLine>(
      names: names,
      keyPrefix: 'warehouse-arrival',
      lineKeyOf: (line) => line.item.orderItemId,
      goodsCodeOf: (line) => line.item.goodsCode,
      colorNameOf: (line) => line.item.colorName,
      unitNameOf: (line) => line.item.unitName,
    );
    bool editable(_ArrivalReceiptLine line) => canRegister && !_saving;
    final stockInFirst = _route.isStockInFirst;
    final suggested = _suggestedWarehouseId;
    return [
      shared.goodsName(),
      shared.goodsCode(),
      shared.color(),
      shared.quantity(
        key: 'approvedRemainingQty',
        label: '批准剩余',
        textOf: (line) => inboundQty(line.item.approvedRemainingQty),
        exactValueOf: (line) => line.item.approvedRemainingQty.toString(),
      ),
      EditableGridColumn(
        key: 'arrivalSource',
        label: workflowFieldText(context).warehouseArrivalSourceLabel,
        width: 165,
        // 每行相同的通用说明放列头 ⓘ：格内只留行特有的错误/预填图标。
        headerInfo: workflowFieldText(context).warehouseArrivalSourceHint,
        textOf: (line) => line.source.label(context),
        cellBuilder: (context, line) => WarehouseArrivalSourceField(
          key: ValueKey('warehouse-arrival-source-${line.item.orderItemId}'),
          value: line.source,
          enabled: editable(line),
          onChanged: (source) => setState(() => line.source = source),
        ),
      ),
      shared.receivedQuantity(
        controllerOf: (line) => line.qty,
        enabled: editable,
        headerInfo: workflowFieldText(context).workflowArrivalQuantityHint,
      ),
      // 单位紧跟「本次实收」：数量的含义(数量/重量)由基础资料-单位的维度决定。
      shared.unit(),
      // 实称重量跟在数量组之后；按本供应商学到的单重核对(称重核对列)。
      shared.weight(
        entryUnit: weightEntryUnit,
        enabled: editable,
        paramsOf: _paramsOf,
        paramsListenable: _weightCache,
        qtyBaseOf: (line) => line.qtyBase,
        qtyListenableOf: (line) => line.qty,
        exactKgOf: _exactKg,
        baseUnitNameOf: _baseUnitName,
        onWeighCount: _weighCount,
      ),
      shared.weightCheck(
        paramsOf: _paramsOf,
        paramsListenable: _weightCache,
        qtyBaseOf: (line) => line.qtyBase,
        qtyListenableOf: (line) => line.qty,
        baseUnitNameOf: _baseUnitName,
      ),
      shared.warehouse(
        required: true,
        enabled: editable,
        onTap: _pickLineWarehouse,
        autofillInfo: '已带入订货单建议仓或上次所选仓，请核对本次实物入库仓库',
        // 改离建议仓描橙边：合格库存不再计入原物料分析目标仓备料。
        changedAwayOf: (line) =>
            suggested != null &&
            line.warehouseId != null &&
            !warehousesShareMain(
              names.warehouseHierarchy,
              line.warehouseId!,
              suggested,
            ),
      ),
      EditableGridColumn(
        key: 'expectedAllocation',
        label: '预计去向(基本量)',
        width: 240,
        textOf: (line) => warehouseInboundAllocationSummaryText(
          _lineProjectedAllocations(line),
          (value) => '${inboundQty(value)} ${_lineBaseUnitLabel(line)}',
        ),
        listenableOf: (line) => line.qty,
        cellBuilder: (context, line) =>
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: line.qty,
              builder: (context, _, _) {
                final allocations = _lineProjectedAllocations(line);
                return WarehouseInboundAllocationSummary(
                  allocations: allocations,
                  qtyText: (value) =>
                      '${inboundQty(value)} ${_lineBaseUnitLabel(line)}',
                  onTap: () => showWarehouseInboundAllocationDetails(
                    context,
                    title: '预计去向 · ${line.item.goodsName}',
                    sections: [_lineAllocationSection(line)],
                  ),
                );
              },
            ),
      ),
      // 先入库后质检：库位是实物落点，必填(空则红框)。
      shared.place(
        required: stockInFirst,
        enabled: editable,
        onChanged: _onStockPlaceChanged,
        headerInfo: stockInFirst
            ? '先入库后质检必填：填实物实际放置的库位，品质部按此到库位检验。'
                  '选定入库仓库后按「该仓记住的库位 → 货品资料通用库位」自动带出；黄框 = 预填待核对。'
            : '选定入库仓库后按「该仓记住的库位 → 货品资料通用库位」自动带出；'
                  '黄框 = 预填待核对，可直接修改。入库后自动记住为该仓默认库位。',
      ),
      EditableGridColumn(
        key: 'series',
        label: '物料系列',
        width: 140,
        textOf: (line) => line.series.text,
        listenableOf: (line) => line.series,
        // 预填黄标 ⓘ(44)计入量宽。
        cellBuilder: (context, line) => Semantics(
          textField: true,
          label: '${line.item.goodsName} 物料系列',
          child: WarehouseAutofillTextField(
            controller: line.series,
            source: '系列来自货品资料，请核对本次到货',
            enabled: editable(line),
          ),
        ),
      ),
    ];
  }

  Widget _buildBottomBar(bool canRegister, bool canPreStock) {
    // 单张页由双击行进入、未预选路线，两条路线按钮并排(同名同义、同一组件)。
    // 提交集=勾选集：一行都没勾或库位建议加载中时提交置灰，灰态点击说明原因。
    final hasCheckedLine = _lineGrid.selectedRows.isNotEmpty;
    final canSubmit =
        canRegister &&
        !_saving &&
        !_suggestions.loading &&
        _lines.isNotEmpty &&
        hasCheckedLine;
    final VoidCallback? onDisabledTap = !canRegister || _lines.isEmpty
        ? null
        : _suggestions.loading
        ? () => context.appInfo('正在读取所选仓库的默认库位，请稍候再提交')
        : hasCheckedLine
        ? null
        : () => context.appWarning('请先勾选要登记送检的明细行（未勾选的行本次不登记）');
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: _saving ? null : () => context.pop(),
          child: const Text('取消'),
        ),
        for (final route in InboundRoute.values)
          if (!route.isStockInFirst || canPreStock)
            InboundRouteSubmitButton(
              route: route,
              isLoading: _saving && _route == route,
              onPressed: canSubmit ? () => _save(route) : null,
              onDisabledTap: onDisabledTap,
            ),
      ],
    );
  }

  /// 人员选择器：关键字为空且指定 [defaultDeptCode] 时收敛到该部门子树、否则全公司搜。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
    String? defaultDeptCode,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      hint: '请选择$label',
      sheetTitle: '选择$label',
      required: true,
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final deptId = (kw == null || kw.isEmpty) && defaultDeptCode != null
            ? (ref.read(departmentCodeIdMapProvider).valueOrNull ??
                  const {})[defaultDeptCode]
            : null;
        final res = await ref
            .read(employeeRepositoryProvider)
            .list(
              size: 30,
              search: kw,
              departmentId: deptId,
              includeSubtree: true,
            );
        return [
          for (final e in res.items)
            UtenEmployeePickerItem(
              id: e.id,
              name: e.fullName,
              employeeCode: e.code,
              departmentName: e.departmentName,
            ),
        ];
      },
      onChanged: (item) {
        if (item != null) _empCache[item.id] = item;
        onChanged(item?.id);
      },
    );
  }
}

/// 一行到货登记明细：共用的入库仓库/库位/实称重量状态 + 数量/来源/系列。
class _ArrivalReceiptLine extends InboundRegistrationLine {
  _ArrivalReceiptLine(this.item, {String? warehouseId, required this.onChanged})
    : qty = UtenAutofillTextController(
        text: procurementQty(item.approvedRemainingQty),
        autofilled: false,
      ),
      series = UtenAutofillTextController(text: item.goodsSeries ?? ''),
      super(
        warehouseId: warehouseId?.isNotEmpty == true ? warehouseId : null,
        warehouseAutofilled: true,
        place: item.goodsStockPlace ?? '',
      ) {
    qty.addListener(onChanged);
    weight.addListener(onChanged);
  }

  final ProcurementReceiptPrefillItem item;
  final VoidCallback onChanged;

  /// 本次实收(行单位)；按称重改过时黄框待核对。
  final UtenAutofillTextController qty;
  WarehouseArrivalSource source = WarehouseArrivalSource.automatic;
  final UtenAutofillTextController series;

  /// 1 个行单位 = 多少基本单位(无效值按 1)。
  double get unitRate {
    final rate = item.unitRate.toDouble();
    return rate.isFinite && rate > 0 ? rate : 1;
  }

  /// 本次实收折成基本单位(称重核对用)；没填为 null。
  double? get qtyBase {
    final value = double.tryParse(qty.text.trim());
    return value == null ? null : value * unitRate;
  }

  @override
  String get goodsId => item.goodsId;
  @override
  String? get colorId => item.colorId;
  @override
  String get goodsName => item.goodsName;

  @override
  void dispose() {
    qty.removeListener(onChanged);
    weight.removeListener(onChanged);
    qty.dispose();
    series.dispose();
    super.dispose();
  }
}
