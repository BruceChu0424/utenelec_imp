// 仓库批量登记实际到货页（/warehouse/inbound/receipts/batch）。
//
// 2026-09-27 用户口径「产成品入库与采购/委外入库 UI、逻辑、表格、记忆都一样」：本页与
// 产成品批量登记页(production_finished_arrival_batch_registration_page)同一骨架，
// 路线按钮 / 共用列 / 仓库格 / 库位建议 / 选仓记忆都走 inbound_registration_* 共用层；
// 改仓后按「该仓 × 货品 × 颜色记住的库位 → 货品资料通用库位」重新带出库位(黄框待核对)。
//
// 入库任务中心「预计到货」多选「先质检后入库」/「先入库后质检」的落点（2026-09-06）：把多张
// 采购/委外订货单的待登记明细汇成一张行级表——本次实收默认=批准剩余、入库仓库
// 行级必填（建议仓预填；**勾选多行后在其中任意一行改仓/写库位即整批落值**，
// 2026-09-11 起不再有表头上方的批量按钮，并记住上次所落仓与库位下次自动带），
// 一次提交按
// 「订货单 × 入库仓库」分组逐张登记并送检（与单张登记页同一条
// registerArrival + 内容派生幂等键链路；部分失败可原地重试不重复登记）。
// 仅断点「已登记 · 待送检」的草稿单不走本页（列表内直接批量送检）。
// 实称重量(ADR-135)与单张页同一口径：数量组之后录净重(可选)，按各行订货单供应商
// 学到的单重核对；称重计数默认只记重量；重量与「按称重改数量」随明细提交并计入幂等键。
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
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
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
import '../providers/warehouse_count_refresh.dart';
import '../repositories/warehouse_place_suggestion_repository.dart';
import '../widgets/batch_place_fill_dialog.dart';
import '../widgets/inbound_registration_widgets.dart';
import '../widgets/warehouse_autofill_text_field.dart';
import '../widgets/warehouse_arrival_source_field.dart';
import '../repositories/procurement_inbound_repository.dart';

class WarehouseArrivalBatchReceiptPage extends ConsumerStatefulWidget {
  const WarehouseArrivalBatchReceiptPage({
    super.key,
    this.prefills,
    this.canRegister,
    this.stockInBeforeInspection = false,
  });

  /// 入库任务中心多选带入的预计到货预填（每张=一张订货单）；空 = 直达兜底。
  final List<ProcurementReceiptPrefill>? prefills;

  /// 仅供独立预览/测试覆盖；正式路由为空时从当前登录权限实时推导。
  final bool? canRegister;

  /// 任务中心进页时选定的路线(2026-09-20 用户口径：本页只显示所选那条路线的
  /// 提交按钮，不再并排两个)：true = 「先入库后质检(N)」直达(`?preStock=1`)，
  /// 库位列进页即必填红框；false = 「先质检后入库(N)」(原「批量登记送检」)直达，
  /// 走原登记送检流程。
  final bool stockInBeforeInspection;

  @override
  ConsumerState<WarehouseArrivalBatchReceiptPage> createState() =>
      _WarehouseArrivalBatchReceiptPageState();
}

