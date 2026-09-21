// 仓库批量登记实际到货页（/warehouse/inbound/receipts/batch）。
//
// 入库任务中心「预计到货」多选「先质检后入库」/「先入库后质检」的落点（2026-09-06）：把多张
// 采购/委外订货单的待登记明细汇成一张行级表——本次实收默认=批准剩余、入库仓库
// 行级必填（建议仓预填；**勾选多行后在其中任意一行改仓/写库位即整批落值**，
// 2026-09-11 起不再有表头上方的批量按钮，并记住上次所落仓与库位下次自动带），
// 一次提交按
// 「订货单 × 入库仓库」分组逐张登记并送检（与单张登记页同一条
// registerArrival + 内容派生幂等键链路；部分失败可原地重试不重复登记）。
// 仅断点「已登记 · 待送检」的草稿单不走本页（列表内直接批量送检）。
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
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_input_decoration.dart';
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
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/models/inbound_allocation.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../providers/warehouse_arrival_fill_memory.dart';
import '../providers/warehouse_count_refresh.dart';
import '../widgets/batch_place_fill_dialog.dart';
import '../widgets/warehouse_autofill_text_field.dart';
import '../widgets/warehouse_arrival_source_field.dart';
import '../repositories/procurement_inbound_repository.dart';

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
    extends ConsumerState<WarehouseArrivalBatchReceiptPage> {
  final _remark = TextEditingController();
  final _scrollCtl = ScrollController();

  /// 明细表 sticky 表头是否已置顶（页面滚动条门控：置顶前不显示，置顶后才显示）。
  final _gridPinned = ValueNotifier<bool>(false);
  final _lineGrid = UtenEditableGridController<_BatchArrivalLine>();
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  DateTime _billDate = ChinaDateTime.today();
  String? _receiverId;
  bool _loading = false;
  bool _saving = false;
  final String _registrationId = const Uuid().v4();
  int _removedLineCount = 0;

  /// 先入库后质检(V596)：本页路线由任务中心进页时定死(2026-09-20 起底部只有一个
  /// 提交按钮)——「先入库后质检」= 登记送检的同一事务里把每行按库位上架(库位必填)；
  /// 「先质检后入库」= 原登记送检流程。库位列是否必填(红框)跟着它走；进页或提交时
  /// 发现没有独立权限则退回原流程并提示(服务端同样兜底)。
  bool _stockInBeforeInspection = false;

  /// 本页路线的按钮名(与任务中心批量按钮同名)。
  String get _routeLabel => _stockInBeforeInspection ? '先入库后质检' : '先质检后入库';

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

  String? _warehouseLabel(String? id) {
    if (id == null || id.isEmpty) return null;
    final names = ref.read(masterNameServiceProvider);
    return warehouseFullLabel(names.warehouseHierarchy, id) ??
        names.warehouse(id);
  }

  @override
  void initState() {
    super.initState();
    // 进页即定路线；没有独立权限时退回「先质检后入库」(任务中心本就不显示该入口)。
    _stockInBeforeInspection =
        widget.stockInBeforeInspection && _canStockInBeforeInspection;
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
    final prefills = widget.prefills;
    if (prefills == null || prefills.isEmpty) return;
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
    final selectable = WarehouseSelection(
      ref.read(masterNameServiceProvider).warehouseHierarchy,
    ).selectableIds;
    // 个人选仓上下文：只补空位，不覆盖来源建议仓与货品资料带出的库位
    //（优先级见 warehouse_arrival_fill_memory.dart）。补进来的一律带黄标提示核对。
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
    if (mounted) setState(() => _loading = false);
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

  /// 确认弹窗正文：一行一个要点（· 前缀 + 悬挂缩进），比整段连排短一半以上。
  /// [extra] 是只在特定条件下才追加的那一条（如跨仓预定提示），用警示色区分。
  Widget _confirmPoints(List<String> points, {String? extra}) => Builder(
    builder: (context) {
      final theme = Theme.of(context);
      Widget line(String text, {Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
        child: Text(
          '· $text',
          style: theme.textTheme.bodyMedium?.copyWith(color: color),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final point in points) line(point),
          if (extra != null) line(extra, color: theme.colorScheme.error),
        ],
      );
    },
  );

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
        line.setCheckedStockPlace(place);
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
          target.setCheckedStockPlace(value);
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

  /// [preStock] 为真 = 「先入库后质检」按钮，否则 = 「先质检后入库」按钮(原「登记并送检」)。
  Future<void> _save({required bool preStock}) async {
    if (!_canRegisterNow) {
      context.appError('当前账号没有登记并送检权限，请返回任务中心刷新权限');
      return;
    }
    final wantPreStock = preStock && _canStockInBeforeInspection;
    if (_stockInBeforeInspection != wantPreStock) {
      // 路线进页已定，这里只会因权限被收回而退回原流程：说明原因并换成
      // 「先质检后入库」按钮，由用户决定是否继续，不静默换路线提交。
      setState(() => _stockInBeforeInspection = wantPreStock);
      if (preStock && !wantPreStock) {
        context.appWarning('当前账号没有「到货先入库后质检」权限，已切换为「先质检后入库」，请确认后再提交');
        return;
      }
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
    final stockInFirst =
        _stockInBeforeInspection && _canStockInBeforeInspection;
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
      if (stockInFirst && line.stockPlace.text.trim().isEmpty) {
        missingPlace.add(label);
      }
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
      title: stockInFirst
          ? '先入库后质检(${groups.length} 张收货单)'
          : '先质检后入库(${groups.length} 张收货单)',
      confirmLabel: stockInFirst ? '确认登记并先入库' : '确认登记送检',
      content: _confirmPoints([
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
      final repo = ref.read(procurementInboundRepositoryProvider);
      for (final entry in groups.entries) {
        final lines = entry.value;
        final first = lines.first;
        final prefill = first.prefill;
        final isPurchase =
            prefill.orderType == ProcurementInboundOrderType.purchase;
        // 幂等键按「订货单+仓库+行+数量」内容派生：响应丢失重试复用同键安全
        // 重放；部分失败后原地重试，已成功组合按同键重放、不会重复登记。
        final canonical = [
          _registrationId,
          '${prefill.orderType.name}:${entry.key}',
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
                if (stockInFirst) 'preStockPlace': line.stockPlace.text.trim(),
                if (line.source.apiValue != null)
                  'replacementIntent': line.source.apiValue,
                'sourceDocNo': prefill.orderBillNo,
                if (line.item.colorId != null) 'colorId': line.item.colorId,
                if (line.item.unitId != null) 'unitId': line.item.unitId,
                if (!isPurchase) 'unitRate': line.item.unitRate,
              },
          ],
        };
        try {
          if (!mounted) return;
          // ADR-098：委外回厂累计低于允许损耗下限时服务端先 409，弹窗确认后带确认重发。
          final registration = await registerArrivalConfirmingShortDelivery(
            context: context,
            body: body,
            register: (payload) => repo.registerArrival(
              orderType: prefill.orderType,
              body: payload,
            ),
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
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canRegister = widget.canRegister ?? _canRegisterNow;
    return Scaffold(
      appBar: UtenAppBar(
        title: '批量登记实际到货',
        // 2026-09-20：路线在任务中心已选定，标题下标明本页走哪条，底部只此一个提交按钮。
        subtitle: '路线：$_routeLabel',
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
              listenable: _lineGrid,
              builder: (context, _) => _buildBottomBar(theme, canRegister),
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
            _banner(theme),
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
            // 「明细(N 行)」标题与表格上方的「统一设置入库仓库」按钮 2026-09-11
            // 一并撤除（落仓/填库位改由表格操作条的批量动作承载）：这里只留
            // 跨单据聚合信息（几张订货单合并到本批），看表体数不出来。
            Text(
              '来自 $_orderCount 张订货单',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            // 2026-09-14：本批可以只登记一部分——原先移出只在行右键菜单里，
            // 页面零提示，用户判定「不能删除部分」。2026-09-17 勾选口径后，
            // 未勾选=不进本次登记（与移出等效、可重新勾回），一并说明。
            Text(
              '明细默认全选：右下「$_routeLabel」只提交勾选的行，'
              '未勾选的行不登记、不写库存，仍留在待登记送检（可重新勾回）；'
              '本次不收的货品也可点行末 ⊖ 移出本次登记（也可勾选多行后右键批量移出）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenEditableGrid<_BatchArrivalLine>(
              key: const Key('warehouse-arrival-batch-lines-grid'),
              controller: _lineGrid,
              stickyHeaderPinned: _gridPinned,
              columns: _lineColumns,
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
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _lineTotalsBar(),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    _removedLineCount == 0
                        ? '本次实收默认=批准剩余量，可改；入库仓库行级必填（建议仓已预填）。'
                              '库位、系列、编码由货品资料带出，送检后会学习回写。'
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

  int get _orderCount =>
      _lines.map((line) => line.prefill.orderId).toSet().length;

  Widget _banner(ThemeData theme) {
    return Semantics(
      container: true,
      label: '按实际到货数量登记；提交后直接送品质部待检。超量部分自动隔离待财务定案。',
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
                child: Text(
                  '批量登记 · $_orderCount 张订货单：本次实收默认=批准剩余量；'
                  '入库仓库逐行必填。提交后按「订货单 × 入库仓库」分组建收货单并直接送检，'
                  '实到超量部分自动隔离待财务定案，不会入库、不会生成应付。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
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

  // 2026-09-11 全站表头快速筛选补齐：批量到货一次拉进多张订货单的上百行，
  // 来源订货单/类型/货品/颜色/单位/入库仓库给表头快速筛选（视图级过滤，
  // 不动行数据、输入值与勾选）。数量/库位等录入列不做筛选。
  List<EditableGridColumn<_BatchArrivalLine>> get _lineColumns => [
    EditableGridColumn(
      key: 'order',
      label: '来源订货单',
      width: 150,
      filterValueOf: (line) => _bucketOrNull(line.prefill.orderBillNo),
      cellBuilder: (context, line) => Tooltip(
        message:
            '${line.prefill.orderType.label} · ${line.prefill.orderBillNo}',
        // 单行省略号（2026-09-16 全站口径）：列宽随 textOf 自动加宽兜底，
        // 不再折两行把整行撑高。
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
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列，
    // 不再拼「名称(编号)」——拼串不能各自筛选，列窄时编号先被省略号吃掉。
    EditableGridColumn(
      key: 'goods',
      label: '货品名称',
      width: 200,
      filterValueOf: (line) => _bucketOrNull(line.item.goodsName),
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
      width: 140,
      // 2026-09-16 用户口径：编号是货品资料的身份快照，登记页**只读**——
      // 此前是可编辑核对框（自动带出+可改），与「编号不能修改」的域规则冲突。
      // 值仍由行模型 goodsCode 控制器承载（保存链路不变），只是格内不再可敲。
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
      width: 100,
      filterValueOf: (line) => _bucketOrNull(line.item.colorName),
      textOf: (line) => line.item.colorName ?? '—',
      cellBuilder: (context, line) => Text(line.item.colorName ?? '—'),
    ),
    EditableGridColumn(
      key: 'approvedRemainingQty',
      label: '批准剩余',
      width: 100,
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
        key: ValueKey(
          'warehouse-arrival-batch-source-${line.item.orderItemId}',
        ),
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
      // 通用说明放列头 ⓘ（2026-09-10 全站口径），与单张到货登记页一致。
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
            key: ValueKey(
              'warehouse-arrival-batch-qty-${line.item.orderItemId}',
            ),
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
    EditableGridColumn(
      key: 'unit',
      label: '单位',
      width: 70,
      filterValueOf: (line) => _bucketOrNull(line.item.unitName),
      textOf: (line) => line.item.unitName ?? '—',
      cellBuilder: (context, line) => Text(line.item.unitName ?? '—'),
    ),
    EditableGridColumn(
      key: 'warehouse',
      label: '入库仓库',
      width: 160,
      required: true,
      filterValueOf: (line) => _bucketOrNull(_warehouseLabel(line.warehouseId)),
      textOf: (line) => _warehouseLabel(line.warehouseId) ?? '未选择',
      // 格尾箭头(20) + 预填黄标 ⓘ(44)计入量宽（2026-09-16）。
      chromeWidth:
          UtenEditableGridCellSpec.dropdownChevronWidth +
          UtenEditableGridCellSpec.hintIconWidth,
      cellBuilder: (context, line) {
        final theme = Theme.of(context);
        final label = _warehouseLabel(line.warehouseId);
        return Semantics(
          button: true,
          label: '${line.item.goodsName} 入库仓库：${label ?? '未选择'}，点击修改',
          child: InkWell(
            key: ValueKey(
              'warehouse-arrival-batch-wh-${line.item.orderItemId}',
            ),
            onTap: _saving ? null : () => _pickLineWarehouse(line),
            borderRadius: BorderRadius.circular(UtenRadius.control),
            child: InputDecorator(
              // 2026-09-10 单元规格统一：不自带 border/contentPadding/小字/双行，
              // 圆角、内边距、字号吃 UtenEditableGrid 行级主题（与数量格等高）。
              decoration: applyAutofillHint(
                UtenInputDecoration(
                  InputDecoration(
                    isDense: true,
                    enabledBorder: label == null
                        ? requiredEmptyBorder(theme)
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
      key: 'stockPlace',
      label: _stockInBeforeInspection ? '上架库位(必填)' : '库位号',
      width: 120,
      required: _stockInBeforeInspection,
      textOf: (line) => line.stockPlace.text,
      listenableOf: (line) => line.stockPlace,
      // 预填黄标 ⓘ(44)计入量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
      // 先入库后质检：库位是实物落点，空则描红框。
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
      width: 120,
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
    key: const Key('warehouse-arrival-batch-totals'),
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

  Widget _buildBottomBar(ThemeData theme, bool canRegister) {
    // 2026-09-12 用户口径「跟其他页面一样，悬浮的在右下角」：吸底操作条改
    // UtenFloatingActionGroup（与品质批量审批页同款），只剩取消 / 提交
    //（合计在明细表下方的合计条，不在操作条重复）。
    // 2026-09-17 勾选口径：提交集=勾选集，一行都没勾时提交按钮置灰，
    // 灰态点击说明原因（未勾选的行本次不登记）。
    // 2026-09-20 用户口径：任务中心点哪条路线进来就只显示哪条路线的提交按钮
    // (「先入库后质检」或「先质检后入库」二者只出现一个)，不再并排两个让人再选一次。
    final hasCheckedLine = _lineGrid.selectedRows.isNotEmpty;
    final canSubmit =
        canRegister && !_saving && _lines.isNotEmpty && hasCheckedLine;
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
        // 先入库后质检(V596 / ADR-090)：登记 + 送检 + 按库位上架同一事务，品质部到
        // 库位检验；合格自动转正入库，不合格从库位取出退回。需独立权限(进页已校验)。
        if (_stockInBeforeInspection)
          Tooltip(
            message:
                '货品直接上架到库位、品质部到库位检验：每行「库位号」必填；'
                '合格由系统按上架位置自动转正入库，不合格由仓库从库位取出登记退回',
            child: UtenButton(
              key: const Key('warehouse-arrival-stock-in-first'),
              // 「点了就往下走一步」的主动作统一红底白字（全站口径）。
              type: UtenButtonType.danger,
              size: UtenButtonSize.large,
              isLoading: _saving,
              icon: Icons.shelves,
              onPressed: canSubmit ? () => _save(preStock: true) : null,
              onDisabledTap: onDisabledTap,
              child: const Text('先入库后质检'),
            ),
          )
        else
          Tooltip(
            message:
                '原登记送检流程：登记到货并直送品质部待检(IQC)，'
                '检验合格后转仓库待入库，仓库确认实物与库位后库存才增加',
            child: UtenButton(
              key: const Key('warehouse-arrival-batch-submit'),
              type: UtenButtonType.danger,
              size: UtenButtonSize.large,
              isLoading: _saving,
              icon: Icons.fact_check_outlined,
              onPressed: canSubmit ? () => _save(preStock: false) : null,
              onDisabledTap: onDisabledTap,
              child: const Text('先质检后入库'),
            ),
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

/// 一行批量到货登记明细：挂来源订货单预填 + 行级数量/仓库/学习字段。
class _BatchArrivalLine extends EditableGridRow {
  _BatchArrivalLine(this.prefill, this.item, {required this.onChanged})
    : qty = TextEditingController(
        text: procurementQty(item.approvedRemainingQty),
      ),
      stockPlace = UtenAutofillTextController(text: item.goodsStockPlace ?? ''),
      series = UtenAutofillTextController(text: item.goodsSeries ?? ''),
      goodsCode = UtenAutofillTextController(text: item.goodsCode),
      warehouseId =
          item.lastReceiptWarehouseId ??
          (prefill.suggestedWarehouseId?.isNotEmpty == true
              ? prefill.suggestedWarehouseId
              : prefill.warehouseId) {
    warehouseAutofilled = warehouseId?.isNotEmpty == true;
    qty.addListener(onChanged);
  }

  final ProcurementReceiptPrefill prefill;
  final ProcurementReceiptPrefillItem item;
  final VoidCallback onChanged;
  final TextEditingController qty;
  WarehouseArrivalSource source = WarehouseArrivalSource.automatic;

  /// 行级入库仓库（必填：建议仓预填，无建议时留空待选）。
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
