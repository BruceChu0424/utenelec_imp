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
//   - 单位紧跟「本次实收」列展示；不设「实际重量」列——2026-09-05 起重量统计走
//     单位的数量/重量维度（基础资料-单位），重量型单位的数量本身即重量；
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

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/required_field_decoration.dart';
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
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/models/inbound_allocation.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../providers/warehouse_arrival_fill_memory.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../widgets/batch_place_fill_dialog.dart';
import '../widgets/warehouse_inbound_allocation_view.dart';
import '../widgets/warehouse_autofill_text_field.dart';
import '../widgets/warehouse_arrival_source_field.dart';

/// 批量校验提示：把同一类违规的**全部**行汇总成一句话。
///
/// 条目多时只列前 8 条再折成「等 N 行」——刷屏的提示和只报第一行一样没法用。
String _rowIssueMessage(
  List<String> rowLabels,
  String issue, {
  required String action,
}) {
  const shownMax = 8;
  final shown = rowLabels.take(shownMax).join('、');
  final more = rowLabels.length > shownMax ? '等 ${rowLabels.length} 行' : '';
  return '以下 ${rowLabels.length} 行$issue，$action：$shown$more';
}

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
    extends ConsumerState<WarehouseArrivalReceiptPage> {
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
  final String _registrationId = const Uuid().v4();
  int _removedLineCount = 0;

  /// 先入库后质检(V596)：底部两个按钮二选一——「先入库后质检」= 登记送检的同一事务里
  /// 把每行按库位上架(库位必填)；「先质检后入库」(2026-09-20 前叫「登记并送检」)= 原流程。
  /// 记住最近一次点的是哪个，库位列是否必填(红框)跟着它走。
  bool _stockInBeforeInspection = false;

  final UtenEditableGridController<_ArrivalReceiptLine> _lineGrid =
      UtenEditableGridController<_ArrivalReceiptLine>();

  List<_ArrivalReceiptLine> get _lines => _lineGrid.rows;

  bool get _isPurchase =>
      widget.prefill?.orderType == ProcurementInboundOrderType.purchase;

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
    final id = widget.prefill?.suggestedWarehouseId;
    return id == null || id.isEmpty ? null : id;
  }

  /// 行的有效入库仓库：2026-09-06 起行级必填（表头默认仓已删），
  /// 建议仓（物料分析目标仓）在 _init 时已逐行预填。
  String? _effectiveWarehouseId(_ArrivalReceiptLine line) => line.warehouseId;

  String? _warehouseLabel(String? id) {
    if (id == null || id.isEmpty) return null;
    final names = ref.read(masterNameServiceProvider);
    return warehouseFullLabel(names.warehouseHierarchy, id) ??
        names.warehouse(id);
  }

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
    sourceOrderNo: widget.prefill?.orderBillNo,
    allocations: _lineProjectedAllocations(line),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remark.dispose();
    _scrollCtl.dispose();
    _lineGrid.dispose();
    _gridPinned.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final prefill = widget.prefill;
    if (prefill == null) return;
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
    final selectable = WarehouseSelection(
      ref.read(masterNameServiceProvider).warehouseHierarchy,
    ).selectableIds;
    // 个人选仓上下文只补空位：行内已有值（上次收货仓 / 建议仓 / 货品资料带出的
    // 库位）优先级都更高，见 warehouse_arrival_fill_memory.dart。
    final memory = ref.read(warehouseArrivalFillMemoryProvider);
    final rememberedWarehouse = selectable.contains(memory.warehouseId)
        ? memory.warehouseId
        : null;
    for (final line in _lineGrid.rows) {
      if (!selectable.contains(line.warehouseId)) {
        line.warehouseId = rememberedWarehouse;
        line.warehouseAutofilled = rememberedWarehouse != null;
      }
    }
    _removedLineCount = 0;
    await _preloadEmployees([prefill.purchaserId, meId]);
    if (mounted) setState(() => _loading = false);
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
          target.setCheckedStockPlace(value);
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
          : '选择入库仓库 · ${targets.first.item.goodsName}',
    );
    if (picked == null || !mounted) return;
    setState(() {
      for (final target in targets) {
        if (target.warehouseId != picked.id && target.stockPlace.autofilled) {
          target.stockPlace.clear();
        }
        target.warehouseId = picked.id;
        target.warehouseAutofilled = false;
      }
    });
    ref
        .read(warehouseArrivalFillMemoryProvider.notifier)
        .rememberWarehouse(picked.id);
    if (targets.length > 1) {
      context.appInfo('已把入库仓库写到选中的 ${targets.length} 行');
    }
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
        line.setCheckedStockPlace(place);
      }
    });
  }

  /// [preStock] 为真 = 「先入库后质检」按钮，否则 = 「先质检后入库」按钮(原「登记并送检」)。
  Future<void> _save({required bool preStock}) async {
    if (!_canRegisterNow) {
      context.appError('当前账号没有登记并送检权限，请返回任务中心刷新权限');
      return;
    }
    final wantPreStock = preStock && _canStockInBeforeInspection;
    if (_stockInBeforeInspection != wantPreStock) {
      // 先切模式再校验：缺库位的行立刻红框，用户补齐后再点同一个按钮。
      setState(() => _stockInBeforeInspection = wantPreStock);
    }
    final prefill = widget.prefill;
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
    final stockInFirst =
        _stockInBeforeInspection && _canStockInBeforeInspection;
    for (var index = 0; index < _lines.length; index++) {
      final line = _lines[index];
      if (!submitted.contains(line)) continue;
      final label = '第 ${index + 1} 行（${line.item.goodsName}）';
      final qty = double.tryParse(line.qty.text.trim()) ?? 0;
      if (qty <= 0) badQty.add(label);
      // 先入库后质检：库位是实物落点，逐行必填(原流程仍只是学习字段)。
      if (stockInFirst && line.stockPlace.text.trim().isEmpty) {
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
        _rowIssueMessage(badQty, '的本次实收不是大于 0 的数字', action: '请改正后再提交'),
      if (missingWarehouse.isNotEmpty)
        _rowIssueMessage(missingWarehouse, '未选择入库仓库', action: '请补齐后再提交'),
      if (missingPlace.isNotEmpty)
        _rowIssueMessage(missingPlace, '未填写上架库位(先入库后质检必填)', action: '请补齐后再提交'),
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
      title: stockInFirst ? '登记并先入库' : '登记并送检',
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
      final repo = ref.read(procurementInboundRepositoryProvider);
      for (final entry in groups.entries) {
        final lines = entry.value;
        // 幂等键按「仓库+行+数量」内容派生：响应丢失重试复用同键安全重放；
        // 部分仓库失败后原地重试，已成功仓按同键重放、不会重复登记。
        final canonical = [
          _registrationId,
          entry.key,
          if (stockInFirst) 'stock-in-first',
          for (final line in lines)
            '${line.item.orderItemId}:${(double.tryParse(line.qty.text.trim()) ?? 0)}'
                '${line.source.apiValue == null ? '' : ':${line.source.apiValue}'}',
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
                if (stockInFirst) 'preStockPlace': line.stockPlace.text.trim(),
                if (line.source.apiValue != null)
                  'replacementIntent': line.source.apiValue,
                // 来源单据编号谱系（来源订货单号），与编辑页口径一致。
                'sourceDocNo': prefill.orderBillNo,
                if (line.item.colorId != null) 'colorId': line.item.colorId,
                if (line.item.unitId != null) 'unitId': line.item.unitId,
                // 委外进仓明细带单位换算率（与委外编辑页口径一致）；采购收货不需要。
                if (!_isPurchase) 'unitRate': line.item.unitRate,
                // 不带 price/weight：价格对仓库不可见（审核时服务端按订货明细权威
                // 回填）；重量统计走单位的数量/重量维度，不在登记页录实称重量。
              },
          ],
        };
        try {
          registrations.add(
            await repo.registerArrival(
              orderType: prefill.orderType,
              body: body,
            ),
          );
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
          if (line.goodsCode.text.trim().isNotEmpty)
            'goodsCode': line.goodsCode.text.trim(),
          if (line.series.text.trim().isNotEmpty)
            'series': line.series.text.trim(),
          if (line.stockPlace.text.trim().isNotEmpty)
            'stockPlace': line.stockPlace.text.trim(),
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
    final prefill = widget.prefill;
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
    return Scaffold(
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
              listenable: _lineGrid,
              builder: (context, _) =>
                  _buildBottomBar(theme, canRegister, canPreStock),
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
            _arrivalBanner(theme, prefill),
            const SizedBox(height: UtenSpacing.s12),
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
            // 「明细(N 行)」标题与表格上方的「统一设置入库仓库」按钮 2026-09-11
            // 一并撤除：落仓/填库位改由表格操作条的批量动作承载（勾选若干行后
            // 作用于选中行，未勾选时沿用旧口径作用于全部明细行）。
            const SizedBox(height: UtenSpacing.s8),
            // 2026-09-14：提示行改为常驻（原先只在 <840 窄屏出现，宽屏桌面
            // 完全看不到「可以只登记一部分」这件事）。
            LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        '明细默认全选：右下「先入库后质检 / 先质检后入库」只提交勾选的行，'
                        '未勾选的行不登记、不写库存，仍留在待登记送检（可重新勾回）；'
                        '本次不收的货品也可以点行末 ⊖ 把该行移出本次登记'
                        '（可勾选多行后右键批量移出）。移出不删除订货明细、不写库存。'
                        '${constraints.maxWidth < 840 ? '表格可左右滑动；' : ''}'
                        '数量、入库仓库、库位、系列和物料编码可直接编辑。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            UtenEditableGrid<_ArrivalReceiptLine>(
              key: const Key('warehouse-arrival-lines-grid'),
              controller: _lineGrid,
              stickyHeaderPinned: _gridPinned,
              columns: _arrivalLineColumns,
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
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _lineTotalsBar(),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    _removedLineCount == 0
                        ? '库位、系列、编码由货品资料带出，可直接修改；送检后会学习回写，下次自动带出。'
                              '明细默认全选，提交只含勾选行。'
                        : '已移出 $_removedLineCount 行（仅本页临时选择）；这些来源行未写收货、未写库存，仍在待登记送检。'
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

  Widget _arrivalBanner(ThemeData theme, ProcurementReceiptPrefill prefill) {
    return Semantics(
      container: true,
      label:
          '请按实际到货数量登记；数量单位由货品单位的数量/重量维度决定。'
          '超出财务批准剩余量时不会直接入库，'
          '系统会隔离并通知财务审核组共享处理。',
      child: Card(
        color: theme.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.fact_check_outlined,
                color: theme.colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '请按实际到货数量登记',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '来源订货单：${prefill.orderBillNo}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '本页登记带单位的数量与库位，不涉及价格与金额；'
                      '重量统计由单位的数量/重量维度承载，无需另填实称重量。'
                      '实到数量超过财务批准剩余量时仍可如实填写——超出部分不会入库、'
                      '不会生成应付，系统会自动隔离并通知财务审核组共享处理。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<EditableGridColumn<_ArrivalReceiptLine>> get _arrivalLineColumns => [
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    EditableGridColumn(
      key: 'goods',
      label: '货品名称',
      width: 200,
      textOf: (line) => line.item.goodsName,
      cellBuilder: (context, line) => Tooltip(
        message: line.item.goodsName,
        // 单行省略号（2026-09-16 全站口径）：列宽随 textOf 自动加宽兜底。
        child: Text(
          line.item.goodsName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    EditableGridColumn(
      key: 'goodsCode',
      label: '编号',
      width: 160,
      // 2026-09-16 用户口径：编号是货品资料的身份快照，登记页**只读**——
      // 与批量登记页同款（此前是可编辑核对框）。值仍由行模型 goodsCode
      // 控制器承载（保存链路不变），只是格内不再可敲。
      textOf: (line) => line.goodsCode.text,
      listenableOf: (line) => line.goodsCode,
      cellBuilder: (context, line) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: line.goodsCode,
        builder: (context, value, _) => Semantics(
          label: '${line.item.goodsName} 物料编码',
          child: Tooltip(
            message: value.text,
            child: Text(
              value.text.isEmpty ? '—' : value.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: value.text.isEmpty
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    ),
    EditableGridColumn(
      key: 'color',
      label: '颜色',
      width: 110,
      textOf: (line) => line.item.colorName ?? '—',
      cellBuilder: (context, line) => Text(line.item.colorName ?? '—'),
    ),
    EditableGridColumn(
      key: 'approvedRemainingQty',
      label: '批准剩余',
      width: 110,
      numeric: true,
      cellBuilder: (context, line) => Text(
        procurementQty(line.item.approvedRemainingQty),
        textAlign: TextAlign.right,
      ),
    ),
    EditableGridColumn(
      key: 'arrivalSource',
      label: workflowFieldText(context).warehouseArrivalSourceLabel,
      width: 165,
      // 每行相同的通用说明放列头 ⓘ（2026-09-10 全站口径）：格内只留行特有的
      // 错误/预填图标，来源下拉不再自带 44px 说明图标挤占选项文案。
      headerInfo: workflowFieldText(context).warehouseArrivalSourceHint,
      textOf: (line) => line.source.label(context),
      cellBuilder: (context, line) => WarehouseArrivalSourceField(
        key: ValueKey('warehouse-arrival-source-${line.item.orderItemId}'),
        value: line.source,
        enabled: _canRegisterNow && !_saving,
        onChanged: (source) => setState(() => line.source = source),
      ),
    ),
    EditableGridColumn(
      key: 'qty',
      label: '本次实收',
      width: 130,
      numeric: true,
      required: true,
      // 每行相同的通用说明放列头 ⓘ（2026-09-10 全站口径），格内不再塞 44px 图标
      // 挤占「大于 0」占位与输入值。
      headerInfo: workflowFieldText(context).workflowArrivalQuantityHint,
      textOf: (line) => line.qty.text,
      listenableOf: (line) => line.qty,
      cellBuilder: (context, line) => RequiredCellFrame(
        listenable: line.qty,
        isEmpty: () => (double.tryParse(line.qty.text.trim()) ?? 0) <= 0,
        child: Semantics(
          textField: true,
          label: '${line.item.goodsName} 本次实收',
          child: TextField(
            key: ValueKey('warehouse-arrival-qty-${line.item.orderItemId}'),
            controller: line.qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            decoration: const UtenInputDecoration(
              InputDecoration(hintText: '大于 0', isDense: true),
            ),
          ),
        ),
      ),
    ),
    // 单位紧跟「本次实收」（2026-09-05 用户口径）：数量的含义（数量/重量）
    // 由基础资料-单位的维度决定，重量型单位的实收即重量。
    EditableGridColumn(
      key: 'unit',
      label: '单位',
      width: 80,
      textOf: (line) => line.item.unitName ?? '—',
      cellBuilder: (context, line) => Text(line.item.unitName ?? '—'),
    ),
    EditableGridColumn(
      key: 'warehouse',
      label: '入库仓库',
      width: 170,
      required: true,
      textOf: (line) => _warehouseLabel(_effectiveWarehouseId(line)) ?? '未选择',
      // 格尾箭头(20) + 预填黄标 ⓘ(44)计入量宽（2026-09-16）。
      chromeWidth:
          UtenEditableGridCellSpec.dropdownChevronWidth +
          UtenEditableGridCellSpec.hintIconWidth,
      cellBuilder: (context, line) {
        final theme = Theme.of(context);
        final warehouseId = _effectiveWarehouseId(line);
        final label = _warehouseLabel(warehouseId);
        final suggested = _suggestedWarehouseId;
        final changedAway =
            suggested != null &&
            warehouseId != null &&
            !warehousesShareMain(
              ref.read(masterNameServiceProvider).warehouseHierarchy,
              warehouseId,
              suggested,
            );
        return Semantics(
          button: true,
          label: '${line.item.goodsName} 入库仓库：${label ?? '未选择'}，点击修改',
          child: InkWell(
            key: ValueKey('warehouse-arrival-wh-${line.item.orderItemId}'),
            onTap: _saving ? null : () => _pickLineWarehouse(line),
            borderRadius: BorderRadius.circular(UtenRadius.control),
            child: InputDecorator(
              // 行级必填：未选仓描红边提示；改离建议仓描橙边提醒（合格库存
              // 不再计入原物料分析目标仓）。选仓走整页 setState 重建本格。
              // 2026-09-10 单元规格统一：不自带 border/contentPadding/小字/双行，
              // 圆角、内边距、字号吃 UtenEditableGrid 行级主题（与数量格等高）。
              decoration: applyAutofillHint(
                UtenInputDecoration(
                  InputDecoration(
                    isDense: true,
                    enabledBorder: label == null
                        ? requiredEmptyBorder(theme)
                        : changedAway
                        ? autofillHintBorder(theme)
                        : null,
                  ),
                  info: line.warehouseAutofilled
                      ? '已带入上次收货仓或来源建议仓，请核对本次实物仓库'
                      : null,
                ),
                theme,
                autofilled: label != null && line.warehouseAutofilled,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label ?? '必选 · 点击选择',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: label == null
                          ? theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.error,
                              fontWeight: FontWeight.w600,
                            )
                          : null,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
    EditableGridColumn(
      key: 'expectedAllocation',
      label: '预计去向(基本量)',
      width: 240,
      textOf: (line) => warehouseInboundAllocationSummaryText(
        _lineProjectedAllocations(line),
        (value) => '${procurementQty(value)} ${_lineBaseUnitLabel(line)}',
      ),
      listenableOf: (line) => line.qty,
      cellBuilder: (context, line) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: line.qty,
        builder: (context, _, _) {
          final allocations = _lineProjectedAllocations(line);
          return WarehouseInboundAllocationSummary(
            allocations: allocations,
            qtyText: (value) =>
                '${procurementQty(value)} ${_lineBaseUnitLabel(line)}',
            onTap: () => showWarehouseInboundAllocationDetails(
              context,
              title: '预计去向 · ${line.item.goodsName}',
              sections: [_lineAllocationSection(line)],
            ),
          );
        },
      ),
    ),
    EditableGridColumn(
      key: 'stockPlace',
      label: _stockInBeforeInspection ? '上架库位(必填)' : '库位号',
      width: 140,
      required: _stockInBeforeInspection,
      textOf: (line) => line.stockPlace.text,
      listenableOf: (line) => line.stockPlace,
      // 预填黄标 ⓘ(44)计入量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
      // 先入库后质检：库位是实物落点，空则描红框(原流程只是学习字段)。
      cellBuilder: (context, line) => RequiredCellFrame(
        listenable: line.stockPlace,
        isEmpty: () =>
            _stockInBeforeInspection && line.stockPlace.text.trim().isEmpty,
        child: Semantics(
          textField: true,
          label: '${line.item.goodsName} 库位号',
          child: WarehouseAutofillTextField(
            controller: line.stockPlace,
            source: _stockInBeforeInspection
                ? '先入库后质检：这里填实物实际放置的库位，品质部按此到库位检验'
                : '库位来自货品资料或上次登记，请核对本次实物存放位置',
            enabled: !_saving,
            onChanged: (value) => _onStockPlaceChanged(line, value),
          ),
        ),
      ),
    ),
    EditableGridColumn(
      key: 'series',
      label: '物料系列',
      width: 140,
      textOf: (line) => line.series.text,
      listenableOf: (line) => line.series,
      // 预填黄标 ⓘ(44)计入量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
      cellBuilder: (context, line) => Semantics(
        textField: true,
        label: '${line.item.goodsName} 物料系列',
        child: WarehouseAutofillTextField(
          controller: line.series,
          source: '系列来自货品资料，请核对本次到货',
          enabled: !_saving,
        ),
      ),
    ),
  ];

  /// 明细表下方的合计条（全站统一 UtenTotalsSummaryBar 口径）：数量严格按单位
  /// UUID 分组，不同单位绝不相加；本页对仓库不可见价格，故没有金额项。
  Widget _lineTotalsBar() => UtenTotalsSummaryBar(
    key: const Key('warehouse-arrival-totals'),
    density: true,
    entries: [
      UtenTotalEntry('明细', '${_lines.length} 行'),
      utenQuantityTotalEntry(
        _lines.map(
          (line) => MeasuredAmount(
            value: double.tryParse(line.qty.text.trim()) ?? 0,
            unitId: line.item.unitId,
            unitName: line.item.unitName,
          ),
        ),
        label: '本次实收',
      ),
    ],
  );

  Widget _buildBottomBar(ThemeData theme, bool canRegister, bool canPreStock) {
    // 合计不再挂底部操作条（2026-09-11 用户口径：明细表下方已有合计条，
    // 底部再报一遍是重复），这里只剩取消 / 先入库后质检 / 先质检后入库。
    // 2026-09-20：「登记并送检」改名「先质检后入库」(与「先入库后质检」对仗，
    // 任务中心批量按钮同名)；单张页由双击行进入、未预选路线，故两个按钮都保留。
    // 2026-09-17 勾选口径：提交集=勾选集，一行都没勾时两个提交按钮置灰，
    // 灰态点击说明原因（未勾选的行本次不登记）。
    final hasCheckedLine = _lineGrid.selectedRows.isNotEmpty;
    final VoidCallback? onDisabledTap =
        !canRegister || _lines.isEmpty || hasCheckedLine
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
        // 先入库后质检(V596 / ADR-090)：与「先质检后入库」并排的第二个主动作(用户口径
        // 2026-09-16「在登记并送检左边加个按钮」)。点它 = 登记 + 送检 + 按库位上架同一事务，
        // 品质部到库位检验；合格自动转正入库，不合格从库位取出退回。需独立权限。
        if (canPreStock)
          Tooltip(
            message:
                '货品直接上架到库位、品质部到库位检验：每行「库位号」必填；'
                '合格由系统按上架位置自动转正入库，不合格由仓库从库位取出登记退回',
            child: UtenButton(
              key: const Key('warehouse-arrival-stock-in-first'),
              size: UtenButtonSize.large,
              isLoading: _saving && _stockInBeforeInspection,
              icon: Icons.shelves,
              onPressed:
                  !canRegister || _saving || _lines.isEmpty || !hasCheckedLine
                  ? null
                  : () => _save(preStock: true),
              onDisabledTap: onDisabledTap,
              child: const Text('先入库后质检'),
            ),
          ),
        UtenButton(
          // 「点了就往下走一步」的主动作统一红底白字（全站口径）。
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          isLoading: _saving && !_stockInBeforeInspection,
          icon: Icons.fact_check_outlined,
          onPressed:
              !canRegister || _saving || _lines.isEmpty || !hasCheckedLine
              ? null
              : () => _save(preStock: false),
          onDisabledTap: onDisabledTap,
          child: const Text('先质检后入库'),
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

/// 一行到货登记明细的本地状态（数量 + 行级入库仓库 + 库位/系列/编码学习字段）。
class _ArrivalReceiptLine extends EditableGridRow {
  _ArrivalReceiptLine(this.item, {String? warehouseId, required this.onChanged})
    : qty = TextEditingController(
        text: procurementQty(item.approvedRemainingQty),
      ),
      stockPlace = UtenAutofillTextController(text: item.goodsStockPlace ?? ''),
      series = UtenAutofillTextController(text: item.goodsSeries ?? ''),
      goodsCode = UtenAutofillTextController(text: item.goodsCode),
      warehouseId = warehouseId?.isNotEmpty == true ? warehouseId : null {
    warehouseAutofilled = this.warehouseId != null;
    qty.addListener(onChanged);
  }

  final ProcurementReceiptPrefillItem item;
  final VoidCallback onChanged;
  final TextEditingController qty;
  WarehouseArrivalSource source = WarehouseArrivalSource.automatic;

  /// 行级入库仓库（2026-09-06 起必填：建议仓预填，无建议时留空待选）。
  String? warehouseId;
  bool warehouseAutofilled = false;

  final UtenAutofillTextController stockPlace;
  final UtenAutofillTextController series;
  final UtenAutofillTextController goodsCode;

  /// 批量写入库位：视同已核对，写完不留预填黄标。
  /// 同值写入时 UtenAutofillTextController 不会自行清标（它只在文本变化时清），
  /// 故先置空再写回，逼它翻成手工值。
  void setCheckedStockPlace(String value) {
    if (stockPlace.text == value) stockPlace.value = TextEditingValue.empty;
    stockPlace.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    qty.removeListener(onChanged);
    qty.dispose();
    stockPlace.dispose();
    series.dispose();
    goodsCode.dispose();
    super.dispose();
  }
}