class _WarehouseArrivalBatchReceiptPageState
    extends ConsumerState<WarehouseArrivalBatchReceiptPage>
    with FormDraftMixin<WarehouseArrivalBatchReceiptPage> {
  @override
  bool get formDraftBusy => _saving;
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.arrivalBatch.spec(
    title: '批量登记实际到货',
    route: RouteName.warehouseArrivalReceiptBatch,
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
    'remark': _remark.text,
    'billDate': _billDate.toIso8601String(),
    'receiverId': _receiverId,
    'registrationId': _registrationId,
    'removedLineCount': _removedLineCount,
    'stockInBeforeInspection': _route.isStockInFirst,
    'employees': draftEmployees(_empCache),
    'prefills': {
      for (final line in _lines)
        line.prefill.expectationId: arrivalPrefillDraft(line.prefill),
    },
    'rows': draftGridRows(
      _lineGrid,
      (line) => {
        'expectationId': line.prefill.expectationId,
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
    _remark.text = draftText(data, 'remark');
    _billDate = DateTime.parse(draftText(data, 'billDate'));
    _receiverId = data['receiverId'] as String?;
    _registrationId = draftText(data, 'registrationId');
    _removedLineCount = data['removedLineCount'] as int? ?? 0;
    _route =
        data['stockInBeforeInspection'] == true && _canStockInBeforeInspection
        ? InboundRoute.stockInFirst
        : InboundRoute.inspectFirst;
    restoreDraftEmployees(_empCache, data['employees']);
    final prefills = draftMap(data['prefills']).map(
      (key, value) =>
          MapEntry(key, restoreArrivalPrefillDraft(draftMap(value))),
    );
    restoreDraftGrid(
      _lineGrid,
      data['rows'],
      (row) =>
          _BatchArrivalLine(
              prefills[draftText(row, 'expectationId')]!,
              restoreArrivalItemDraft(draftMap(row['item'])),
              onChanged: _onLineChanged,
            )
            ..qty.text = draftText(row, 'qty')
            ..setWarehouse(
              row['warehouseId'] as String?,
              autofilled: row['warehouseAutofilled'] == true,
            )
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
  final _lineGrid = UtenEditableGridController<_BatchArrivalLine>();
  late final _suggestions = InboundPlaceSuggestionLoader(
    ref.read(warehousePlaceSuggestionRepositoryProvider),
  );
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  DateTime _billDate = ChinaDateTime.today();
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

  /// 本页路线由任务中心进页时定死(2026-09-20 起底部只有一个提交按钮，与产成品批量页
  /// 同一口径)：「先入库后质检」= 登记送检的同一事务里把每行按库位上架(库位必填)；
  /// 「先质检后入库」= 原登记送检流程。进页或提交时发现没有独立权限则退回原流程并提示。
  InboundRoute _route = InboundRoute.inspectFirst;

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

  List<_BatchArrivalLine> get _lines => _lineGrid.rows;

  String? _warehouseLabel(String? id) =>
      inboundWarehouseLabel(ref.read(masterNameServiceProvider), id);

  // ---- 实称重量(ADR-135)：单重参数按「货品 × 该行订货单供应商」取，页面内缓存 ----

  /// 页面级单重参数缓存(build 里 watch，离开页面释放)。
  WeightParamsCache get _weightCache => ref.read(weightParamsCacheProvider);

  /// 单位 -> 重量单位(行单位本身按重量计时精确换算)。
  Map<String, WeightUnit> get _massUnits =>
      ref.read(warehouseUnitMassUnitsProvider).valueOrNull ?? const {};

  WeightParams? _paramsOf(_BatchArrivalLine line) =>
      _weightCache.of(line.goodsId, supplierId: line.prefill.supplierId);

  Iterable<WeightParamsLine> _weightParamsLines() => [
    for (final line in _lines)
      WeightParamsLine(
        goodsId: line.goodsId,
        supplierId: line.prefill.supplierId,
      ),
  ];

  void _ensureWeightParams() {
    if (!mounted) return;
    unawaited(_weightCache.ensure(_weightParamsLines()));
  }

  /// 按数量精确换算的重量(货品或行单位是重量单位)；需要实称时为 null。
  double? _exactKg(_BatchArrivalLine line) => warehouseExactLineKg(
    lineQty: double.tryParse(line.qty.text.trim()),
    lineMassUnit: _massUnits[line.item.unitId],
    unitRate: line.unitRate,
    params: _paramsOf(line),
  );

  /// 实际随明细提交的重量：精确换算行不带(服务端按数量算)，其余带实称千克。
  double? _sentKg(_BatchArrivalLine line) =>
      _exactKg(line) == null ? line.weight.kg : null;

  /// 幂等键的行重量片段(没称又没按称重改数量时为空串，键与不称重时一致)。
  String _weightKeyPart(_BatchArrivalLine line) {
    final part = warehouseWeightKeyPart(
      'w',
      _sentKg(line),
      line.weight.qtyFromWeight,
    );
    return part == null ? '' : ':$part';
  }

  String? _baseUnitName(_BatchArrivalLine line) {
    final base = line.item.baseUnitName?.trim();
    if (base != null && base.isNotEmpty) return base;
    return line.unitRate == 1 ? line.item.unitName : null;
  }

  /// 称重计数(到货口径)：默认「只记重量」，「按称重改数量」需显式点。
  Future<void> _weighCount(BuildContext context, _BatchArrivalLine line) =>
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
          supplierId: line.prefill.supplierId,
          warehouseId: line.warehouseId,
          baseUnitName: _baseUnitName(line),
          lineUnitName: line.item.unitName,
          unitRate: line.unitRate,
          currentQty: double.tryParse(line.qty.text.trim()),
          initialNetKg: line.weight.kg,
          sampleRemark: '到货登记 ${line.prefill.orderBillNo}',
        ),
        weight: line.weight,
        qty: line.qty,
        cache: _weightCache,
        refetch: _weightParamsLines(),
      );

  @override
  void initState() {
    super.initState();
    // 进页即定路线；没有独立权限时退回「先质检后入库」(任务中心本就不显示该入口)。
    _route = widget.stockInBeforeInspection && _canStockInBeforeInspection
        ? InboundRoute.stockInFirst
        : InboundRoute.inspectFirst;
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
    final prefills = widget.prefills;
    if (prefills == null || prefills.isEmpty) {
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
    final meId = ref.read(sessionProvider).user?.employeeId;
    if (meId != null && meId.isNotEmpty) {
      _receiverId = meId;
      await _preloadEmployees([meId]);
    }
    _lineGrid.replaceAll([
      for (final prefill in prefills)
        for (final item in prefill.items)
          _BatchArrivalLine(prefill, item, onChanged: _onLineChanged),
    ]);
    // 进页默认全选（2026-09-17，与订货单编辑页同款）：勾选=本次要登记送检的行，
    // 右下两个提交按钮只认勾选行；默认全选让「进来直接提交」行为不变。
    _lineGrid.setSelected(_lineGrid.rows, true);
    _ensureWeightParams();
    final selectable = WarehouseSelection(
      ref.read(masterNameServiceProvider).warehouseHierarchy,
    ).selectableIds;
    // 个人选仓上下文：只补空位，不覆盖来源建议仓(优先级见
    // inbound_warehouse_fill_memory.dart)。补进来的一律带黄标提示核对。
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
    if (mounted) setState(() => _loading = false);
    // 按行上的仓带出库位(该仓记住的库位 → 货品资料通用库位；手填/草稿值不覆盖)。
    await _suggestions.reload(_lines);
    if (mounted) await initializeFormDraft();
  }

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
        } catch (_) {}
      }),
    );
  }

  void _onLineChanged() {
    if (mounted) setState(() {});
  }

  /// 仅从本次批量登记移出：不写库、不改订货或到货累计（返回任务中心仍待登记）。
  void _removeFromThisRegistration(List<_BatchArrivalLine> rows) {
    if (_saving || !_canRegisterNow || rows.isEmpty) return;
    _lineGrid.removeRows(rows);
    if (!mounted) return;
    setState(() => _removedLineCount += rows.length);
    context.appInfo('已从本次登记移出 ${rows.length} 行；未写入数据库，返回任务中心后仍可继续登记送检');
  }

  /// 一次改动的落值范围（对齐新建采购订货单的 `_writeTargets`）。
  ///
  /// 2026-09-11 起本页不再有「批量设置入库仓库 / 批量填写库位」两个常驻按钮：
  /// **勾选若干行 → 在其中任意一行改仓/写库位 = 批量落到全部选中行**；
  /// 点的行不在选中集里（或压根没勾）就只改这一行。
  List<_BatchArrivalLine> _writeTargets(_BatchArrivalLine row) {
    final selected = _lineGrid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 行内选仓：落到 [_writeTargets]（选中一批就整批落仓），并记住这次选的仓。
  Future<void> _pickLineWarehouse(_BatchArrivalLine line) async {
    if (_saving) return;
    await _pickWarehouseFor(
      _writeTargets(line),
      fallbackWarehouseId: line.prefill.suggestedWarehouseId,
    );
  }

  /// 选仓核心（行内点击与右键「批量设置入库仓库」共用）：面板返回后落到目标行、
  /// 记住这次选的仓。
  Future<void> _pickWarehouseFor(
    List<_BatchArrivalLine> targets, {
    String? fallbackWarehouseId,
  }) async {
    if (_saving || targets.isEmpty) return;
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
      initialWarehouseId: targets.first.warehouseId ?? fallbackWarehouseId,
      title: targets.length > 1
          ? '批量设置入库仓库（选中 ${targets.length} 行）'
          : '选择入库仓库 · ${targets.first.item.goodsName}',
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

  /// 右键「批量设置库位号」：一次输入应用到全部选中行（整托同架场景），
  /// 只作用本次选中行(成功入库后按仓库、货品和颜色学习)。
  Future<void> _batchFillStockPlace(List<_BatchArrivalLine> rows) async {
    if (_saving || rows.isEmpty) return;
    final place = await showBatchPlaceFillDialog(
      context,
      rowCount: rows.length,
      inputKey: const Key('warehouse-arrival-batch-place-input'),
      applyKey: const Key('warehouse-arrival-batch-place-apply'),
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

  /// 行内写库位：同样落到 [_writeTargets]，并记住这次写的库位号。
  ///
  /// 逐字符同步到选中行（不等失焦），用户边打边能看到整批跟着变——与「改一行
  /// 就是改一批」的心智一致。只改本行时什么都不用做（控件自己持有文本）。
  void _onStockPlaceChanged(_BatchArrivalLine line, String value) {
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

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 按「订货单 × 入库仓库」分组（LinkedHashMap 保序）：每组一张收货单顺序登记。
  /// 只对本次要提交的行分组（勾选行，2026-09-17 起提交集=勾选集）。
  Map<String, List<_BatchArrivalLine>> _buildGroups(
    List<_BatchArrivalLine> lines,
  ) {
    final groups = <String, List<_BatchArrivalLine>>{};
    for (final line in lines) {
      final key = '${line.prefill.orderId}:${line.warehouseId}';
      groups.putIfAbsent(key, () => []).add(line);
    }
    return groups;
  }

  /// 行级跨仓预定检测（实收超过所选仓的分析预定量）：确认框警示用。
  bool _hasCrossWarehouseAllocation(List<_BatchArrivalLine> lines) {
    for (final line in lines) {
      final qty = double.tryParse(line.qty.text.trim()) ?? 0;
      final allocations = warehouseInboundAllocationForWarehouse(
        line.item.expectedAllocations,
        qty,
        actualWarehouseId: line.warehouseId,
        actualWarehouseName: _warehouseLabel(line.warehouseId) ?? '',
        sameMainWarehouse: (target, actual) => warehousesShareMain(
          ref.read(masterNameServiceProvider).warehouseHierarchy,
          target,
          actual,
        ),
        unitRate: line.item.unitRate.toDouble(),
      );
      if (allocations.any((a) => a.isCrossWarehouse)) return true;
    }
    return false;
  }

  Future<void> _save() async {
    if (!_canRegisterNow) {
      context.appError('当前账号没有登记并送检权限，请返回任务中心刷新权限');
      return;
    }
    if (_route.isStockInFirst && !_canStockInBeforeInspection) {
      // 路线进页已定，这里只会因权限被收回而退回原流程：说明原因并换成
      // 「先质检后入库」按钮，由用户决定是否继续，不静默换路线提交。
      setState(() => _route = InboundRoute.inspectFirst);
      context.appWarning('当前账号没有「到货先入库后质检」权限，已切换为「先质检后入库」，请确认后再提交');
      return;
    }
    if (_suggestions.loading) {
      context.appInfo('正在读取所选仓库的默认库位，请稍候再提交');
      return;
    }
    if (_receiverId == null || _receiverId!.isEmpty) {
      context.appError('请选择收货人(仓库收货人)');
      return;
    }
    if (_lines.isEmpty) {
      context.appError('没有可登记明细，请返回任务中心刷新');
      return;
    }
    // 勾选=本次要登记送检的行（2026-09-17，与订货单编辑页同款）：右下两个
    // 提交按钮没勾行时已置灰，这里再兜一层；未勾选行不进校验也不进提交。
    final submitLines = _lineGrid.selectedRows;
    if (submitLines.isEmpty) {
      context.appError('请先勾选要登记送检的明细行（未勾选的行本次不登记）');
      return;
    }
    final submitted = submitLines.toSet();
    final excludedCount = _lines.length - submitLines.length;
    // 明细整表扫完再报：原先首个违规就 return，批量几十行时用户补一行提交一次，
    // 观感像「怎么老是报错」。判定条件不变，只把问题按类别各汇总成一条。
    final badQty = <String>[];
    final missingWarehouse = <String>[];
    final missingPlace = <String>[];
    final stockInFirst = _route.isStockInFirst;
    for (var index = 0; index < _lines.length; index++) {
      final line = _lines[index];
      if (!submitted.contains(line)) continue;
      final label =
          '第 ${index + 1} 行（${line.prefill.orderBillNo} ${line.item.goodsName}）';
      final qty = double.tryParse(line.qty.text.trim()) ?? 0;
      if (qty <= 0) badQty.add(label);
      if (line.warehouseId == null || line.warehouseId!.isEmpty) {
        missingWarehouse.add(label);
      }
      // 先入库后质检：库位是实物落点，逐行必填。
      if (stockInFirst && line.place.text.trim().isEmpty) {
        missingPlace.add(label);
      }
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
    // 采购收货单必须有采购员（批量页取订货负责人预填，不可编辑）；
    // 只看本次要提交的行——整单都没勾时该单不建收货单，不该被拦。
    final missingPurchaser = submitLines
        .where(
          (line) =>
              line.prefill.orderType == ProcurementInboundOrderType.purchase &&
              (line.prefill.purchaserId?.isNotEmpty != true),
        )
        .map((line) => line.prefill.orderBillNo)
        .toSet();
    if (missingPurchaser.isNotEmpty) {
      context.appError('订货单 ${missingPurchaser.join('、')} 缺少采购员，请先在单张登记页处理');
      return;
    }
    final groups = _buildGroups(submitLines);
    final hasCrossWarehouse = _hasCrossWarehouseAllocation(submitLines);
    // 2026-09-11：原来是一整段连排文字，弹窗被顶得巨长。改成「一句结论 + 短要点」，
    // 高度与宽度由 UtenDialog 统一兜（限宽 460 / 限高 60% 屏高 / 超出自滚）。
    final confirmed = await UtenDialog.show(
      context,
      title: '${_route.label}(${groups.length} 张收货单)',
      confirmLabel: stockInFirst ? '确认登记并先入库' : '确认登记送检',
      content: InboundConfirmPoints([
        // 有未勾选行时先说清去向，防「取消勾选=静默不登记」。
        if (excludedCount > 0)
          '有 $excludedCount 行未勾选：本次不登记、不写库存，仍留在任务中心待登记送检，可稍后办理。',
        ...(stockInFirst
            ? const [
                '按「订货单 × 入库仓库」分组建单，同一事务内登记到货、送品质部待检，并把每行实物按库位号上架(先入库后质检)。',
                '品质部到库位检验：合格后系统自动按上架位置转正入库，不合格由仓库从库位取出登记退回。',
                '实到超批准量的单自动隔离并通知财务审核组：隔离单不上架、不入库、不生成应付，也不影响其余单。',
              ]
            : const [
                '按「订货单 × 入库仓库」分组建单，同一事务内登记到货并直送品质部待检(IQC)。',
                '检验合格后转仓库待入库；仓库确认实物与库位后库存才增加。',
                '实到超批准量的单自动隔离并通知财务审核组：不入库、不生成应付，也不影响其余单。',
              ]),
      ], extra: hasCrossWarehouse ? '部分行实收超过所选仓的分析预定量，跨仓部分只作预计、转公共库存。' : null),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    final registrations = <WarehouseArrivalRegistration>[];
    try {
      await saveFormDraftNow();
      final repo = ref.read(procurementInboundRepositoryProvider);
      for (final entry in groups.entries) {
        final lines = entry.value;
        final first = lines.first;
        final prefill = first.prefill;
        final isPurchase =
            prefill.orderType == ProcurementInboundOrderType.purchase;
        // 幂等键按「订货单+仓库+行+数量(+实称重量)」内容派生：响应丢失重试复用同键
        // 安全重放；部分失败后原地重试，已成功组合按同键重放、不会重复登记。
        final canonical = [
          _registrationId,
          '${prefill.orderType.name}:${entry.key}',
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
          'warehouseId': lineWarehouseOf(lines),
          'supplierId': prefill.supplierId,
          'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
          if (isPurchase) ...{
            'purchaserId': prefill.purchaserId,
            'receiverEmployeeId': _receiverId,
          } else
            // 委外进仓单主档仅 sender_id 一个人员列（按「收货人」语义解析）。
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
                'sourceDocNo': prefill.orderBillNo,
                if (line.item.colorId != null) 'colorId': line.item.colorId,
                if (line.item.unitId != null) 'unitId': line.item.unitId,
                if (!isPurchase) 'unitRate': line.item.unitRate,
                // 实称净重(千克 4 位；没称不带，精确换算行不带)与「按称重改数量」。
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
            if (!mounted) return;
            if (registrations.isNotEmpty) {
              context.appWarning(
                '已登记送检 ${registrations.length} 张收货单；其余已取消，修改数量后可直接重试',
              );
            }
            return;
          }
          registrations.add(registration);
        } on ApiException catch (e) {
          if (!mounted) return;
          if (registrations.isNotEmpty) {
            context.appError(
              '已登记送检 ${registrations.length} 张收货单；'
              '订货单「${prefill.orderBillNo}」仓库'
              '「${_warehouseLabel(lineWarehouseOf(lines)) ?? '—'}」登记失败：${e.message}。'
              '可直接重试，已成功部分不会重复登记',
            );
          } else {
            context.appError(e.message);
          }
          return;
        }
      }
      // 学习回写只针对实际登记了的行（未勾选行不产生本次事实）。
      unawaited(_learnGoodsProfiles(submitLines));
      if (!mounted) return;
      await completeFormDraft();
      if (!mounted) return;
      bumpListRefresh(
        ref,
        PurchaseDocConfig.by(PurchaseDocType.receipt).refreshKey,
      );
      bumpListRefresh(
        ref,
        SubcontractDocConfig.by(SubcontractDocType.receipt).refreshKey,
      );
      invalidateWarehouseTaskCounts(ref);
      final batch = WarehouseArrivalRegistrationBatch(
        registrations: registrations,
      );
      if (context.canPop()) {
        context.pop(batch);
      } else {
        context.go(RouteName.warehouseInboundExpectations);
      }
    } catch (_) {
      if (mounted) context.appError('批量登记失败，请保持当前内容后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? lineWarehouseOf(List<_BatchArrivalLine> lines) =>
      lines.first.warehouseId;

  /// 学习回写（best-effort）：仅上报用户实际填了值的字段；失败不阻断主流程。
  Future<void> _learnGoodsProfiles(List<_BatchArrivalLine> lines) async {
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
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // 单重参数缓存与单位字典随页面存活；录入/显示单位是用户偏好。
    ref.watch(weightParamsCacheProvider);
    ref.watch(warehouseUnitMassUnitsProvider);
    final theme = Theme.of(context);
    final canRegister = widget.canRegister ?? _canRegisterNow;
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '批量登记实际到货',
          // 2026-09-20：路线在任务中心已选定，标题下标明本页走哪条，底部只此一个提交按钮。
          subtitle: '路线：${_route.label}',
          leading: UtenBackButton(
            onPressed: () => popOrBackTo(
              context,
              defaultPath: RouteName.warehouseInboundExpectations,
            ),
          ),
        ),
        body: SafeArea(
          child: _lines.isEmpty && !_loading
              ? _missingPrefill(context)
              : _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : Stack(
                  children: [
                    AbsorbPointer(
                      absorbing: _saving || !canRegister,
                      child: _buildForm(context, theme, canRegister),
                    ),
                    // 提交期间全屏加载遮罩（整批到货登记事务）。
                    if (_saving)
                      const UtenBusyOverlay(
                        title: '正在批量登记到货',
                        description: '正在按实收数量整批登记送检，请勿重复提交或离开本页。',
                      ),
                  ],
                ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        // 提交集=勾选集（2026-09-17）：监听表格选择集，一行都没勾时右下两个
        // 提交按钮置灰（灰态点击说明原因），勾回任意行立即恢复。
        floatingActionButton: _lines.isEmpty
            ? null
            : ListenableBuilder(
                listenable: Listenable.merge([_lineGrid, _suggestions]),
                builder: (context, _) => _buildBottomBar(canRegister),
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
          const Text('请从「入库任务中心」多选预计到货任务后批量登记'),
          const SizedBox(height: UtenSpacing.s16),
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.arrow_back_rounded,
            onPressed: () => context.go(RouteName.warehouseInboundTasks),
            child: const Text('返回任务中心'),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, ThemeData theme, bool canRegister) {
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    return UtenGridPageScrollbar(
      pinned: _gridPinned,
      controller: _scrollCtl,
      // 滚动条贴屏幕右缘（2026-09-15）：包装在内容容器之外，右缘窄条
      // 恒在屏幕最右，不随限宽容器/列宽漂移。
      child: UtenContentContainer(
        child: ListView(
          controller: _scrollCtl,
          padding: const EdgeInsets.all(UtenSpacing.s12),
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
                        _employeePicker(
                          label: '收货人',
                          currentId: _receiverId,
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
            InboundPlaceSuggestionStatus(
              loader: _suggestions,
              onRetry: () => _suggestions.reload(_lines),
            ),
            // 来源单据张数 + 勾选口径(与产成品批量页同一句式)。
            InboundGridIntro(
              sourceSummary: '来自 $_orderCount 张订货单',
              submitLabel: _route.label,
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenEditableGrid<_BatchArrivalLine>(
              key: const Key('warehouse-arrival-batch-lines-grid'),
              controller: _lineGrid,
              stickyHeaderPinned: _gridPinned,
              columns: _lineColumns(canRegister, weightUnits.entry),
              createBlankRow: () => throw UnsupportedError('明细由所选预计到货任务固定带入'),
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
              // 2026-09-11 表头上方四个常驻按钮全撤：「全选/取消全选」由表头
              // 复选框承担，「移出本次登记」搬进行右键菜单，「批量设置入库仓库 /
              // 批量填写库位」改成「勾选多行后在任意一行改仓/写库位即批量落值」。
              // 2026-09-12 再补右键菜单显式批量入口（与产成品登记页统一口径）。
              showSelectAllToggle: false,
              showRemoveRowsAction: false,
              // 2026-09-14：行末常驻 ⊖（走同一条「移出本次登记」确认与回调）。
              showInlineRemoveAction: true,
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
              emptyMessage: '没有可登记明细，请返回任务中心刷新',
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
                        inboundTotalsBar<_BatchArrivalLine>(
                          key: const Key('warehouse-arrival-batch-totals'),
                          lines: _lines,
                          qtyLabel: '本次实收',
                          qtyOf: (line) =>
                              double.tryParse(line.qty.text.trim()) ?? 0,
                          unitIdOf: (line) => line.item.unitId,
                          unitNameOf: (line) => line.item.unitName,
                          weight: warehouseWeightTotals<_BatchArrivalLine>(
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

  int get _orderCount =>
      _lines.map((line) => line.prefill.orderId).toSet().length;

  // 明细表列(与产成品批量页同一套共用列，列名/列序/格式一致)：来源订货单 → 类型 →
  // 货品名称 → 编号 → 颜色 → 批准剩余 → 到货来源 → 本次实收 → 单位 → 实称重量 →
  // 称重核对 → 入库仓库 → 库位号 → 物料系列。表头快速筛选只做视图级过滤，不动行数据、
  // 输入值与勾选。
  List<EditableGridColumn<_BatchArrivalLine>> _lineColumns(
    bool canRegister,
    WeightUnit weightEntryUnit,
  ) {
    final names = ref.read(masterNameServiceProvider);
    final shared = InboundGridColumns<_BatchArrivalLine>(
      names: names,
      keyPrefix: 'warehouse-arrival-batch',
      lineKeyOf: (line) => line.item.orderItemId,
      goodsCodeOf: (line) => line.item.goodsCode,
      colorNameOf: (line) => line.item.colorName,
      unitNameOf: (line) => line.item.unitName,
    );
    bool editable(_BatchArrivalLine line) => canRegister && !_saving;
    final stockInFirst = _route.isStockInFirst;
    return [
      EditableGridColumn(
        key: 'order',
        label: '来源订货单',
        width: 150,
        filterValueOf: (line) => inboundBucket(line.prefill.orderBillNo),
        cellBuilder: (context, line) => Tooltip(
          message:
              '${line.prefill.orderType.label} · ${line.prefill.orderBillNo}',
          child: Text(
            line.prefill.orderBillNo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        textOf: (line) => line.prefill.orderBillNo,
      ),
      EditableGridColumn(
        key: 'orderType',
        label: '类型',
        width: 80,
        filterValueOf: (line) => line.prefill.orderType.label,
        textOf: (line) => line.prefill.orderType.label,
        cellBuilder: (context, line) => Text(line.prefill.orderType.label),
      ),
      shared.goodsName(),
      shared.goodsCode(),
      shared.color(),
      shared.quantity(
        key: 'approvedRemainingQty',
        label: '批准剩余',
        textOf: (line) => inboundQty(line.item.approvedRemainingQty),
      ),
      EditableGridColumn(
        key: 'arrivalSource',
        label: workflowFieldText(context).warehouseArrivalSourceLabel,
        width: 165,
        // 每行相同的通用说明放列头 ⓘ：格内只留行特有的错误/预填图标。
        headerInfo: workflowFieldText(context).warehouseArrivalSourceHint,
        textOf: (line) => line.source.label(context),
        cellBuilder: (context, line) => WarehouseArrivalSourceField(
          key: ValueKey(
            'warehouse-arrival-batch-source-${line.item.orderItemId}',
          ),
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
      shared.unit(),
      // 实称重量跟在数量组之后；按该行订货单供应商学到的单重核对(称重核对列)。
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
        // 改离订货单建议仓描橙边：合格库存不再计入原物料分析目标仓备料。
        changedAwayOf: (line) {
          final suggested = line.prefill.suggestedWarehouseId;
          final actual = line.warehouseId;
          return suggested != null &&
              suggested.isNotEmpty &&
              actual != null &&
              !warehousesShareMain(names.warehouseHierarchy, actual, suggested);
        },
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
        width: 120,
        textOf: (line) => line.series.text,
        listenableOf: (line) => line.series,
        // 预填黄标 ⓘ(44)计入量宽。
        chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
        cellBuilder: (context, line) => Semantics(
          textField: true,
          label: '${line.goodsName} 物料系列',
          child: WarehouseAutofillTextField(
            controller: line.series,
            source: '系列来自货品资料，请核对本次到货',
            enabled: editable(line),
          ),
        ),
      ),
    ];
  }

  Widget _buildBottomBar(bool canRegister) {
    // 右下悬浮：取消 + 进页时所选路线的唯一提交按钮(与产成品批量页同一组件)。
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
        InboundRouteSubmitButton(
          route: _route,
          isLoading: _saving,
          onPressed: canSubmit ? _save : null,
          onDisabledTap: onDisabledTap,
        ),
      ],
    );
  }

  /// 人员选择器：关键字为空时收敛到仓储部子树、否则全公司搜。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      hint: '请选择$label',
      sheetTitle: '选择$label',
      required: true,
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final deptId = (kw == null || kw.isEmpty)
            ? (ref.read(departmentCodeIdMapProvider).valueOrNull ??
                  const {})[kDeptCodeWarehouse]
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

/// 一行批量到货登记明细：挂来源订货单预填 + 共用的入库仓库/库位/实称重量状态 +
/// 数量/系列。
class _BatchArrivalLine extends InboundRegistrationLine {
  _BatchArrivalLine(this.prefill, this.item, {required this.onChanged})
    : qty = UtenAutofillTextController(
        text: procurementQty(item.approvedRemainingQty),
        autofilled: false,
      ),
      series = UtenAutofillTextController(text: item.goodsSeries ?? ''),
      super(
        warehouseId:
            item.lastReceiptWarehouseId ??
            (prefill.suggestedWarehouseId?.isNotEmpty == true
                ? prefill.suggestedWarehouseId
                : prefill.warehouseId),
        warehouseAutofilled: true,
        place: item.goodsStockPlace ?? '',
      ) {
    qty.addListener(onChanged);
    weight.addListener(onChanged);
  }

  final ProcurementReceiptPrefill prefill;
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
